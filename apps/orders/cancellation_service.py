"""
Serviço Financeiro Avançado para Processamento de Cancelamentos de Pedidos ('orders').
Implementa com rigor matemático e conformidade contábil:
- Secção 6.10: Tabela Completa de Cancelamentos, Reembolsos e Compensações;
- Secção 7.3: Princípios do Livro Razão Ledger de Dupla Entrada (partidas dobradas imutáveis);
- Regras de Negócio:
  - RN-102: Direito de cancelamento sem custos nos primeiros 60s ou em AGUARDA_PARCEIRO (100% reembolso);
  - RN-103: Cancelamento em preparação com retenção dos produtos confecionados e compensação ao parceiro;
  - RN-104: Penalização financeira e degradação de reputação do parceiro por cancelamento indevido;
  - RN-106: Cancelamento por timeout do sistema (sem estafeta) com reembolso integral e cupão de compensação;
  - RN-108: Registo de lançamentos compensatórios imutáveis no Livro Razão e alertas para taxas > 5% mensal;
  - RN-050 / RN-059: Aritmética estritamente inteira em unidades mínimas da moeda (Cêntimos / Kwanza);
  - RN-066 / RN-070: Desfazimento de autorizações (Void) ou captura definitiva via gateway.
"""
from __future__ import annotations

import logging
import uuid
from dataclasses import asdict, dataclass
from decimal import Decimal, ROUND_HALF_UP
from typing import Any

from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.catalog.models import ParceiroLoja
from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.finance.payment_service import PaymentGatewayIntegrationService
from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import Pedido
from apps.orders.state_machine_manager import OrderStateMachineManager
from apps.promotions.models import CupaoDesconto

logger = logging.getLogger("orders.cancellation")


# ==============================================================================
# EXCEÇÕES DE DOMÍNIO DE CANCELAMENTO
# ==============================================================================

class CancellationError(Exception):
    """Exceção base para erros durante o processo de cancelamento de pedido."""

    def __init__(self, mensagem: str, codigo: str = "CANCELLATION_ERROR", detalhes: dict[str, Any] | None = None) -> None:
        super().__init__(mensagem)
        self.mensagem = mensagem
        self.codigo = codigo
        self.detalhes = detalhes or {}


class OrderAlreadyFinalizedError(CancellationError):
    """Lançada quando se tenta cancelar um pedido que já atingiu um estado terminal."""
    pass


# ==============================================================================
# DTO DE RESULTADO FINANCEIRO DO CANCELAMENTO (SECÇÃO 6.10)
# ==============================================================================

@dataclass(frozen=True)
class ResultadoCancelamentoFinanceiro:
    """Detalhamento financeiro auditável da liquidação do cancelamento (Secção 6.10)."""

    pedido_id: str
    quem_cancela: str
    motivo: str
    estado_anterior: str
    novo_estado: str
    dentro_janela_60s: bool
    tempo_decorrido_segundos: int
    total_cobrado_original: int
    reembolso_cliente: int
    pagamento_parceiro: int
    pagamento_estafeta: int
    comissao_plataforma: int
    retencao_taxa_servico: int
    penalizacao_parceiro: int
    novo_score_parceiro: Decimal | None
    estafeta_compensado_id: str | None
    cupao_compensacao_codigo: str | None
    alerta_taxa_cancelamento_parceiro: bool
    lancamentos_ledger_ids: list[str]
    gateway_operacao: str
    gateway_status: str

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        if self.novo_score_parceiro is not None:
            data["novo_score_parceiro"] = str(self.novo_score_parceiro)
        return data


# ==============================================================================
# CLASSE DE SERVIÇO PRINCIPAL: OrderCancellationProcessor
# ==============================================================================

