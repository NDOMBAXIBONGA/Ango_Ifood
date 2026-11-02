"""
Tarefas assíncronas Celery e utilitários de invalidação de cache Redis para o catálogo (RN-015, RN-020).
Garante que alterações de preço ou indisponibilidade de itens (`is_disponivel=False`)
são refletidas instantaneamente na cache e propagadas aos clientes em bem menos de 5 minutos (SLA RN-020).
"""
import logging
from typing import Any

from asgiref.sync import async_to_sync
from celery import shared_task
from channels.layers import get_channel_layer
from django.core.cache import cache
from django.utils import timezone

logger = logging.getLogger(__name__)

# TTL máximo da cache de menu conforme RN-020 (5 minutos = 300 segundos)
CATALOG_CACHE_TTL_SECONDS = 300


def obter_chaves_cache_loja(loja_id: str) -> list[str]:
    """Devolve as chaves Redis associadas ao menu e descoberta de uma loja."""
    return [
        f"catalog:store:{loja_id}:menu:v1",
        f"catalog:store:{loja_id}:categories:v1",
        f"catalog:store:{loja_id}:items:available:v1",
    ]


def invalidar_cache_catalogo_imediato(
    loja_id: str,
    item_id: str | None = None,
    is_disponivel: bool | None = None,
    motivo: str = "catalog_update",
) -> dict[str, Any]:
    """
    RN-015 / RN-020: Limpa instantaneamente as chaves de cache Redis da loja e do item,
    e grava um marcador de versão de catálogo com TTL de 5 minutos (300 s).
    """
    chaves = obter_chaves_cache_loja(str(loja_id))
    if item_id:
        chaves.append(f"catalog:item:{item_id}:detail:v1")

    cache.delete_many(chaves)

    versao_payload = {
        "loja_id": str(loja_id),
        "item_id": str(item_id) if item_id else None,
        "is_disponivel": is_disponivel,
        "motivo": motivo,
        "atualizado_em": timezone.now().isoformat(),
    }
    cache.set(
        f"catalog:store:{loja_id}:last_invalidation",
        versao_payload,
        timeout=CATALOG_CACHE_TTL_SECONDS,
    )
    return versao_payload


@shared_task(
    name="catalog.sincronizar_alteracao_item_menu",
    bind=True,
    max_retries=3,
    default_retry_delay=5,
)
def sincronizar_alteracao_item_menu_task(
    self: Any,
    loja_id: str,
    item_id: str,
    nome_item: str,
    is_disponivel: bool,
    preco: int,
    motivo: str = "item_updated",
) -> dict[str, Any]:
    """
    RN-015 / RN-020: Tarefa assíncrona Celery disparada sempre que um item do menu é atualizado
    (especialmente quando `is_disponivel=False` ou quando o preço é alterado).
    1. Reforça a invalidação da cache Redis da loja/item.
    2. Emite evento em tempo real via Django Channels (`RedisChannelLayer`) para o grupo da loja,
       removendo ou atualizando o item na vista dos clientes imediatamente (SLA < 5 min).
    """
    try:
        versao_info = invalidar_cache_catalogo_imediato(
            loja_id=loja_id,
            item_id=item_id,
            is_disponivel=is_disponivel,
            motivo=motivo,
        )

        channel_layer = get_channel_layer()
        if channel_layer is not None:
            async_to_sync(channel_layer.group_send)(
                f"catalog_store_{loja_id}",
                {
                    "type": "catalog.item.updated",
                    "loja_id": str(loja_id),
                    "item_id": str(item_id),
                    "nome": nome_item,
                    "is_disponivel": is_disponivel,
                    "preco": preco,
                    "motivo": motivo,
                    "timestamp": versao_info["atualizado_em"],
                },
            )

        logger.info(
            "RN-015 / RN-020 [CatalogSync]: Cache invalidada e evento emitido para loja=%s, "
            "item=%s (%s), is_disponivel=%s, preco=%d, motivo=%s.",
            loja_id,
            item_id,
            nome_item,
            is_disponivel,
            preco,
            motivo,
        )
        return versao_info
    except Exception as exc:
        logger.exception(
            "Erro ao sincronizar alteração de catálogo (loja=%s, item=%s): %s",
            loja_id,
            item_id,
            exc,
        )
        raise self.retry(exc=exc)
