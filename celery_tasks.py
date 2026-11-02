"""
Tarefas assíncronas do Celery com integração Redis para o sistema distribuído ('orders' e 'logistics').
Implementa rigorosamente as regras RN-075, RN-086 e os Parâmetros da Secção 8:
- RN-075: Timeout de aceitação pelo parceiro com cancelamento automático, rotina de reembolso integral
  ao cliente, registo imutável de auditoria e lembrete reforçado aos 90 segundos.
- RN-086: Timeout de 30 segundos por oferta a estafeta individual, expiração de oferta, exclusão da fila
  de prioridade da corrida e expansão geográfica incremental do raio de busca via PostGIS para o próximo estafeta.
"""
from __future__ import annotations

import logging
import uuid
from decimal import Decimal
from typing import Any

from celery import shared_task
from django.conf import settings
from django.contrib.gis.db.models.functions import Distance
from django.contrib.gis.measure import D
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import EventoPedido, LivroRazaoLedger, Pedido
from apps.orders.state_machine import OrderStateMachine

logger = logging.getLogger(__name__)

# =============================================================================
# CONSTANTES E PARÂMETROS DISTRIBUÍDOS DA SECÇÃO 8 (RN-075, RN-086)
# =============================================================================

# Secção 8 / RN-075: Tempo limite padrão para aceitação da loja (3 minutos = 180 segundos)
DEFAULT_TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS: int = getattr(
    settings,
    "TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS",
    180,  # 3 minutos por defeito conforme especificação da Secção 8
)

# RN-075: Intervalo para envio de lembrete sonoro/push reforçado ao parceiro (90 segundos)
INTERVALO_LEMBRETE_REFORCADO_SEGUNDOS: int = 90

# Secção 8 / RN-086: Janela estrita de 30 segundos para o estafeta aceitar a oferta de corrida
TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS: int = getattr(
    settings,
    "TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS",
    30,  # 30 segundos
)

# Secção 8 / RN-086: Degraus de expansão geográfica do raio de busca (em km)
RAIO_DESPACHO_INICIAL_KM: Decimal = Decimal("2.0")
INCREMENTO_RAIO_DESPACHO_KM: Decimal = Decimal("1.5")
RAIO_DESPACHO_MAXIMO_PADRAO_KM: Decimal = Decimal("10.0")

# Prefixos de chaves Redis para coordenação de estado e filas de despacho
REDIS_KEY_OFERTA_ESTAFETA = "logistics:offer:{entrega_id}:{estafeta_id}"
REDIS_KEY_EXCLUIDOS_CORRIDA = "logistics:excluded_couriers:{entrega_id}"
REDIS_KEY_RAIO_ATUAL_CORRIDA = "logistics:search_radius:{entrega_id}"
REDIS_KEY_LOCK_DESPACHO = "logistics:dispatch_lock:{entrega_id}"


# =============================================================================
# 1. TAREFA: TIMEOUT DE ACEITAÇÃO DO PARCEIRO (RN-075, SECÇÃO 8)
# =============================================================================

