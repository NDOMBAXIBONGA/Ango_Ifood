"""
Sinais Django para a aplicação 'support'.
Implementa o gatilho automático de alerta de SLA de Suporte para Incidentes de Segurança (RN-139, RN-140).
"""
import logging
from django.db.models.signals import post_delete, post_save
from django.dispatch import receiver

from apps.support.models import AppBannerDinamico, Parametro, TicketDisputa

logger = logging.getLogger("support.signals")


@receiver([post_save, post_delete], sender=Parametro)
@receiver([post_save, post_delete], sender=AppBannerDinamico)
def invalidar_cache_bootstrap_sistema_post_save(sender, **kwargs) -> None:
    """Invalida a chave de cache de bootstrap sempre que um parâmetro ou banner for alterado."""
    from apps.support.bootstrap_views import invalidate_bootstrap_cache
    invalidate_bootstrap_cache()


@receiver(post_save, sender=TicketDisputa)
def monitorizar_incidente_seguranca_sla_post_save(
    sender,
    instance: TicketDisputa,
    created: bool,
    **kwargs,
) -> None:
    """
    RN-139 e RN-140:
    Sinal disparado na criação de tickets de incidentes de segurança alimentar
    (Reações Alérgicas, Intoxicação Alimentar) com Prioridade Alta ou Crítica.
    Dispara imediatamente a tarefa Celery assíncrona para garantir escalamento em menos de 5 minutos.
    """
    # Apenas na criação inicial ou se não tiver sido escalado previamente
    if not instance.is_alerta_escalado:
        eh_incidente_seguranca = instance.tipo_incidente in (
            TicketDisputa.TipoIncidente.REACAO_ALERGICA,
            TicketDisputa.TipoIncidente.INTOXICACAO_ALIMENTAR,
        )
        eh_prioridade_alta = instance.prioridade in (
            TicketDisputa.PrioridadeTicket.ALTA,
            TicketDisputa.PrioridadeTicket.CRITICA,
        )

        if eh_incidente_seguranca or eh_prioridade_alta:
            logger.warning(
                "RN-139 / RN-140: Incidente de Segurança detectado (Ticket %s | %s | Prioridade %s). "
                "A emitir tarefa Celery de escalamento imediato (< 5 min).",
                instance.id,
                instance.tipo_incidente,
                instance.prioridade,
            )
            from apps.support.tasks import task_escalar_alerta_incidente_seguranca_5min
            task_escalar_alerta_incidente_seguranca_5min.delay(ticket_id=str(instance.id))

