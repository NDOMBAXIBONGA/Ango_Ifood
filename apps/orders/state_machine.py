"""
Serviço Isolado de Gestão do Ciclo de Vida do Pedido (OMS - Order Management System).
Aplicação: 'orders'
Classe Principal: `OrderStateMachineManager`

Implementa com rigor absoluto:
- Secção 5: Ciclo de vida e 10 estados sequenciais + 4 saídas excecionais.
- Secção 5.1: Matriz estrita e imutável de transições permitidas.
- Secção 5.2: Princípios inegociáveis de Idempotência Absoluta e Histórico Imutável (`EventoPedido`).
- Concorrência Segura: Bloqueio pessimista de registo via `select_for_update()` dentro de `transaction.atomic()`.
- Disparo pós-commit de Sinais Operacionais (Django Signals) e Tarefas Assíncronas (Celery).
"""
from __future__ import annotations

import logging
import types
import uuid
from typing import Any

from django.core.exceptions import ValidationError
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.orders import signals
from apps.orders.models import EventoPedido, Pedido
from apps.orders.tasks import (
    iniciar_motor_despacho_logistico,
    iniciar_timer_aceitacao_parceiro,
    notificar_estafeta_pronto_recolha,
    processar_estorno_cancelamento_pedido,
    processar_liquidacao_ledger_pedido,
)

logger = logging.getLogger(__name__)


# ==============================================================================
# 1. EXCEÇÕES DA MÁQUINA DE ESTADOS (Secção 5.1)
# ==============================================================================

class OrderStateMachineError(ValidationError):
    """Exceção base para erros na máquina de estados do OMS."""

    def __init__(
        self,
        mensagem: str,
        codigo: str = "ORDER_STATE_MACHINE_ERROR",
        detalhes: dict[str, Any] | None = None,
    ) -> None:
        self.mensagem = mensagem
        self.codigo = codigo
        self.detalhes = detalhes or {}
        super().__init__(self.mensagem, code=codigo)


class InvalidStateTransition(OrderStateMachineError):
    """
    Exceção lançada quando se tenta executar uma transição de estado não permitida
    pela matriz da Secção 5.1 da especificação técnica.
    Herda de ValidationError do Django para integração transparente com APIs e validações.
    """

    def __init__(
        self,
        pedido_id: str | uuid.UUID,
        estado_atual: str,
        novo_estado: str,
        transicoes_permitidas: frozenset[str] | set[str],
        ator: str,
    ) -> None:
        self.pedido_id = str(pedido_id)
        self.estado_atual = estado_atual
        self.novo_estado = novo_estado
        self.transicoes_permitidas = sorted(list(transicoes_permitidas))
        self.ator = ator
        mensagem = (
            f"Secção 5.1: Transição de estado inválida para o Pedido {pedido_id}. "
            f"Não é permitido transitar de '{estado_atual}' para '{novo_estado}'. "
            f"Transições possíveis a partir de '{estado_atual}': {self.transicoes_permitidas}."
        )
        super().__init__(
            mensagem=mensagem,
            codigo="INVALID_STATE_TRANSITION",
            detalhes={
                "pedido_id": self.pedido_id,
                "estado_atual": estado_atual,
                "novo_estado": novo_estado,
                "transicoes_permitidas": self.transicoes_permitidas,
                "ator": ator,
            },
        )


# Alias de retrocompatibilidade
InvalidStateTransitionError = InvalidStateTransition


class OrderNotFoundError(OrderStateMachineError):
    """Lançada quando o pedido informado não existe na base de dados."""

    def __init__(self, pedido_id: str | uuid.UUID) -> None:
        super().__init__(
            mensagem=f"Pedido com ID '{pedido_id}' não foi encontrado na base de dados.",
            codigo="ORDER_NOT_FOUND",
            detalhes={"pedido_id": str(pedido_id)},
        )