class OrderCancellationProcessor:
    """
    Processador transacional avançado para cancelamento de pedidos, penalizações,
    reembolsos e compensações com base estrita na Tabela da Secção 6.10 e RN-102 a RN-109.
    """

    # Penalização financeira fixa ao parceiro por cancelamento indevido (RN-104)
    DEFAULT_PENALIZACAO_PARCEIRO_CENTIMOS: int = getattr(
        settings, "PARTNER_CANCELLATION_PENALTY_FEE", 150_000  # 1.500 Kz
    )

    # Compensação logística mínima ao estafeta por deslocação cancelada (Secção 6.10)
    DEFAULT_COMPENSACAO_MINIMA_ESTAFETA: int = getattr(
        settings, "MIN_COURIER_CANCELLATION_COMPENSATION", 50_000  # 500 Kz
    )

    # Valor do cupão de compensação atribuído ao cliente em timeout sem estafetas (RN-106)
    DEFAULT_CUPAO_COMPENSACAO_TIMEOUT_CENTIMOS: int = getattr(
        settings, "VALOR_COMPENSACAO_TIMEOUT_ESTAFETA", 50_000  # 500 Kz
    )

    @classmethod
    def processar_cancelamento(
        cls,
        pedido_id: str | uuid.UUID,
        quem_cancela: str,
        motivo: str,
        ator_id: str | None = None,
    ) -> dict[str, Any]:
        """
        Executa a liquidação atómica de cancelamento sob a Tabela da Secção 6.10.
        Bloqueia o pedido com `select_for_update()` para congelar os valores durante o cálculo.

        Regras Codificadas:
        1. Estado 'AGUARDA_PARCEIRO' (Primeiros 60s ou após 60s se parceiro não aceitou):
           - Cliente: 100% reembolso. Parceiro e Estafeta 'Sem efeito/Sem custo' (RN-102).
        2. Estado 'ACEITE' (antes de preparar):
           - Cliente nos primeiros 60s: 100% reembolso.
           - Cliente após 60s: Retém 'taxa_servico'. Parceiro sem custo. Estafeta recebe compensação mínima se a caminho.
        3. Estado 'EM_PREPARACAO':
           - Cliente: Reembolso Parcial. Retém obrigatoriamente o Subtotal dos produtos.
             Parceiro recebe Subtotal líquido de comissão. Estafeta recebe compensação logística.
        4. Estado 'PRONTO' ou 'RECOLHIDO':
           - Cliente: Reembolso 0%. Parceiro recebe valor total dos produtos líquido de comissão.
             Estafeta recebe valor integral da corrida (taxa entrega + gorjeta).
        5. Cancelamento Iniciado pelo Parceiro (Qualquer estado):
           - Reembolso 100% ao cliente. Aplica taxa fixa de penalização financeira (RN-104, RN-108).
             Envia alerta se taxa mensal > 5%. Estafeta recebe compensação se houve deslocação.
        6. Cancelamento por Timeout do Sistema (Sem estafeta disponível):
           - Reembolso 100% ao cliente + atribuição de cupão de compensação (RN-106).
             Parceiro recebe produtos caso já confecionados (absorvido pela plataforma). Estafeta sem efeito.
        """
        quem_cancela_normalizado = str(quem_cancela).strip().capitalize()
        if quem_cancela_normalizado not in ("Cliente", "Parceiro", "Sistema", "Estafeta", "Suporte", "Timeout"):
            quem_cancela_normalizado = "Cliente"

        logger.info(
            "[CANCELAMENTO] A iniciar processamento para pedido_id=%s por %s (motivo: %s)",
            pedido_id,
            quem_cancela_normalizado,
            motivo,
        )

        with transaction.atomic():
            # 1. Bloqueio pessimista no pedido com select_for_update() para congelamento absoluto
            try:
                pedido = (
                    Pedido.objects.select_for_update()
                    .select_related("loja", "cliente")
                    .get(pk=pedido_id)
                )
            except Pedido.DoesNotExist as exc:
                raise CancellationError(
                    f"Pedido {pedido_id} não encontrado para cancelamento.",
                    codigo="ORDER_NOT_FOUND",
                ) from exc

            estado_anterior = pedido.estado

            # 2. Verificação de estados terminais que impedem novo cancelamento
            estados_terminais = {
                Pedido.EstadoPedido.ENTREGUE,
                Pedido.EstadoPedido.CONCLUIDO,
                Pedido.EstadoPedido.CANCELADO,
                Pedido.EstadoPedido.REEMBOLSADO,
            }
            if estado_anterior in estados_terminais:
                raise OrderAlreadyFinalizedError(
                    f"Secção 6.10: O pedido {pedido.id} já se encontra no estado terminal '{estado_anterior}'.",
                    codigo="ORDER_TERMINAL_STATE",
                    detalhes={"estado_atual": estado_anterior, "pedido_id": str(pedido.id)},
                )

            # 3. Verificação cronológica da janela de carência de 60 segundos
            agora = timezone.now()
            tempo_decorrido_segundos = int((agora - pedido.data_criacao).total_seconds())

            # Para o estado ACEITE, calcula especificamente a partir da transição para ACEITE
            segundos_desde_aceite = tempo_decorrido_segundos
            if estado_anterior == Pedido.EstadoPedido.ACEITE:
                evento_aceite = EventoPedido.objects.filter(
                    pedido=pedido,
                    tipo_evento=EventoPedido.TipoEvento.ORDER_ACCEPTED,
                ).order_by("-timestamp").first()
                if evento_aceite and evento_aceite.timestamp:
                    segundos_desde_aceite = int((agora - evento_aceite.timestamp).total_seconds())

            dentro_janela_60s = segundos_desde_aceite <= 60

            # 4. Verificação de dados operacionais da Entrega e Estafeta
            entrega: Entrega | None = getattr(pedido, "entrega", None) or getattr(pedido, "entrega_logistica", None)
            estafeta: Estafeta | None = None
            estafeta_atribuido = False
            estafeta_em_deslocacao = False

            if entrega and entrega.estafeta_id:
                try:
                    estafeta = Estafeta.objects.select_for_update().get(pk=entrega.estafeta_id)
                    estafeta_atribuido = True
                    estafeta_em_deslocacao = entrega.estado_entrega in (
                        Entrega.EstadoEntrega.ATRIBUIDO,
                        Entrega.EstadoEntrega.RECOLHIDO,
                        Entrega.EstadoEntrega.EM_TRANSITO,
                    )
                except Estafeta.DoesNotExist:
                    estafeta = None

            # 5. Parâmetros e valores financeiros base (em unidades mínimas inteiras - RN-059)
            subtotal = pedido.subtotal
            taxa_entrega = pedido.taxa_entrega
            taxa_servico = pedido.taxa_servico
            gorjeta_estafeta = pedido.gorjeta_estafeta
            total_cobrado = pedido.total_cobrado

            comissao_loja_pct: Decimal = pedido.loja.comissao_percentagem
            comissao_plataforma = int(
                (Decimal(subtotal) * (comissao_loja_pct / Decimal("100.00"))).quantize(
                    Decimal("1"), rounding=ROUND_HALF_UP
                )
            )
            valor_liquido_parceiro = max(0, subtotal - comissao_plataforma)

            compensacao_minima_estafeta = cls.DEFAULT_COMPENSACAO_MINIMA_ESTAFETA
            if taxa_entrega > 0:
                compensacao_minima_estafeta = min(taxa_entrega, max(cls.DEFAULT_COMPENSACAO_MINIMA_ESTAFETA, taxa_entrega // 2))

            compensacao_integral_estafeta = taxa_entrega + gorjeta_estafeta

            # Variáveis a definir conforme a matriz da Secção 6.10
            reembolso_cliente = 0
            pagamento_parceiro = 0
            pagamento_estafeta = 0
            retencao_taxa_servico = 0
            penalizacao_parceiro = 0
            novo_score_parceiro: Decimal | None = None
            cupao_compensacao_codigo: str | None = None
            alerta_taxa_cancelamento_parceiro = False

            # ==================================================================
            # 6. APLICAÇÃO DOS 6 CENÁRIOS DA TABELA DA SECÇÃO 6.10
            # ==================================================================

            # ------------------------------------------------------------------
            # CENÁRIO 5: CANCELAMENTO PELO PARCEIRO (RN-104, RN-108)
            # ------------------------------------------------------------------
            if quem_cancela_normalizado == "Parceiro":
                reembolso_cliente = total_cobrado
                pagamento_parceiro = 0
                penalizacao_parceiro = cls.DEFAULT_PENALIZACAO_PARCEIRO_CENTIMOS

                if estafeta_atribuido and estafeta_em_deslocacao:
                    pagamento_estafeta = compensacao_minima_estafeta

                # Degradação de score de reputação do parceiro (-0.25)
                loja = pedido.loja
                loja.score_reputacao = max(Decimal("0.00"), loja.score_reputacao - Decimal("0.25"))
                loja.save(update_fields=["score_reputacao"])
                novo_score_parceiro = loja.score_reputacao

                # RN-104 / RN-108: Verificação de taxa de cancelamento mensal > 5%
                alerta_taxa_cancelamento_parceiro = cls._verificar_limiar_cancelamento_parceiro(loja)

            # ------------------------------------------------------------------
            # CENÁRIO 6: CANCELAMENTO POR TIMEOUT DO SISTEMA (SEM ESTAFETA - RN-106)
            # ------------------------------------------------------------------
            elif quem_cancela_normalizado in ("Sistema", "Timeout"):
                reembolso_cliente = total_cobrado
                pagamento_estafeta = 0  # Sem efeito para o estafeta

                # Se a comida já foi confecionada, o parceiro é pago e a plataforma absorve o custo
                if estado_anterior in (Pedido.EstadoPedido.EM_PREPARACAO, Pedido.EstadoPedido.PRONTO):
                    pagamento_parceiro = valor_liquido_parceiro

                # RN-106: Atribuição de cupão/crédito de compensação ao cliente
                cupao_compensacao_codigo = cls._emitir_cupao_compensacao_cliente(pedido.cliente)

            # ------------------------------------------------------------------
            # CENÁRIOS 1 A 4: CANCELAMENTOS INICIADOS PELO CLIENTE
            # ------------------------------------------------------------------
            else:
                # 1. Estado 'Aguarda Parceiro' (ou nos primeiros 60s se pendente)
                if estado_anterior in (
                    Pedido.EstadoPedido.CRIADO,
                    Pedido.EstadoPedido.PAGAMENTO,
                    Pedido.EstadoPedido.AGUARDA_PARCEIRO,
                ):
                    reembolso_cliente = total_cobrado
                    pagamento_parceiro = 0
                    pagamento_estafeta = 0

                # 2. Estado 'Aceite, antes de preparar'
                elif estado_anterior == Pedido.EstadoPedido.ACEITE:
                    if dentro_janela_60s:
                        # Reembolso de 100% nos primeiros 60s
                        reembolso_cliente = total_cobrado
                        pagamento_parceiro = 0
                        pagamento_estafeta = 0
                    else:
                        # Após 60s: retém a taxa de serviço da plataforma
                        retencao_taxa_servico = taxa_servico
                        reembolso_cliente = max(0, total_cobrado - retencao_taxa_servico)
                        pagamento_parceiro = 0
                        if estafeta_atribuido and estafeta_em_deslocacao:
                            pagamento_estafeta = compensacao_minima_estafeta

                # 3. Estado 'Em preparação'
                elif estado_anterior == Pedido.EstadoPedido.EM_PREPARACAO:
                    # Reembolso Parcial: retém valor dos produtos (Subtotal)
                    reembolso_cliente = max(0, total_cobrado - subtotal)
                    retencao_taxa_servico = taxa_servico
                    pagamento_parceiro = valor_liquido_parceiro
                    if estafeta_atribuido:
                        pagamento_estafeta = compensacao_minima_estafeta

                # 4. Estado 'Pronto' ou 'Recolhido' (ou em trânsito)
                elif estado_anterior in (
                    Pedido.EstadoPedido.PRONTO,
                    Pedido.EstadoPedido.RECOLHIDO,
                    Pedido.EstadoPedido.EM_TRANSITO,
                ):
                    reembolso_cliente = 0  # 0% de reembolso ao cliente
                    retencao_taxa_servico = taxa_servico
                    pagamento_parceiro = valor_liquido_parceiro
                    pagamento_estafeta = compensacao_integral_estafeta

                else:
                    reembolso_cliente = total_cobrado

            # ==================================================================
            # 7. LANÇAMENTOS NO LIVRO RAZÃO LEDGER DE DUPLA ENTRADA (RN-108, RN-150)
            # ==================================================================
            lancamentos_ledger_ids: list[str] = []

            # A. Reembolso ao Cliente (PLATAFORMA -> CLIENTE)
            if reembolso_cliente > 0:
                l_cli = LivroRazaoLedger.objects.create(
                    referencia_pedido=pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.PLATAFORMA,
                    conta_destino=LivroRazaoLedger.ContaContabil.CLIENTE,
                    debito=reembolso_cliente,
                    credito=reembolso_cliente,
                )
                lancamentos_ledger_ids.append(str(l_cli.id))

            # B. Pagamento ao Parceiro pelos produtos (PLATAFORMA -> PARCEIRO)
            if pagamento_parceiro > 0:
                l_parc = LivroRazaoLedger.objects.create(
                    referencia_pedido=pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.PLATAFORMA,
                    conta_destino=LivroRazaoLedger.ContaContabil.PARCEIRO,
                    debito=pagamento_parceiro,
                    credito=pagamento_parceiro,
                )
                lancamentos_ledger_ids.append(str(l_parc.id))

            # C. Pagamento / Compensação ao Estafeta (PLATAFORMA -> ESTAFETA)
            if pagamento_estafeta > 0 and estafeta:
                l_est = LivroRazaoLedger.objects.create(
                    referencia_pedido=pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.PLATAFORMA,
                    conta_destino=LivroRazaoLedger.ContaContabil.ESTAFETA,
                    debito=pagamento_estafeta,
                    credito=pagamento_estafeta,
                )
                lancamentos_ledger_ids.append(str(l_est.id))

                # Credita imediatamente o saldo de carteira do estafeta (Secção 11 / RN-146)
                estafeta.saldo_carteira += pagamento_estafeta
                estafeta.save(update_fields=["saldo_carteira"])

            # D. Penalização Financeira ao Parceiro (PARCEIRO -> RETENCOES - RN-104)
            if penalizacao_parceiro > 0:
                l_pen = LivroRazaoLedger.objects.create(
                    referencia_pedido=pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.PARCEIRO,
                    conta_destino=LivroRazaoLedger.ContaContabil.RETENCOES,
                    debito=penalizacao_parceiro,
                    credito=penalizacao_parceiro,
                )
                lancamentos_ledger_ids.append(str(l_pen.id))

            # ==================================================================
            # 8. ATUALIZAÇÃO DA ENTREGA (SE APLICÁVEL)
            # ==================================================================
            if entrega and entrega.estado_entrega != Entrega.EstadoEntrega.ENTREGUE:
                entrega.estado_entrega = Entrega.EstadoEntrega.FALHOU
                entrega.save(update_fields=["estado_entrega"])

            # ==================================================================
            # 9. TRANSIÇÃO DA MÁQUINA DE ESTADOS PARA 'CANCELADO' COM EVENTO IMUTÁVEL
            # ==================================================================
            dados_adicionais_evento: dict[str, Any] = {
                "quem_cancela": quem_cancela_normalizado,
                "motivo": motivo,
                "estado_anterior": estado_anterior,
                "tempo_decorrido_segundos": tempo_decorrido_segundos,
                "dentro_janela_60s": dentro_janela_60s,
                "particao_financeira": {
                    "total_cobrado_original": total_cobrado,
                    "reembolso_cliente": reembolso_cliente,
                    "pagamento_parceiro": pagamento_parceiro,
                    "pagamento_estafeta": pagamento_estafeta,
                    "retencao_taxa_servico": retencao_taxa_servico,
                    "penalizacao_parceiro": penalizacao_parceiro,
                    "comissao_plataforma_retida": comissao_plataforma if pagamento_parceiro > 0 else 0,
                },
                "lancamentos_ledger_ids": lancamentos_ledger_ids,
                "cupao_compensacao": cupao_compensacao_codigo,
                "alerta_limiar_5pct": alerta_taxa_cancelamento_parceiro,
                "regra": "Secção 6.10 / RN-102 a RN-109",
            }

            autor_str = f"{quem_cancela_normalizado.lower()}:{ator_id or pedido.cliente_id}"

            resultado_transicao = OrderStateMachineManager.transitar_estado(
                pedido_id=pedido.id,
                novo_estado=Pedido.EstadoPedido.CANCELADO,
                ator=autor_str,
                dados_adicionais=dados_adicionais_evento,
            )

            # ==================================================================
            # 10. INTEGRAÇÃO COM GATEWAY DE PAGAMENTOS (ESTORNO / CAPTURA - RN-066)
            # ==================================================================
            gateway_operacao = "VOID_OR_REFUND"
            gateway_status = "SUCCESS"

            try:
                if reembolso_cliente > 0:
                    res_gateway = PaymentGatewayIntegrationService.cancelar_pre_autorizacao(
                        pedido_id=pedido.id,
                        motivo=f"Cancelamento por {quem_cancela_normalizado}: {motivo}",
                    )
                    gateway_operacao = res_gateway.get("status", "VOIDED")
                elif reembolso_cliente == 0 and total_cobrado > 0:
                    # Cenário 4 (Pronto/Recolhido): O cliente não recebe reembolso.
                    # A pré-autorização é definitivamente liquidada para pagar parceiro e estafeta!
                    res_gateway = PaymentGatewayIntegrationService.capturar_pagamento_final(
                        pedido_id=pedido.id,
                    )
                    gateway_operacao = res_gateway.get("status", "CAPTURED")
            except Exception as exc:
                logger.error("[CANCELAMENTO] Erro na liquidação com o gateway para pedido %s: %s", pedido.id, exc)
                gateway_status = f"ERROR: {exc}"

            resultado = ResultadoCancelamentoFinanceiro(
                pedido_id=str(pedido.id),
                quem_cancela=quem_cancela_normalizado,
                motivo=motivo,
                estado_anterior=estado_anterior,
                novo_estado=Pedido.EstadoPedido.CANCELADO,
                dentro_janela_60s=dentro_janela_60s,
                tempo_decorrido_segundos=tempo_decorrido_segundos,
                total_cobrado_original=total_cobrado,
                reembolso_cliente=reembolso_cliente,
                pagamento_parceiro=pagamento_parceiro,
                pagamento_estafeta=pagamento_estafeta,
                comissao_plataforma=comissao_plataforma if pagamento_parceiro > 0 else 0,
                retencao_taxa_servico=retencao_taxa_servico,
                penalizacao_parceiro=penalizacao_parceiro,
                novo_score_parceiro=novo_score_parceiro,
                estafeta_compensado_id=str(estafeta.id) if estafeta and pagamento_estafeta > 0 else None,
                cupao_compensacao_codigo=cupao_compensacao_codigo,
                alerta_taxa_cancelamento_parceiro=alerta_taxa_cancelamento_parceiro,
                lancamentos_ledger_ids=lancamentos_ledger_ids,
                gateway_operacao=gateway_operacao,
                gateway_status=gateway_status,
            )

            logger.info(
                "[CANCELAMENTO] Concluído [Secção 6.10]: Pedido %s | Por: %s | Reembolso: %d | Parceiro: %d | Estafeta: %d",
                pedido.id,
                quem_cancela_normalizado,
                reembolso_cliente,
                pagamento_parceiro,
                pagamento_estafeta,
            )

            return resultado.to_dict()

    @classmethod
    def _verificar_limiar_cancelamento_parceiro(cls, loja: ParceiroLoja) -> bool:
        """
        RN-104 e RN-108:
        Calcula a taxa percentual de cancelamento da loja no mês corrente.
        Se ultrapassar 5.0%, emite alerta nos registos e na cache Redis.
        """
        agora = timezone.now()
        inicio_mes = agora.replace(day=1, hour=0, minute=0, second=0, microsecond=0)

        total_pedidos_mes = Pedido.objects.filter(
            loja=loja,
            data_criacao__gte=inicio_mes,
        ).count()

        cancelamentos_parceiro = EventoPedido.objects.filter(
            pedido__loja=loja,
            tipo_evento=EventoPedido.TipoEvento.ORDER_CANCELLED,
            autor__startswith="parceiro",
            timestamp__gte=inicio_mes,
        ).count() + 1

        taxa_cancelamento = (cancelamentos_parceiro / max(1, total_pedidos_mes)) * 100.0

        if taxa_cancelamento > 5.0:
            logger.warning(
                "[RN-104 / RN-108] ALERTA CRÍTICO: Loja '%s' (NIF: %s) ultrapassou o limiar de 5%% "
                "de cancelamentos no mês corrente (Taxa: %.2f%%). Suspensão temporária recomendada.",
                loja.nome,
                loja.nif,
                taxa_cancelamento,
            )
            cache.set(f"partner:cancellation_alert_5pct:{loja.id}", taxa_cancelamento, timeout=86400 * 30)
            return True

        return False

    @classmethod
    def _emitir_cupao_compensacao_cliente(cls, cliente: Any) -> str:
        """
        RN-106: Emite automaticamente um cupão de desconto promocional
        financiado pela plataforma para compensar o cliente por cancelamento por timeout.
        """
        codigo_cupao = f"COMP-{uuid.uuid4().hex[:8].upper()}"
        valor_compensacao = cls.DEFAULT_CUPAO_COMPENSACAO_TIMEOUT_CENTIMOS
        agora = timezone.now()

        CupaoDesconto.objects.create(
            codigo=codigo_cupao,
            tipo_desconto=CupaoDesconto.TipoDesconto.FIXO,
            valor=valor_compensacao,
            validade_inicio=agora,
            validade_fim=agora + timezone.timedelta(days=30),
            montante_minimo_pedido=0,
            limite_global_uso=1,
            limite_por_utilizador=1,
            financiador=CupaoDesconto.FinanciadorCupao.PLATAFORMA,
        )

        logger.info(
            "[RN-106] Cupão de compensação %s (Valor: %d) emitido com sucesso para cliente %s",
            codigo_cupao,
            valor_compensacao,
            getattr(cliente, "id", None),
        )

        return codigo_cupao


# ==============================================================================
# FUNÇÃO RETROCOMPATÍVEL: processar_cancelamento_pedido
# ==============================================================================

def processar_cancelamento_pedido(
    pedido_id: str | uuid.UUID,
    quem_cancela: str,
    motivo: str,
    ator_id: str | None = None,
) -> dict[str, Any]:
    """
    Função de compatibilidade que delega diretamente na classe OrderCancellationProcessor.
    """
    return OrderCancellationProcessor.processar_cancelamento(
        pedido_id=pedido_id,
        quem_cancela=quem_cancela,
        motivo=motivo,
        ator_id=ator_id,
    )
