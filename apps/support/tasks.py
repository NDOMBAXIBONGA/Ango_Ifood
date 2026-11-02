"""
Tarefas Assíncronas do Celery para a aplicação 'support'.
Implementa o SLA de suporte emergencial para incidentes de segurança alimentar (RN-139, RN-140).
"""
from __future__ import annotations

import logging
from celery import shared_task
from django.core.cache import cache
from django.utils import timezone

logger = logging.getLogger("support.sla")


@shared_task(
    name="apps.support.tasks.task_escalar_alerta_incidente_seguranca_5min",
    bind=True,
    max_retries=3,
    default_retry_delay=10,
)
def task_escalar_alerta_incidente_seguranca_5min(self, ticket_id: str) -> dict[str, str]:
    """
    RN-139 / RN-140 / Secção 8.1:
    Escalamento imediato de alerta para a equipa médica e de operações no backoffice
    em menos de 5 minutos sempre que for registado um incidente de segurança alimentar
    (reação alérgica grave, intoxicação alimentar).
    """
    logger.critical(
        "ALERTA CRÍTICO DE SAÚDE PÚBLICA (RN-139 / RN-140): Incidente de segurança alimentar "
        "com Prioridade Alta/Crítica registado para o Ticket %s! Escalamento imediato iniciado.",
        ticket_id,
    )

    try:
        from apps.support.models import TicketDisputa
        ticket = TicketDisputa.objects.select_related("pedido", "pedido__loja", "pedido__cliente").get(pk=ticket_id)

        # Regista a notificação emergencial no Redis para painéis em tempo real
        cache_key = f"support:emergency_alert:{ticket_id}"
        agora = timezone.now()
        alerta_dados = {
            "ticket_id": str(ticket.id),
            "pedido_id": str(ticket.pedido_id),
            "loja_nome": ticket.pedido.loja.nome if ticket.pedido.loja else "Desconhecida",
            "cliente_nome": ticket.pedido.cliente.nome if ticket.pedido.cliente else "Desconhecido",
            "tipo_incidente": ticket.tipo_incidente,
            "prioridade": ticket.prioridade,
            "motivo": ticket.motivo,
            "timestamp_alerta": agora.isoformat(),
            "sla_limite_minutos": 5,
        }
        cache.set(cache_key, alerta_dados, timeout=86400)  # 24 horas

        # Marca como escalado no banco
        if not ticket.is_alerta_escalado:
            ticket.is_alerta_escalado = True
            ticket.save(update_fields=["is_alerta_escalado"])

        logger.info(
            "Alerta de incidente de segurança %s escalado com sucesso dentro do SLA de 5 minutos (RN-139).",
            ticket_id,
        )
        return {"status": "ESCALADO", "ticket_id": ticket_id, "timestamp": agora.isoformat()}

    except Exception as exc:
        logger.error("Erro ao escalar incidente de segurança %s: %s", ticket_id, exc)
        raise self.retry(exc=exc)