# ==============================================================================
# 2. OBJETO DE RESULTADO DE TRANSIÇÃO (Suporte a Pedido direto e Tuplo)
# ==============================================================================

class OrderTransitionResult:
    """
    Encapsula o resultado da execução de uma transição de estado.
    Implementa um padrão Proxy / Desempacotador transparente:
    - Comportamento de `Pedido`: Qualquer acesso a atributo é delegado a `self.pedido`
      (ex.: `resultado.estado`, `resultado.id`, `resultado.total_cobrado`).
    - Desempacotamento de Tuplo: Permite chamadas legadas que desempacotam
      `(pedido, evento, transitou) = OrderStateMachineManager.transitar_estado(...)`.
    """

    def __init__(
        self,
        pedido: Pedido,
        evento: EventoPedido | None = None,
        transitou: bool = True,
    ) -> None:
        self.pedido = pedido
        self.evento = evento
        self.transitou = transitou

    def __iter__(self):
        yield self.pedido
        yield self.evento
        yield self.transitou

    def __getattr__(self, name: str) -> Any:
        return getattr(self.pedido, name)

    def __eq__(self, other: Any) -> bool:
        if isinstance(other, OrderTransitionResult):
            return self.pedido == other.pedido
        return self.pedido == other

    def __repr__(self) -> str:
        return (
            f"<OrderTransitionResult pedido={self.pedido.id} "
            f"estado={self.pedido.estado} transitou={self.transitou}>"
        )

    def __str__(self) -> str:
        return str(self.pedido)


# ==============================================================================
# 3. CLASSE DE SERVIÇO: OrderStateMachineManager (Secção 5)
# ==============================================================================