@shared_task(
    name="celery_tasks.task_timeout_aceitacao_parceiro",
    bind=True,
    max_retries=3,
    default_retry_delay=10,
    autoretry_for=(Exception,),
    dont_autoretry_for=(Pedido.DoesNotExist,),
)
def task_timeout_aceitacao_parceiro(
    self,
    pedido_id: str,
    timeout_segundos: int = DEFAULT_TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS,
) -> dict[str, Any]:
    """
    RN-075 / Secção 8:
    Executada X minutos (default=3 minutos) após o pedido entrar em 'AGUARDA_PARCEIRO'.
    1. Verifica se o pedido ainda se encontra no estado 'AGUARDA_PARCEIRO'.
    2. Se sim, altera automaticamente o estado para 'REJEITADO' com o ator 'SISTEMA'.
    3. Executa a rotina de reembolso integral ao cliente (lançamentos no Livro Razão Ledger).
    4. Regista o log imutável de auditoria em `EventoPedido`.
    """
    logger.info(
        "[RN-075] A validar timeout de aceitação do parceiro: pedido_id=%s (timeout=%ss)",
        pedido_id,
        timeout_segundos,
    )

    with transaction.atomic():
        try:
            pedido = (
                Pedido.objects.select_for_update()
                .select_related("loja", "cliente")
                .get(pk=pedido_id)
            )
        except Pedido.DoesNotExist:
            logger.error("[RN-075] Pedido %s não encontrado no timeout de aceitação.", pedido_id)
            return {"status": "pedido_nao_encontrado", "pedido_id": pedido_id}

        # Se o parceiro já aceitou, rejeitou ou o cliente cancelou antes do prazo, ignora
        if pedido.estado != Pedido.EstadoPedido.AGUARDA_PARCEIRO:
            logger.info(
                "[RN-075] Pedido %s já não está em AGUARDA_PARCEIRO (estado atual: '%s'). Timeout ignorado.",
                pedido_id,
                pedido.estado,
            )
            return {
                "status": "ignorado_estado_divergente",
                "pedido_id": pedido_id,
                "estado_atual": pedido.estado,
            }

        # RN-075: Altera automaticamente o estado para REJEITADO com o ator 'SISTEMA'
        motivo_rejeicao = (
            f"RN-075: Rejeição automática por timeout de aceitação da loja "
            f"após {timeout_segundos} segundos."
        )

        pedido, evento_rejeicao, transitou = OrderStateMachine.transitar_estado(
            pedido_id=pedido.id,
            novo_estado=Pedido.EstadoPedido.REJEITADO,
            ator="SISTEMA",
            dados_adicionais={
                "motivo": motivo_rejeicao,
                "timeout_segundos": timeout_segundos,
                "loja_id": str(pedido.loja_id),
                "loja_nome": pedido.loja.nome,
                "regra": "RN-075",
            },
        )

        # RN-075: Executa a rotina de reembolso integral ao cliente
        reembolso_info = _executar_reembolso_integral_cliente(
            pedido=pedido,
            motivo=motivo_rejeicao,
            ator="SISTEMA",
        )

        logger.warning(
            "[RN-075] Pedido %s rejeitado com sucesso pelo SISTEMA. Reembolso processado: %s",
            pedido_id,
            reembolso_info,
        )

        return {
            "status": "rejeitado_por_timeout",
            "pedido_id": str(pedido.id),
            "novo_estado": pedido.estado,
            "reembolso": reembolso_info,
            "evento_id": str(evento_rejeicao.id) if evento_rejeicao else None,
        }


# Alias canónico conforme RN-075
task_monitorizar_timeout_aceitacao_parceiro = task_timeout_aceitacao_parceiro



@shared_task(
    name="celery_tasks.task_lembrete_reforcado_parceiro",
    bind=True,
    max_retries=2,
    default_retry_delay=5,
)
def task_lembrete_reforcado_parceiro(self, pedido_id: str) -> bool:
    """
    RN-075: Executada aos 90 segundos após o pedido entrar em 'AGUARDA_PARCEIRO'.
    Verifica se o pedido continua pendente de aceitação pela loja. Se continuar,
    emite um alerta reforçado (sonoro/push de alta prioridade e WebSocket via Redis)
    para o terminal/tablet do parceiro comercial.
    """
    try:
        pedido = Pedido.objects.select_related("loja").get(pk=pedido_id)
        if pedido.estado == Pedido.EstadoPedido.AGUARDA_PARCEIRO:
            logger.warning(
                "[RN-075] Lembrete sonoro/push reforçado emitido aos 90s para a loja '%s' (Pedido %s).",
                pedido.loja.nome,
                pedido_id,
            )
            # Notifica canais de mensageria em tempo real / WebSocket
            _notificar_lembrete_tablet_loja(pedido)
            return True
        return False
    except Pedido.DoesNotExist:
        return False


def _executar_reembolso_integral_cliente(
    pedido: Pedido,
    motivo: str,
    ator: str,
) -> dict[str, Any]:
    """
    RN-075 e Secção 7.3: Rotina de estorno e reembolso financeiro integral ao cliente.
    Cria lançamentos imutáveis de dupla entrada no Livro Razão Ledger:
    - Conta de Origem: GATEWAY / PLATAFORMA
    - Conta de Destino: CLIENTE
    - Regista evento de auditoria `payment.refunded`.
    """
    total_reembolso = pedido.total_cobrado

    # 0. Reversão no Gateway bancário (RN-066, RN-070)
    try:
        from apps.orders.payment_service import PaymentGatewayService
        PaymentGatewayService.cancelar_autorizacao_estorno(pedido=pedido, motivo=motivo)
    except Exception as exc:
        logger.error("[RN-075] Erro ao comunicar estorno com o gateway de pagamento: %s", exc)

    # 1. Registo de dupla entrada imutável no Livro Razão (Secção 7.3 e RN-150)
    lancamento_ledger = None
    if total_reembolso > 0:
        lancamento_ledger = LivroRazaoLedger.objects.create(
            referencia_pedido=pedido,
            conta_origem=LivroRazaoLedger.ContaContabil.PLATAFORMA,
            conta_destino=LivroRazaoLedger.ContaContabil.CLIENTE,
            debito=total_reembolso,
            credito=total_reembolso,
        )

    # 2. Registo imutável de evento financeiro de auditoria (Secção 12.1)
    evento_reembolso = EventoPedido.objects.create(
        pedido=pedido,
        tipo_evento=EventoPedido.TipoEvento.PAYMENT_REFUNDED,
        autor=ator,
        dados_adicionais={
            "montante_reembolsado": total_reembolso,
            "motivo": motivo,
            "metodo_pagamento": pedido.metodo_pagamento,
            "ledger_id": str(lancamento_ledger.id) if lancamento_ledger else None,
            "regra": "RN-075",
        },
    )

    return {
        "montante_reembolsado": total_reembolso,
        "evento_reembolso_id": str(evento_reembolso.id),
        "ledger_id": str(lancamento_ledger.id) if lancamento_ledger else None,
    }


