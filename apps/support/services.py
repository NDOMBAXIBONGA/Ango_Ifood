"""
Camada de Serviços de Negócio para Suporte, Disputas e Compensações ('support').
Módulo: apps/support/services.py

Implementa com rigor técnico:
- RN-106: Limite de compensação por perfil (Agente <= 3.000 Kz / 300.000 cêntimos; exige Supervisor se exceder);
- RN-141: Mediação e resolução fundamentada de disputas entre cliente e parceiro (Procedente_Cliente, Procedente_Parceiro, Improcedente);
- RN-142: Registo e auditoria imutável de decisões administrativas proferidas no suporte;
- Secção 7.3: Lançamentos de compensação no Livro Razão (Ledger) de dupla entrada;
- Secção 5.2 / 12.1: Registo imutável de eventos de domínio em EventoPedido.
"""
from __future__ import annotations

import logging
import uuid
from decimal import Decimal
from typing import Any, Optional

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.accounts.models import CustomUser
from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.orders.models import Pedido
from apps.support.models import Parametro, TicketDisputa

logger = logging.getLogger("support.services")

# Limite máximo padrão para compensação direta concedida por perfil 'Agente' (RN-106: 3.000 Kz = 300.000 cêntimos)
DEFAULT_LIMITE_COMPENSACAO_AGENTE_CENTIMOS: int = 300000


class DisputeServiceError(Exception):
    """Exceção base para erros durante a mediação e resolução de disputas."""

    def __init__(self, mensagem: str, codigo: str = "DISPUTE_ERROR", detalhes: Optional[dict[str, Any]] = None) -> None:
        super().__init__(mensagem)
        self.mensagem = mensagem
        self.codigo = codigo
        self.detalhes = detalhes or {}


class CompensationLimitExceededError(DisputeServiceError):
    """Lançada quando um agente excede o teto de 3.000 Kz sem aprovação de um supervisor (RN-106)."""
    pass