class OrderStateMachineManager:
    """
    Gestor Isolado e Robusto da Máquina de Estados do Pedido (OMS).
    Centraliza a execução segura das transições de ciclo de vida com atomicidade estrita,
    bloqueio pessimista contra condições de corrida, registo imutável de auditoria e idempotência absoluta.
    """

    # --------------------------------------------------------------------------
    # Requisito 1: Matriz Imutável de Transições Permitidas (Secção 5.1)
    # 10 Estados Sequenciais:
    #   1. CRIADO -> 2. PAGAMENTO -> 3. AGUARDA_PARCEIRO -> 4. ACEITE ->
    #   5. EM_PREPARACAO -> 6. PRONTO -> 7. RECOLHIDO -> 8. EM_TRANSITO ->
    #   9. ENTREGUE -> 10. CONCLUIDO
    # 4 Saídas Excecionais:
    #   REJEITADO, CANCELADO, FALHA_ENTREGA, REEMBOLSADO
    # --------------------------------------------------------------------------
    MATRIZ_TRANSICOES: types.MappingProxyType[str, frozenset[str]] = types.MappingProxyType({
        # 1. CRIADO: Pedido criado pelo cliente no checkout
        Pedido.EstadoPedido.CRIADO: frozenset({
            Pedido.EstadoPedido.PAGAMENTO,
            Pedido.EstadoPedido.CANCELADO,
        }),
        # 2. PAGAMENTO: Aguarda autorização/captura do pagamento
        Pedido.EstadoPedido.PAGAMENTO: frozenset({
            Pedido.EstadoPedido.AGUARDA_PARCEIRO,
            Pedido.EstadoPedido.CANCELADO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 3. AGUARDA_PARCEIRO: Pagamento retido; aguarda resposta da loja parceira
        Pedido.EstadoPedido.AGUARDA_PARCEIRO: frozenset({
            Pedido.EstadoPedido.ACEITE,
            Pedido.EstadoPedido.REJEITADO,
            Pedido.EstadoPedido.CANCELADO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 4. ACEITE: Parceiro aceitou o pedido comercialmente
        Pedido.EstadoPedido.ACEITE: frozenset({
            Pedido.EstadoPedido.EM_PREPARACAO,
            Pedido.EstadoPedido.CANCELADO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 5. EM_PREPARACAO: Cozinha/estabelecimento a preparar os itens
        Pedido.EstadoPedido.EM_PREPARACAO: frozenset({
            Pedido.EstadoPedido.PRONTO,
            Pedido.EstadoPedido.CANCELADO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 6. PRONTO: Pedido confecionado e embalado, pronto para recolha
        Pedido.EstadoPedido.PRONTO: frozenset({
            Pedido.EstadoPedido.RECOLHIDO,
            Pedido.EstadoPedido.CANCELADO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 7. RECOLHIDO: Estafeta levantou o pacote fisicamente no estabelecimento
        Pedido.EstadoPedido.RECOLHIDO: frozenset({
            Pedido.EstadoPedido.EM_TRANSITO,
            Pedido.EstadoPedido.CANCELADO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 8. EM_TRANSITO: Estafeta em deslocação para a morada do cliente
        Pedido.EstadoPedido.EM_TRANSITO: frozenset({
            Pedido.EstadoPedido.ENTREGUE,
            Pedido.EstadoPedido.FALHA_ENTREGA,
            Pedido.EstadoPedido.CANCELADO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 9. ENTREGUE: Estafeta entregou e validou o PIN do cliente
        Pedido.EstadoPedido.ENTREGUE: frozenset({
            Pedido.EstadoPedido.CONCLUIDO,
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # 10. CONCLUIDO: Ciclo operacional terminado; liquidação financeira efetuada
        Pedido.EstadoPedido.CONCLUIDO: frozenset({
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # --- Saídas Excecionais ---
        Pedido.EstadoPedido.REJEITADO: frozenset({
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        Pedido.EstadoPedido.CANCELADO: frozenset({
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        Pedido.EstadoPedido.FALHA_ENTREGA: frozenset({
            Pedido.EstadoPedido.REEMBOLSADO,
        }),
        # Estado Terminal Absoluto: Não permite transições subsequentes
        Pedido.EstadoPedido.REEMBOLSADO: frozenset(),
    })

    # Mapeamento oficial entre o estado do OMS e o evento de domínio (Secção 12.1)
    ESTADO_PARA_TIPO_EVENTO: types.MappingProxyType[str, str] = types.MappingProxyType({
        Pedido.EstadoPedido.CRIADO: EventoPedido.TipoEvento.ORDER_CREATED,
        Pedido.EstadoPedido.PAGAMENTO: EventoPedido.TipoEvento.ORDER_PAID,
        Pedido.EstadoPedido.AGUARDA_PARCEIRO: EventoPedido.TipoEvento.ORDER_SENT_TO_PARTNER,
        Pedido.EstadoPedido.ACEITE: EventoPedido.TipoEvento.ORDER_ACCEPTED,
        Pedido.EstadoPedido.EM_PREPARACAO: EventoPedido.TipoEvento.ORDER_IN_PREPARATION,
        Pedido.EstadoPedido.PRONTO: EventoPedido.TipoEvento.ORDER_READY,
        Pedido.EstadoPedido.RECOLHIDO: EventoPedido.TipoEvento.ORDER_PICKED_UP,
        Pedido.EstadoPedido.EM_TRANSITO: EventoPedido.TipoEvento.ORDER_IN_TRANSIT,
        Pedido.EstadoPedido.ENTREGUE: EventoPedido.TipoEvento.ORDER_DELIVERED,
        Pedido.EstadoPedido.CONCLUIDO: EventoPedido.TipoEvento.ORDER_COMPLETED,
        Pedido.EstadoPedido.REJEITADO: EventoPedido.TipoEvento.ORDER_REJECTED,
        Pedido.EstadoPedido.CANCELADO: EventoPedido.TipoEvento.ORDER_CANCELLED,
        Pedido.EstadoPedido.FALHA_ENTREGA: EventoPedido.TipoEvento.ORDER_DELIVERY_FAILED,
        Pedido.EstadoPedido.REEMBOLSADO: EventoPedido.TipoEvento.ORDER_REFUNDED,
    })

    # --------------------------------------------------------------------------
    # Normalização de Aliases de Estado
    # --------------------------------------------------------------------------
    @classmethod
    def normalizar_estado(cls, estado: str | Pedido.EstadoPedido) -> str:
        """Harmoniza aliases e variações textuais para o identificador canónico do modelo."""
        estado_str = str(estado).strip()
        if estado_str.upper() in ("PREPARACAO", "5. PREPARACAO", "5. PREPARAÇÃO", "PREPARAÇÃO"):
            return Pedido.EstadoPedido.EM_PREPARACAO
        # Mapeia pelos valores e escolhas padrão
        for val in Pedido.EstadoPedido.values:
            if estado_str.upper() == val.upper():
                return val
        return estado_str

    # --------------------------------------------------------------------------
    # Requisito 2, 3, 4 e 5: transitar_estado()
    # --------------------------------------------------------------------------
    @classmethod
    def transitar_estado(
        cls,
        pedido_id: str | uuid.UUID,
        novo_estado: str | Pedido.EstadoPedido,
        ator: str,
        dados_adicionais: dict[str, Any] | None = None,
    ) -> OrderTransitionResult:
        """
        Executa a transição de estado de um pedido de forma estritamente atómica e protegida.

        Garantias Técnicas:
        1. Bloqueio Pessimista (`select_for_update()`): Previne condições de corrida (Race Conditions)
           quando múltiplos atores concorrentes (cliente, parceiro, webhook ou timer) operam no mesmo pedido.
        2. Idempotência Absoluta (Secção 5.2): Se o pedido já estiver no estado pretendido, encerra
           silenciosamente sem criar registos duplicados ou disparar novos efeitos colaterais.
        3. Validação Estrita (Secção 5.1): Se o destino for ilegal, levanta `InvalidStateTransition`.
        4. Histórico Imutável (Secção 5.2): Grava novo registo na tabela `EventoPedido` com timestamp e ator.
        5. Sinais e Celery pós-commit: Os efeitos secundários só disparam após `on_commit` na base de dados.
        """
        novo_estado_canonico = cls.normalizar_estado(novo_estado)
        dados_contexto = dict(dados_adicionais or {})

        # Validação obrigatória da identificação do ator da ação (Secção 5.2)
        if not ator or not str(ator).strip():
            raise OrderStateMachineError(
                mensagem="Secção 5.2: É obrigatório identificar o ator responsável pela transição de estado.",
                codigo="ACTOR_REQUIRED",
            )

        ator_str = str(ator).strip()

        # Requisito 2: Bloco atómico transacional com bloqueio pessimista
        with transaction.atomic():
            try:
                pedido = (
                    Pedido.objects.select_for_update()
                    .select_related("loja", "cliente")
                    .get(pk=pedido_id)
                )
            except Pedido.DoesNotExist as exc:
                raise OrderNotFoundError(pedido_id) from exc

            estado_anterior = pedido.estado

            # Requisito 4: Idempotência Absoluta (Secção 5.2)
            # Se o estado atual do pedido já for rigorosamente igual ao novo_estado solicitado,
            # interrompe a execução silenciosamente e retorna o pedido sem disparar efeitos secundários.
            if estado_anterior == novo_estado_canonico:
                logger.info(
                    "Secção 5.2: Transição idempotente ignorada para Pedido %s. "
                    "O pedido já se encontra no estado '%s'.",
                    pedido.id,
                    novo_estado_canonico,
                )
                return OrderTransitionResult(pedido=pedido, evento=None, transitou=False)

            # Requisito 3: Validação da Transição contra a Matriz Imutável (Secção 5.1)
            transicoes_permitidas = cls.MATRIZ_TRANSICOES.get(estado_anterior, frozenset())
            if novo_estado_canonico not in transicoes_permitidas:
                logger.warning(
                    "Secção 5.1: Tentativa de transição inválida rejeitada para Pedido %s: "
                    "de '%s' para '%s' requisitado por '%s'.",
                    pedido.id,
                    estado_anterior,
                    novo_estado_canonico,
                    ator_str,
                )
                raise InvalidStateTransition(
                    pedido_id=pedido.id,
                    estado_atual=estado_anterior,
                    novo_estado=novo_estado_canonico,
                    transicoes_permitidas=transicoes_permitidas,
                    ator=ator_str,
                )

            # Validação Antifraude Obrigatória antes de enviar ao parceiro (Secção 6.14, RN-130 a RN-135)
            if novo_estado_canonico == Pedido.EstadoPedido.AGUARDA_PARCEIRO:
                from apps.orders.fraud_engine import FraudRiskAssessmentEngine
                dados_pg = dados_contexto.get("pagamento") or dados_contexto.get("dados_pagamento")
                FraudRiskAssessmentEngine.analisar_risco_pedido(
                    pedido=pedido,
                    dados_pagamento=dados_pg,
                )

            # Atualização do estado do Pedido
            agora = timezone.now()
            pedido.estado = novo_estado_canonico
            pedido.save(update_fields=["estado", "data_atualizacao"])

            # Requisito 5: Registo de Histórico Imutável na tabela EventoPedido (Secção 5.2)
            tipo_evento = cls.ESTADO_PARA_TIPO_EVENTO.get(
                novo_estado_canonico,
                f"order.{novo_estado_canonico.lower()}",
            )

            payload_historico = {
                **dados_contexto,
                "estado_anterior": estado_anterior,
                "novo_estado": novo_estado_canonico,
                "transicao": f"{estado_anterior} -> {novo_estado_canonico}",
                "timestamp_transicao": agora.isoformat(),
            }

            evento = EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=tipo_evento,
                autor=ator_str,
                timestamp=agora,
                dados_adicionais=payload_historico,
            )

            # Requisito 6: Disparo de Sinais Operacionais e Celery pós-commit
            cls._disparar_efeitos_secundarios(
                pedido=pedido,
                estado_anterior=estado_anterior,
                novo_estado=novo_estado_canonico,
                evento=evento,
                ator=ator_str,
                dados_adicionais=payload_historico,
            )

            logger.info(
                "Secção 5: Transição concluída com sucesso para Pedido %s: "
                "de '%s' para '%s' (evento=%s, ator=%s).",
                pedido.id,
                estado_anterior,
                novo_estado_canonico,
                tipo_evento,
                ator_str,
            )

            return OrderTransitionResult(pedido=pedido, evento=evento, transitou=True)

    # --------------------------------------------------------------------------
    # Requisito 6: Disparo de Sinais Operacionais e Tarefas Celery
    # --------------------------------------------------------------------------
    @classmethod
    def _disparar_efeitos_secundarios(
        cls,
        pedido: Pedido,
        estado_anterior: str,
        novo_estado: str,
        evento: EventoPedido,
        ator: str,
        dados_adicionais: dict[str, Any],
    ) -> None:
        """
        Executa os efeitos colaterais (Django Signals e Celery Tasks) exclusivamente
        após o commit da transação na base de dados (`transaction.on_commit`),
        garantindo consistência e prevenindo chamadas fantasmas em caso de rollback.
        """
        pedido_id_str = str(pedido.id)

        def _executar_pos_commit() -> None:
            # 1. Sinal genérico de transição concluída
            signals.order_state_transitioned.send(
                sender=cls,
                pedido=pedido,
                estado_anterior=estado_anterior,
                novo_estado=novo_estado,
                evento=evento,
                ator=ator,
                dados_adicionais=dados_adicionais,
            )

            # 2. Efeitos secundários específicos por estado de destino (Secção 5 e 6.7)
            if novo_estado == Pedido.EstadoPedido.AGUARDA_PARCEIRO:
                # Inicia o timer de aceitação pelo parceiro comercial (SLA de 3 min / 180s - Secção 8)
                signals.order_awaiting_partner.send(sender=cls, pedido=pedido, evento=evento)
                iniciar_timer_aceitacao_parceiro.apply_async(
                    args=[pedido_id_str],
                    kwargs={"timeout_segundos": 180},
                )

            elif novo_estado == Pedido.EstadoPedido.ACEITE:
                # Inicia o motor de despacho logístico para matching de estafetas (RN-090)
                signals.order_accepted.send(sender=cls, pedido=pedido, evento=evento)
                iniciar_motor_despacho_logistico.delay(pedido_id=pedido_id_str)

            elif novo_estado == Pedido.EstadoPedido.EM_PREPARACAO:
                # Notifica cliente e atualiza previsões de cozinha
                signals.order_in_preparation.send(sender=cls, pedido=pedido, evento=evento)

            elif novo_estado == Pedido.EstadoPedido.PRONTO:
                # Notifica o estafeta para levantamento imediato na loja
                signals.order_ready_for_pickup.send(sender=cls, pedido=pedido, evento=evento)
                notificar_estafeta_pronto_recolha.delay(pedido_id=pedido_id_str)

            elif novo_estado == Pedido.EstadoPedido.RECOLHIDO:
                # Notifica cliente que o pedido está a caminho
                signals.order_picked_up.send(sender=cls, pedido=pedido, evento=evento)

            elif novo_estado == Pedido.EstadoPedido.EM_TRANSITO:
                # Ativa o fluxo de geolocalização e tracking em tempo real (RN-094)
                signals.order_in_transit.send(sender=cls, pedido=pedido, evento=evento)

            elif novo_estado == Pedido.EstadoPedido.ENTREGUE:
                # Validação de PIN concluída e confirmação de entrega ao cliente (RN-095)
                signals.order_delivered.send(sender=cls, pedido=pedido, evento=evento)

            elif novo_estado == Pedido.EstadoPedido.CONCLUIDO:
                # Desencadeia lançamentos no Livro Razão Ledger de dupla entrada (Secção 7.3, RN-150)
                signals.order_completed.send(sender=cls, pedido=pedido, evento=evento)
                processar_liquidacao_ledger_pedido.delay(pedido_id=pedido_id_str)

            elif novo_estado == Pedido.EstadoPedido.CANCELADO:
                # Desencadeia estorno/reembolso no gateway e no livro razão (RN-066)
                signals.order_cancelled.send(sender=cls, pedido=pedido, evento=evento)
                motivo = str(dados_adicionais.get("motivo", "Cancelado pelo cliente/sistema"))
                processar_estorno_cancelamento_pedido.delay(pedido_id=pedido_id_str, motivo=motivo)

            elif novo_estado == Pedido.EstadoPedido.REJEITADO:
                # Desencadeia estorno/reembolso e notificação ao cliente (RN-070)
                signals.order_rejected.send(sender=cls, pedido=pedido, evento=evento)
                motivo = str(dados_adicionais.get("motivo", "Rejeitado pelo parceiro ou timeout de aceitação"))
                processar_estorno_cancelamento_pedido.delay(pedido_id=pedido_id_str, motivo=motivo)

            elif novo_estado == Pedido.EstadoPedido.FALHA_ENTREGA:
                # Falha operacional no trajeto; aciona suporte e reversão logística
                signals.order_delivery_failed.send(sender=cls, pedido=pedido, evento=evento)

            elif novo_estado == Pedido.EstadoPedido.REEMBOLSADO:
                # Registo do estorno finalizado no livro razão contábil
                signals.order_refunded.send(sender=cls, pedido=pedido, evento=evento)

        transaction.on_commit(_executar_pos_commit)


# ==============================================================================
# 4. ALIAS CANÓNICO PARA RETROCOMPATIBILIDADE TOTAL
# ==============================================================================

OrderStateMachine = OrderStateMachineManager