def _notificar_lembrete_tablet_loja(pedido: Pedido) -> None:
    """Emite evento de alta prioridade para o WebSocket do parceiro no Redis."""
    cache_channel = f"partner:store:{pedido.loja_id}:urgent_alerts"
    payload = {
        "tipo": "ALERTA_90S_TIMEOUT_IMINENTE",
        "pedido_id": str(pedido.id),
        "tempo_restante_segundos": 90,
        "mensagem": "Atenção: restam 90 segundos para aceitar o pedido antes de cancelamento automático!",
    }
    # Publica na chave/canal Redis para consumo por Django Channels ou push gateway
    cache.set(cache_channel, payload, timeout=120)


# =============================================================================
# 2. TAREFA: TIMEOUT DE OFERTA DE ESTAFETA E EXPANSÃO (RN-086, SECÇÃO 8)
# =============================================================================

@shared_task(
    name="celery_tasks.task_timeout_oferta_estafeta",
    bind=True,
    max_retries=3,
    default_retry_delay=5,
    autoretry_for=(Exception,),
    dont_autoretry_for=(Entrega.DoesNotExist,),
)
def task_timeout_oferta_estafeta(
    self,
    entrega_id: str,
    estafeta_id: str,
) -> dict[str, Any]:
    """
    RN-086 / Secção 8:
    Executada exatamente 30 segundos após uma oferta ser enviada a um estafeta específico.
    1. Verifica se a entrega continua no estado pendente de atribuição ('PENDENTE').
    2. Se o estafeta não aceitou no prazo de 30 segundos:
       - Marca a oferta individual como expirada em Redis.
       - Adiciona o estafeta ao conjunto de excluídos daquela corrida.
       - Dispara o algoritmo de despacho para procurar o próximo estafeta elegível,
         expandindo o raio de procura geograficamente em PostGIS.
    """
    logger.info(
        "[RN-086] A verificar timeout de oferta de 30s: entrega_id=%s estafeta_id=%s",
        entrega_id,
        estafeta_id,
    )

    # 1. Verifica se a oferta já foi aceite ou resolvida via Redis
    chave_oferta = REDIS_KEY_OFERTA_ESTAFETA.format(
        entrega_id=entrega_id,
        estafeta_id=estafeta_id,
    )
    status_oferta = cache.get(chave_oferta)

    if status_oferta == "ACEITE":
        logger.info(
            "[RN-086] Oferta da entrega %s já foi aceite pelo estafeta %s. Timeout ignorado.",
            entrega_id,
            estafeta_id,
        )
        return {"status": "oferta_ja_aceite", "entrega_id": entrega_id, "estafeta_id": estafeta_id}

    with transaction.atomic():
        try:
            entrega = (
                Entrega.objects.select_for_update()
                .select_related("pedido", "pedido__loja")
                .get(pk=entrega_id)
            )
        except Entrega.DoesNotExist:
            logger.error("[RN-086] Entrega %s não encontrada no timeout da oferta.", entrega_id)
            return {"status": "entrega_nao_encontrada", "entrega_id": entrega_id}

        # Se a entrega já foi atribuída a outro estafeta ou cancelada, encerra o ciclo
        if entrega.estado_entrega != Entrega.EstadoEntrega.PENDENTE:
            logger.info(
                "[RN-086] Entrega %s já não se encontra PENDENTE (estado: '%s').",
                entrega_id,
                entrega.estado_entrega,
            )
            return {
                "status": "entrega_ja_atribuida",
                "entrega_id": entrega_id,
                "estado": entrega.estado_entrega,
            }

        # 2. Marca a oferta como expirada em Redis (RN-086)
        cache.set(chave_oferta, "EXPIRADA", timeout=3600)

        # 3. Adiciona o estafeta à lista de exclusão/rejeição desta entrega
        chave_excluidos = REDIS_KEY_EXCLUIDOS_CORRIDA.format(entrega_id=entrega_id)
        estafetas_excluidos: set[str] = set(cache.get(chave_excluidos) or [])
        estafetas_excluidos.add(str(estafeta_id))
        cache.set(chave_excluidos, list(estafetas_excluidos), timeout=3600)

        logger.warning(
            "[RN-086] Oferta expirou para o estafeta %s na entrega %s. Total de estafetas excluídos: %d",
            estafeta_id,
            entrega_id,
            len(estafetas_excluidos),
        )

        # Regista evento de auditoria da expiração da oferta (Secção 12.1)
        EventoPedido.objects.create(
            pedido=entrega.pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_FAILED,
            autor="SISTEMA:DESPACHO",
            dados_adicionais={
                "evento": "oferta_estafeta_expirada",
                "estafeta_id": str(estafeta_id),
                "entrega_id": str(entrega_id),
                "motivo": "RN-086: Sem resposta no prazo de 30 segundos",
                "timeout_segundos": TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS,
            },
        )

        # 4. Chama o algoritmo de despacho para avançar imediatamente para o próximo estafeta da fila (RN-086)
        from apps.logistics.tasks import avancar_proximo_estafeta_fila
        resultado_proximo = avancar_proximo_estafeta_fila(entrega_id=entrega_id)

        return {
            "status": "oferta_expirada_e_redespachada",
            "entrega_id": entrega_id,
            "estafeta_expirado": estafeta_id,
            "proximo_estafeta": resultado_proximo,
        }