class DisputeResolutionService:
    """
    Serviço transacional para resolução e auditoria imutável de disputas e incidentes de suporte.
    """

    @classmethod
    def obter_limite_compensacao_agente(cls) -> int:
        """
        Recupera o teto de compensação do agente parametrizado na tabela de Governação (Secção 8, RN-106).
        Valor padrão: 300.000 cêntimos (3.000 Kz).
        """
        param = Parametro.objects.filter(
            chave="LIMITE_COMPENSACAO_AGENTE_CENTIMOS",
            ambito__in=[Parametro.AmbitoParametro.GLOBAL, Parametro.AmbitoParametro.PERFIL],
            vigencia_inicio__lte=timezone.now(),
        ).filter(
            models.Q(vigencia_fim__isnull=True) | models.Q(vigencia_fim__gte=timezone.now())
        ).order_by("-versao").first()

        if param and param.valor_numerico is not None:
            return int(param.valor_numerico)

        return getattr(settings, "LIMITE_COMPENSACAO_AGENTE_CENTIMOS", DEFAULT_LIMITE_COMPENSACAO_AGENTE_CENTIMOS)

    @classmethod
    def verificar_eh_supervisor(cls, user: CustomUser) -> bool:
        """
        Verifica se o utilizador possui credenciais de Supervisor ou Administrador no backoffice.
        """
        if not user or not user.is_authenticated:
            return False

        if user.is_superuser or user.is_staff:
            return True

        # Verifica pertença a grupos RBAC com privilégios de supervisão
        grupos = set(user.groups.values_list("name", flat=True))
        if bool(grupos.intersection({"Supervisor", "Supervisores", "Admin", "Administrador", "Gestor"})):
            return True

        # Verifica atributo de cargo/role se existir
        cargo = getattr(user, "cargo", None) or getattr(user, "role", None)
        if cargo in ("supervisor", "admin", "manager"):
            return True

        return False

    @classmethod
    def resolver_disputa(
        cls,
        pedido_id: str | uuid.UUID,
        decisao: str,
        motivo_justificacao: str,
        compensacao_valor: int,
        autor: CustomUser,
        supervisor_aprovador: Optional[CustomUser] = None,
        tipo_incidente: str = TicketDisputa.TipoIncidente.DISPUTA_COMERCIAL,
        prioridade: str = TicketDisputa.PrioridadeTicket.MEDIA,
        ticket_id: Optional[str | uuid.UUID] = None,
    ) -> dict[str, Any]:
        """
        Executa de forma atómica a resolução da disputa, com validação de alçadas (RN-106),
        registo imutável de auditoria (RN-142), liquidação financeira no Livro Razão (Secção 7.3)
        e emissão de eventos de domínio no OMS.

        :param pedido_id: UUID do pedido em litígio.
        :param decisao: 'Procedente_Cliente', 'Procedente_Parceiro' ou 'Improcedente' (RN-141).
        :param motivo_justificacao: Fundamentação técnica detalhada (mín. 10 caracteres).
        :param compensacao_valor: Valor a creditar/compensar em cêntimos (unidades inteiras).
        :param autor: Agente de suporte autenticado que proferiu a decisão.
        :param supervisor_aprovador: Supervisor obrigatório se compensacao_valor > 3.000 Kz (RN-106).
        :param tipo_incidente: Categoria da reclamação (RN-138, RN-140).
        :param prioridade: Prioridade com impacto de SLA (RN-139).
        :param ticket_id: ID de ticket pré-existente (opcional).
        :return: Dicionário estruturado com o resultado da resolução.
        """
        # 1. Validação prévia de Choices da Decisão (RN-141)
        choices_validas = [
            TicketDisputa.DecisaoDisputa.PROCEDENTE_CLIENTE,
            TicketDisputa.DecisaoDisputa.PROCEDENTE_PARCEIRO,
            TicketDisputa.DecisaoDisputa.IMPROCEDENTE,
        ]
        if decisao not in choices_validas:
            raise DisputeServiceError(
                f"RN-141: Decisão '{decisao}' inválida. Choices permitidas: {choices_validas}",
                codigo="INVALID_DECISION_CHOICE",
            )

        if not motivo_justificacao or len(motivo_justificacao.strip()) < 10:
            raise DisputeServiceError(
                "RN-142: O 'motivo_justificacao' é obrigatório e tem de conter pelo menos 10 caracteres.",
                codigo="INVALID_JUSTIFICATION",
            )

        # 2. Validação de Limites de Compensação por Perfil (RN-106 / Secção 8)
        limite_agente = cls.obter_limite_compensacao_agente()
        eh_supervisor_autor = cls.verificar_eh_supervisor(autor)

        if compensacao_valor > limite_agente and not eh_supervisor_autor:
            # Autor é Agente e excedeu o teto: exige supervisor obrigatório
            if not supervisor_aprovador:
                raise CompensationLimitExceededError(
                    f"RN-106: O valor de compensação ({compensacao_valor} cêntimos = {compensacao_valor / 100:.2f} Kz) "
                    f"ultrapassa o limite de alçada do Agente ({limite_agente} cêntimos = {limite_agente / 100:.2f} Kz). "
                    f"É obrigatória a identificação e aprovação de um perfil 'Supervisor'.",
                    codigo="SUPERVISOR_APPROVAL_REQUIRED",
                    detalhes={"limite_agente_centimos": limite_agente, "compensacao_valor": compensacao_valor},
                )

            if not cls.verificar_eh_supervisor(supervisor_aprovador):
                raise DisputeServiceError(
                    f"RN-106: O utilizador aprovador indicado '{supervisor_aprovador.email}' "
                    f"não possui privilégios de Supervisor no sistema.",
                    codigo="INVALID_SUPERVISOR",
                )

        with transaction.atomic():
            # 3. Bloqueio pessimista no Pedido para segurança transacional
            try:
                pedido = (
                    Pedido.objects.select_for_update()
                    .select_related("loja", "cliente")
                    .get(pk=pedido_id)
                )
            except Pedido.DoesNotExist as exc:
                raise DisputeServiceError(
                    f"Pedido com ID '{pedido_id}' não encontrado para resolução de disputa.",
                    codigo="ORDER_NOT_FOUND",
                ) from exc

            # 4. Recupera ou cria a instância de TicketDisputa
            ticket: Optional[TicketDisputa] = None
            if ticket_id:
                ticket = TicketDisputa.objects.select_for_update().filter(pk=ticket_id, pedido=pedido).first()

            if not ticket:
                ticket = TicketDisputa.objects.select_for_update().filter(
                    pedido=pedido,
                    estado__in=[TicketDisputa.EstadoTicket.ABERTO, TicketDisputa.EstadoTicket.EM_ANALISE],
                ).first()

            agora = timezone.now()

            if not ticket:
                # Cria novo ticket já com a resolução
                ticket = TicketDisputa(
                    pedido=pedido,
                    motivo=f"Disputa/Incidente aberto via suporte: {motivo_justificacao[:100]}",
                    tipo_incidente=tipo_incidente,
                    prioridade=prioridade,
                )

            # 5. Aplica os dados da decisão imutável (RN-141 e RN-142)
            ticket.estado = TicketDisputa.EstadoTicket.RESOLVIDO
            ticket.decisao = decisao
            ticket.motivo_justificacao = motivo_justificacao.strip()
            ticket.compensacao_valor = compensacao_valor
            ticket.autor_decisao = autor
            ticket.supervisor_aprovador = supervisor_aprovador if (compensacao_valor > limite_agente and not eh_supervisor_autor) else (supervisor_aprovador or (autor if eh_supervisor_autor else None))
            ticket.data_resolucao = agora
            ticket.save()

            # 6. Efeitos Financeiros e Partidas Dobradas no Livro Razão (Secção 7.3 & RN-150)
            lancamentos_ledger_ids: list[str] = []

            if decisao == TicketDisputa.DecisaoDisputa.PROCEDENTE_CLIENTE and compensacao_valor > 0:
                # Crédito concedido ao Cliente suportado pela plataforma (ou estorno imputado)
                lancamento_compensacao = LivroRazaoLedger.objects.create(
                    referencia_pedido=pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.PLATAFORMA,
                    conta_destino=LivroRazaoLedger.ContaContabil.CLIENTE,
                    debito=compensacao_valor,
                    credito=compensacao_valor,
                )
                lancamentos_ledger_ids.append(str(lancamento_compensacao.id))

                logger.info(
                    "RN-141: Compensação de %d cêntimos concedida ao cliente no Pedido %s via Ledger (Ticket %s).",
                    compensacao_valor,
                    pedido.id,
                    ticket.id,
                )

            elif decisao == TicketDisputa.DecisaoDisputa.PROCEDENTE_PARCEIRO:
                logger.info(
                    "RN-141: Disputa do Pedido %s resolvida favorável ao Parceiro (Ticket %s). Sem penalizações.",
                    pedido.id,
                    ticket.id,
                )

            elif decisao == TicketDisputa.DecisaoDisputa.IMPROCEDENTE:
                logger.info(
                    "RN-141: Disputa do Pedido %s julgada Improcedente pelo suporte (Ticket %s).",
                    pedido.id,
                    ticket.id,
                )

            # 7. Registo Imutável de Auditoria no EventoPedido (Secção 5.2 / 12.1 / RN-142)
            payload_evento = {
                "tipo_evento_suporte": "support.dispute.resolved",
                "ticket_id": str(ticket.id),
                "pedido_id": str(pedido.id),
                "decisao": decisao,
                "motivo_justificacao": motivo_justificacao,
                "compensacao_valor": compensacao_valor,
                "autor_decisao_id": str(autor.id),
                "autor_decisao_email": getattr(autor, "email", "sem_email"),
                "autor_era_supervisor": eh_supervisor_autor,
                "supervisor_aprovador_id": str(ticket.supervisor_aprovador.id) if ticket.supervisor_aprovador else None,
                "lancamentos_ledger_ids": lancamentos_ledger_ids,
                "timestamp_resolucao": agora.isoformat(),
                "regra": "RN-106 / RN-141 / RN-142",
            }

            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.ORDER_REFUNDED if (decisao == TicketDisputa.DecisaoDisputa.PROCEDENTE_CLIENTE and compensacao_valor > 0) else EventoPedido.TipoEvento.ORDER_COMPLETED,
                autor=f"suporte:{autor.email}",
                dados_adicionais=payload_evento,
            )

            logger.info(
                "RN-142: Decisão imutável de suporte registada com sucesso: Ticket %s | Pedido %s | Decisão: %s",
                ticket.id,
                pedido.id,
                decisao,
            )

            return {
                "sucesso": True,
                "mensagem": "Decisão da disputa registada com sucesso com auditoria imutável (RN-142).",
                "ticket_id": str(ticket.id),
                "pedido_id": str(pedido.id),
                "decisao": ticket.decisao,
                "compensacao_valor_centimos": ticket.compensacao_valor,
                "compensacao_valor_kz": round(ticket.compensacao_valor / 100.0, 2),
                "autor_decisao": getattr(autor, "nome", autor.email),
                "supervisor_aprovador": getattr(ticket.supervisor_aprovador, "nome", ticket.supervisor_aprovador.email) if ticket.supervisor_aprovador else None,
                "lancamentos_ledger_ids": lancamentos_ledger_ids,
                "data_resolucao": ticket.data_resolucao.isoformat(),
            }