# =============================================================================
# 3. ALGORITMO DE DESPACHO COM EXPANSÃO GEOGRÁFICA INCREMENTAL (RN-086)
# =============================================================================

def despachar_proximo_estafeta(
    entrega: Entrega,
    estafetas_excluidos: set[str],
) -> dict[str, Any]:
    """
    RN-086 e Secção 8:
    Localiza o próximo estafeta elegível expandindo progressivamente o raio de busca em PostGIS.
    - Raio inicial: 2.0 km
    - Incremento a cada iteração sem candidatos: +1.5 km
    - Teto máximo: raio_entrega_km da loja ou 10.0 km
    - Critérios de ordenação: proximidade PostGIS (`ST_Distance`) e reputação (`score_reputacao`).
    """
    entrega_id_str = str(entrega.id)
    ponto_loja = entrega.pedido.loja.geolocalizacao
    raio_maximo_loja = Decimal(str(entrega.pedido.loja.raio_entrega_km or RAIO_DESPACHO_MAXIMO_PADRAO_KM))

    # Obtém o raio de busca atual a partir do Redis (ou inicia no raio inicial de 2.0 km)
    chave_raio = REDIS_KEY_RAIO_ATUAL_CORRIDA.format(entrega_id=entrega_id_str)
    raio_atual_raw = cache.get(chave_raio)
    raio_atual = Decimal(str(raio_atual_raw)) if raio_atual_raw else RAIO_DESPACHO_INICIAL_KM

    # Expande o raio incrementalmente caso a tentativa anterior tenha expirado
    if raio_atual_raw is not None:
        raio_atual = min(raio_atual + INCREMENTO_RAIO_DESPACHO_KM, raio_maximo_loja)
    cache.set(chave_raio, str(raio_atual), timeout=3600)

    logger.info(
        "[RN-086] A procurar estafetas elegíveis para entrega %s num raio de %s km (excluídos: %d)",
        entrega_id_str,
        raio_atual,
        len(estafetas_excluidos),
    )

    # Consulta geoespacial otimizada em PostGIS (SRID 4326):
    # - Onboarding aprovado e status online ativo (RN-082, RN-083)
    # - Exclui estafetas que já recusaram ou deixaram expirar a oferta desta corrida (RN-086)
    # - Filtra por distância esférica dentro do raio expandido
    # - Ordena por distância linear crescente e score de reputação decrescente
    candidato = (
        Estafeta.objects.filter(
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao__isnull=False,
            ultima_geolocalizacao__distance_lte=(ponto_loja, D(km=float(raio_atual))),
        )
        .exclude(id__in=estafetas_excluidos)
        .annotate(distancia_loja=Distance("ultima_geolocalizacao", ponto_loja))
        .order_dict_by_dispatch()
        .first()
    ) if hasattr(Estafeta.objects, "order_dict_by_dispatch") else (
        Estafeta.objects.filter(
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao__isnull=False,
            ultima_geolocalizacao__distance_lte=(ponto_loja, D(km=float(raio_atual))),
        )
        .exclude(id__in=estafetas_excluidos)
        .annotate(distancia_loja=Distance("ultima_geolocalizacao", ponto_loja))
        .order_by("distancia_loja", "-score_reputacao")
        .first()
    )

    if candidato is not None:
        candidato_id_str = str(candidato.id)
        distancia_m = getattr(candidato, "distancia_loja", None)
        distancia_metros_int = int(distancia_m.m) if hasattr(distancia_m, "m") else 0

        # Grava a nova oferta pendente em Redis com TTL de 35 segundos
        chave_nova_oferta = REDIS_KEY_OFERTA_ESTAFETA.format(
            entrega_id=entrega_id_str,
            estafeta_id=candidato_id_str,
        )
        cache.set(chave_nova_oferta, "OFERECIDA", timeout=35)

        # Regista evento imutável de despacho da oferta (Secção 12.1)
        EventoPedido.objects.create(
            pedido=entrega.pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_OFFERED,
            autor="SISTEMA:DESPACHO",
            dados_adicionais={
                "entrega_id": entrega_id_str,
                "estafeta_id": candidato_id_str,
                "estafeta_nome": candidato.utilizador.nome,
                "distancia_metros": distancia_metros_int,
                "raio_pesquisa_km": str(raio_atual),
                "prazo_resposta_segundos": TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS,
            },
        )

        # Agenda a tarefa de timeout regressivo estrito de 30 segundos para o novo candidato (RN-086)
        task_timeout_oferta_estafeta.apply_async(
            args=[entrega_id_str, candidato_id_str],
            countdown=TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS,
        )

        logger.info(
            "[RN-086] Nova oferta enviada: entrega_id=%s para estafeta_id=%s (%s m, raio %s km)",
            entrega_id_str,
            candidato_id_str,
            distancia_metros_int,
            raio_atual,
        )

        return {
            "encontrado": True,
            "estafeta_id": candidato_id_str,
            "raio_km": str(raio_atual),
            "distancia_metros": distancia_metros_int,
        }

    # Se nenhum candidato foi encontrado no raio atual e ainda não atingiu o raio máximo,
    # agenda nova tentativa de expansão com pequeno atraso (backoff de 5s)
    if raio_atual < raio_maximo_loja:
        logger.info(
            "[RN-086] Sem estafetas no raio de %s km. A agendar expansão para próxima tentativa.",
            raio_atual,
        )
        task_tentar_expansao_despacho.apply_async(
            args=[entrega_id_str],
            countdown=5,
        )
        return {
            "encontrado": False,
            "em_expansao": True,
            "raio_atual_km": str(raio_atual),
            "raio_maximo_km": str(raio_maximo_loja),
        }

    # Se esgotou o raio máximo da loja sem estafetas disponíveis, alerta a torre de controlo
    logger.error(
        "[RN-086 / RN-089] Alerta de escassez crítica: nenhum estafeta disponível para entrega %s "
        "após atingir o raio máximo de %s km.",
        entrega_id_str,
        raio_maximo_loja,
    )
    cache.set(f"logistics:shortage_alert:{entrega_id_str}", True, timeout=1800)

    return {
        "encontrado": False,
        "em_expansao": False,
        "alerta_escassez": True,
        "raio_maximo_atingido_km": str(raio_maximo_loja),
    }


@shared_task(name="celery_tasks.task_tentar_expansao_despacho")
def task_tentar_expansao_despacho(entrega_id: str) -> None:
    """Tarefa auxiliar para retomar a busca de estafetas com raio expandido."""
    try:
        entrega = Entrega.objects.select_related("pedido", "pedido__loja").get(pk=entrega_id)
        if entrega.estado_entrega == Entrega.EstadoEntrega.PENDENTE:
            chave_excluidos = REDIS_KEY_EXCLUIDOS_CORRIDA.format(entrega_id=entrega_id)
            estafetas_excluidos: set[str] = set(cache.get(chave_excluidos) or [])
            despachar_proximo_estafeta(entrega, estafetas_excluidos)
    except Entrega.DoesNotExist:
        pass

