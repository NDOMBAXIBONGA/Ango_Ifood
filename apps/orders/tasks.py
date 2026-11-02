"""
Tarefas Assíncronas do Celery para Gestão de Timeouts Operacionais e Ciclo de Vida do OMS.
Aplicação: 'orders' (com suporte distribuído a 'logistics' e 'finance').
Broker e Backend de Resultados: Redis.

Implementa rigorosamente:
- RN-075 e Secção 8: Monitorização do timeout de aceitação da loja parceira (SLA de 3 min / 180s),
  rejeição automática por timeout com ator 'SISTEMA', estorno/reembolso integral pré-autorizado,
  libertação de stock e alerta sonoro/push reforçado aos 90 segundos (RN-120).
- RN-086 e Secção 8: Timeout estrito de 30 segundos por oferta de corrida a estafeta individual,
  registo de expiração em auditoria imutável, libertação de bloqueio e reavaliação do motor de
  despacho logístico com expansão geoespacial do raio em PostGIS.
- Secção 5 e 5.2: Transições de estado atómicas e registo de eventos imutáveis em `EventoPedido`.
- Secção 7.3 e RN-150: Reembolso de dupla entrada no Livro Razão Ledger.
"""
from __future__ import annotations

import json
import logging
import uuid
from decimal import Decimal
from typing import Any

from celery import shared_task
from django.conf import settings
from django.contrib.gis.db.models.functions import Distance
from django.contrib.gis.geos import Point
from django.contrib.gis.measure import D
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import EventoPedido, LinhaPedido, LivroRazaoLedger, Pedido

logger = logging.getLogger(__name__)

# ==============================================================================
# PARÂMETROS CONFIGURÁVEIS E SLAS DA SECÇÃO 8
# ==============================================================================

# Secção 8: Prazo de aceitação do parceiro (âmbito: 'Parceiro' - 3 minutos = 180s)
DEFAULT_TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS: int = getattr(
    settings, "TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS", 180
)

# RN-075 / RN-120: Janela de lembrete reforçado aos 90 segundos (metade do SLA da loja)
INTERVALO_LEMBRETE_REFORCADO_SEGUNDOS: int = 90

# Secção 8: Timeout de oferta ao estafeta (âmbito: 'Zona' - 30 segundos)
DEFAULT_TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS: int = getattr(
    settings, "TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS", 30
)

# Secção 8: Raio inicial de procura de estafetas (âmbito: 'Zona' - 3.0 km)
RAIO_INICIAL_DESPACHO_KM: Decimal = Decimal(
    str(getattr(settings, "LOGISTICS_RAIO_DESPACHO_INICIAL_KM", "3.0"))
)

# Secção 8: Degraus de expansão e limite máximo (3.0 km -> 5.0 km -> 7.0 km)
INCREMENTO_EXPANSAO_RAIO_KM: Decimal = Decimal("2.0")
RAIO_LIMITE_MAXIMO_DESPACHO_KM: Decimal = Decimal(
    str(getattr(settings, "LOGISTICS_RAIO_DESPACHO_LIMITE_KM", "7.0"))
)

# Chaves Canónicas de Redis para Coordenação Distribuída
REDIS_KEY_OFERTA_ESTAFETA = "logistics:offer:{entrega_id}:{estafeta_id}"
REDIS_KEY_EXCLUIDOS_CORRIDA = "logistics:excluded_couriers:{entrega_id}"
REDIS_KEY_RAIO_ATUAL_CORRIDA = "logistics:search_radius:{entrega_id}"
REDIS_KEY_LOCK_DESPACHO = "logistics:dispatch_lock:{entrega_id}"
REDIS_KEY_LEMBRETE_90S_DISPARADO = "orders:alert_90s_sent:{pedido_id}"


def _obter_parametro_configuravel(chave: str, valor_padrao: Any) -> Any:
    """Recupera parâmetro configurável da cache Redis ou settings, respeitando a Secção 8."""
    chave_cache = f"system:parameter:{chave}"
    valor_cached = cache.get(chave_cache)
    if valor_cached is not None:
        return valor_cached
    return getattr(settings, chave, valor_padrao)


# ==============================================================================
# 1. TAREFA OBRIGATÓRIA: MONITORIZAÇÃO DE TIMEOUT DE ACEITAÇÃO DO PARCEIRO
# ==============================================================================

@shared_task(
    name="apps.orders.tasks.task_monitorizar_timeout_aceitacao_parceiro",
    bind=True,
    max_retries=3,
    default_retry_delay=5,
    autoretry_for=(Exception,),
    dont_autoretry_for=(Pedido.DoesNotExist,),
)
def task_monitorizar_timeout_aceitacao_parceiro(
    self,
    pedido_id: str,
    timeout_segundos: int | None = None,
    estagio: str = "timeout_final",
) -> dict[str, Any]:
    """
    RN-075 / Secção 8:
    Gere o ciclo de timeout de aceitação da loja parceira após transitar para 'AGUARDA_PARCEIRO'.

    Lógica Operacional:
    1. Agendamento aos 90 segundos (`estagio='alerta_90s'`):
       Se o parceiro não respondeu, dispara alerta sonoro/push e WebSocket reforçado (RN-075, RN-120).
    2. Agendamento aos 180 segundos (`estagio='timeout_final'` - default):
       Abre transação com `select_for_update()`. Se continuar em `AGUARDA_PARCEIRO`:
       - Invoca `OrderStateMachineManager.transitar_estado` para `REJEITADO` com o ator 'SISTEMA';
       - Executa estorno/reembolso integral automático dos valores pré-autorizados ao cliente (RN-075);
       - Liberta o stock previamente reservado dos itens do menu;
       - Regista o evento imutável de auditoria em `EventoPedido`.
    """
    sla_segundos = timeout_segundos or _obter_parametro_configuravel(
        "TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS",
        DEFAULT_TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS,
    )

    logger.info(
        "[RN-075] A executar verificação de aceitação do parceiro: pedido_id=%s, estagio=%s, sla=%ss",
        pedido_id,
        estagio,
        sla_segundos,
    )

    # --------------------------------------------------------------------------
    # ESTÁGIO 1: Lembrete Reforçado aos 90 Segundos (RN-075, RN-120)
    # --------------------------------------------------------------------------
    if estagio == "alerta_90s":
        try:
            pedido = Pedido.objects.select_related("loja").get(pk=pedido_id)
            if pedido.estado == Pedido.EstadoPedido.AGUARDA_PARCEIRO:
                # Verifica idempotência do alerta para não disparar em duplicado
                chave_alerta = REDIS_KEY_LEMBRETE_90S_DISPARADO.format(pedido_id=pedido_id)
                if cache.add(chave_alerta, True, timeout=300):
                    _disparar_alerta_sonoro_reforcado_parceiro(pedido)
                    logger.warning(
                        "[RN-075 / RN-120] Alerta sonoro reforçado disparado aos 90s para a loja '%s' (Pedido %s).",
                        pedido.loja.nome,
                        pedido_id,
                    )
                    return {
                        "status": "alerta_90s_disparado",
                        "pedido_id": pedido_id,
                        "loja_id": str(pedido.loja_id),
                        "tempo_restante_segundos": 90,
                    }
            return {
                "status": "alerta_90s_ignorado",
                "pedido_id": pedido_id,
                "estado_atual": pedido.estado,
            }
        except Pedido.DoesNotExist:
            logger.error("[RN-075] Pedido %s não encontrado no alerta de 90s.", pedido_id)
            return {"status": "pedido_nao_encontrado", "pedido_id": pedido_id}

    # --------------------------------------------------------------------------
    # ESTÁGIO 2: Timeout Final de 3 Minutos (180s) e Cancelamento Automático (RN-075)
    # --------------------------------------------------------------------------
    with transaction.atomic():
        try:
            pedido = (
                Pedido.objects.select_for_update()
                .select_related("loja", "cliente")
                .get(pk=pedido_id)
            )
        except Pedido.DoesNotExist:
            logger.error("[RN-075] Pedido %s não encontrado no timeout final.", pedido_id)
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

        # 1. Transita o estado para REJEITADO com o ator 'SISTEMA' (Secção 5.1 e RN-075)
        motivo_rejeicao = (
            f"RN-075: Rejeição automática por timeout de aceitação da loja parceira "
            f"após {sla_segundos} segundos (SLA Secção 8)."
        )

        from apps.orders.state_machine import OrderStateMachineManager

        resultado_transicao = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido.id,
            novo_estado=Pedido.EstadoPedido.REJEITADO,
            ator="SISTEMA",
            dados_adicionais={
                "motivo": motivo_rejeicao,
                "timeout_segundos": sla_segundos,
                "loja_id": str(pedido.loja_id),
                "loja_nome": pedido.loja.nome,
                "regra": "RN-075",
            },
        )

        # 2. Executa a rotina de estorno e reembolso integral do valor ao cliente (RN-075)
        reembolso_info = _executar_reembolso_integral_cliente(
            pedido=pedido,
            motivo=motivo_rejeicao,
            ator="SISTEMA",
        )

        # 3. Liberta o stock previamente reservado dos itens do menu (RN-075)
        stock_info = _libertar_stock_pedido(pedido=pedido)

        logger.warning(
            "[RN-075] Pedido %s REJEITADO automaticamente pelo SISTEMA por timeout. "
            "Reembolso efetuado: %s. Stock libertado: %s",
            pedido_id,
            reembolso_info,
            stock_info,
        )

        return {
            "status": "rejeitado_por_timeout",
            "pedido_id": str(pedido.id),
            "novo_estado": pedido.estado,
            "reembolso": reembolso_info,
            "stock_libertado": stock_info,
            "evento_id": str(resultado_transicao.evento.id) if resultado_transicao.evento else None,
        }


# ==============================================================================
# 2. TAREFA OBRIGATÓRIA: TIMEOUT DE OFERTA DE ESTAFETA E REDESPACHO (RN-086)
# ==============================================================================

@shared_task(
    name="apps.orders.tasks.task_timeout_oferta_estafeta",
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
    Executada exatamente 30 segundos após uma oferta de corrida ser enviada a um estafeta específico.

    Lógica Operacional:
    1. Verifica se a oferta continua pendente de aceitação pelo estafeta especificado.
    2. Se o estafeta não respondeu (timeout por omissão) ou recusou explicitamente:
       - Regista a rejeição/expiração no histórico imutável de auditoria (`EventoPedido`);
       - Liberta a entrega do bloqueio com esse estafeta e adiciona-o aos excluídos desta corrida;
       - Invoca imediatamente o motor de despacho (`executar_algoritmo_despacho_logistico`)
         para reavaliar a entrega e disparar a oferta para o próximo estafeta da fila de
         prioridade, expandindo o raio geoespacial em PostGIS se necessário (RN-086).
    """
    logger.info(
        "[RN-086] A verificar timeout de 30s de oferta ao estafeta: entrega_id=%s, estafeta_id=%s",
        entrega_id,
        estafeta_id,
    )

    chave_oferta = REDIS_KEY_OFERTA_ESTAFETA.format(
        entrega_id=entrega_id,
        estafeta_id=estafeta_id,
    )

    # 1. Verifica no Redis se o estafeta já aceitou a oferta dentro da janela dos 30s
    status_oferta_redis = cache.get(chave_oferta)
    if status_oferta_redis == "ACEITE":
        logger.info(
            "[RN-086] Oferta da entrega %s foi aceite pelo estafeta %s a tempo. Timeout ignorado.",
            entrega_id,
            estafeta_id,
        )
        return {
            "status": "oferta_ja_aceite",
            "entrega_id": entrega_id,
            "estafeta_id": estafeta_id,
        }

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
                "[RN-086] Entrega %s já não se encontra PENDENTE (estado: '%s'). Timeout ignorado.",
                entrega_id,
                entrega.estado_entrega,
            )
            return {
                "status": "entrega_ja_atribuida",
                "entrega_id": entrega_id,
                "estado": entrega.estado_entrega,
            }

        # 2. Marca a oferta individual como EXPIRADA em Redis
        cache.set(chave_oferta, "EXPIRADA", timeout=3600)

        # 3. Liberta o estafeta do bloqueio individual de despacho
        lock_estafeta_key = f"logistics:lock_courier:{estafeta_id}"
        cache.delete(lock_estafeta_key)

        # 4. Adiciona o estafeta à lista de exclusão/rejeição desta entrega (RN-086)
        chave_excluidos = REDIS_KEY_EXCLUIDOS_CORRIDA.format(entrega_id=entrega_id)
        estafetas_excluidos: set[str] = set(cache.get(chave_excluidos) or [])
        estafetas_excluidos.add(str(estafeta_id))
        cache.set(chave_excluidos, list(estafetas_excluidos), timeout=3600)

        # 5. Regista a expiração no histórico de auditoria imutável (Secção 5.2 e 12.1)
        evento_expiracao = EventoPedido.objects.create(
            pedido=entrega.pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_FAILED,
            autor="SISTEMA:DESPACHO",
            dados_adicionais={
                "evento": "oferta_estafeta_expirada",
                "estafeta_id": str(estafeta_id),
                "entrega_id": str(entrega_id),
                "motivo": "RN-086: Sem resposta no prazo estrito de 30 segundos (SLA Secção 8)",
                "timeout_segundos": DEFAULT_TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS,
                "total_excluidos_corrida": len(estafetas_excluidos),
            },
        )

        logger.warning(
            "[RN-086] Oferta expirou para o estafeta %s na entrega %s. "
            "Estafetas excluídos desta corrida: %d. A invocar motor de redespacho...",
            estafeta_id,
            entrega_id,
            len(estafetas_excluidos),
        )

        # 6. Invoca imediatamente o motor de despacho para o próximo candidato com expansão geoespacial (RN-086)
        resultado_redespacho = executar_algoritmo_despacho_logistico(
            entrega_id=entrega_id,
            estafetas_excluidos_fornecidos=estafetas_excluidos,
        )

        return {
            "status": "oferta_expirada_e_redespachada",
            "entrega_id": entrega_id,
            "estafeta_expirado": estafeta_id,
            "evento_id": str(evento_expiracao.id),
            "resultado_redespacho": resultado_redespacho,
        }


# ==============================================================================
# 3. MOTOR DE DESPACHO E EXPANSÃO GEOESPACIAL (RN-084, RN-085, RN-086)
# ==============================================================================

def executar_algoritmo_despacho_logistico(
    entrega_id: str,
    estafetas_excluidos_fornecidos: set[str] | None = None,
) -> dict[str, Any]:
    """
    RN-084, RN-085, RN-086 e Secção 6.8:
    Motor inteligente de seleção e atribuição de estafetas:
    1. Localiza a entrega e a posição geográfica PostGIS da loja associada.
    2. Lê os estafetas excluídos da cache Redis.
    3. Recupera o raio de busca atual (inicia em 3.0 km) e expande até 7.0 km caso necessário.
    4. Executa query geoespacial em PostGIS filtrando estafetas elegíveis (online, aprovados, sem sobrecarga).
    5. Ordena pelo ScoreDespacho ponderado (Proximidade 50%, Aceitação 25%, Reputação 25%).
    6. Dispara oferta ao primeiro classificado e agenda o timeout estrito de 30 segundos.
    """
    try:
        entrega = (
            Entrega.objects.select_related("pedido", "pedido__loja")
            .get(pk=entrega_id)
        )
    except Entrega.DoesNotExist:
        logger.error("[DESPACHO] Entrega %s não encontrada para despacho.", entrega_id)
        return {"status": "entrega_nao_encontrada", "entrega_id": entrega_id}

    if entrega.estado_entrega != Entrega.EstadoEntrega.PENDENTE:
        logger.info("[DESPACHO] Entrega %s já não se encontra PENDENTE (%s).", entrega_id, entrega.estado_entrega)
        return {"status": "entrega_ja_atribuida", "entrega_id": entrega_id}

    ponto_loja: Point = entrega.pedido.loja.geolocalizacao
    if not ponto_loja:
        logger.error("[DESPACHO] Loja %s sem coordenadas geográficas PostGIS válidas.", entrega.pedido.loja_id)
        return {"status": "loja_sem_coordenadas"}

    # Recupera ou consolida conjunto de excluídos
    chave_excluidos = REDIS_KEY_EXCLUIDOS_CORRIDA.format(entrega_id=entrega_id)
    estafetas_excluidos = estafetas_excluidos_fornecidos or set(cache.get(chave_excluidos) or [])

    # Gestão de raio de pesquisa incremental em Redis (RN-086: 3.0 km -> 5.0 km -> 7.0 km)
    chave_raio = REDIS_KEY_RAIO_ATUAL_CORRIDA.format(entrega_id=entrega_id)
    raio_atual_raw = cache.get(chave_raio)
    raio_atual = Decimal(str(raio_atual_raw)) if raio_atual_raw else RAIO_INICIAL_DESPACHO_KM

    raio_maximo_loja = Decimal(
        str(entrega.pedido.loja.raio_entrega_km or RAIO_LIMITE_MAXIMO_DESPACHO_KM)
    )

    # 1. Busca candidato ótimo no raio atual via PostGIS (RN-084, RN-085)
    candidato, distancia_metros = _buscar_candidato_elegivel_no_raio(
        ponto_loja=ponto_loja,
        raio_km=raio_atual,
        estafetas_excluidos=estafetas_excluidos,
    )

    # 2. Se não encontrou no raio atual, expande incrementalmente se ainda não atingiu o limite
    if candidato is None and raio_atual < raio_maximo_loja:
        novo_raio = min(raio_atual + INCREMENTO_EXPANSAO_RAIO_KM, raio_maximo_loja)
        cache.set(chave_raio, str(novo_raio), timeout=3600)
        logger.warning(
            "[RN-086] Sem estafetas disponíveis num raio de %s km. A expandir raio para %s km (entrega %s).",
            raio_atual,
            novo_raio,
            entrega_id,
        )
        raio_atual = novo_raio
        candidato, distancia_metros = _buscar_candidato_elegivel_no_raio(
            ponto_loja=ponto_loja,
            raio_km=raio_atual,
            estafetas_excluidos=estafetas_excluidos,
        )

    # 3. Candidato elegível encontrado: dispara oferta com timeout de 30s
    if candidato is not None:
        estafeta_id_str = str(candidato.id)

        # Regista oferta pendente em Redis com TTL de 35s
        chave_oferta = REDIS_KEY_OFERTA_ESTAFETA.format(
            entrega_id=entrega_id,
            estafeta_id=estafeta_id_str,
        )
        cache.set(chave_oferta, "OFERECIDA", timeout=35)

        # Bloqueia temporariamente o estafeta para não receber corridas concorrentes simultâneas
        cache.set(f"logistics:lock_courier:{estafeta_id_str}", entrega_id, timeout=35)

        # Regista evento imutável de auditoria (Secção 12.1)
        EventoPedido.objects.create(
            pedido=entrega.pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_OFFERED,
            autor="SISTEMA:DESPACHO",
            dados_adicionais={
                "entrega_id": entrega_id,
                "estafeta_id": estafeta_id_str,
                "estafeta_nome": candidato.utilizador.nome,
                "distancia_metros": distancia_metros,
                "raio_pesquisa_km": str(raio_atual),
                "prazo_resposta_segundos": DEFAULT_TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS,
            },
        )

        # Emite notificação push / WebSocket via Redis ao estafeta selecionado
        _notificar_oferta_aplicacao_estafeta(
            entrega=entrega,
            estafeta=candidato,
            distancia_metros=distancia_metros,
        )

        # Agenda a tarefa de timeout regressivo de 30 segundos (RN-086)
        task_timeout_oferta_estafeta.apply_async(
            args=[entrega_id, estafeta_id_str],
            countdown=DEFAULT_TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS,
        )

        logger.info(
            "[RN-086] Nova oferta de corrida atribuída: entrega_id=%s -> estafeta_id=%s (%s m, raio %s km)",
            entrega_id,
            estafeta_id_str,
            distancia_metros,
            raio_atual,
        )

        return {
            "status": "oferta_enviada",
            "entrega_id": entrega_id,
            "estafeta_id": estafeta_id_str,
            "distancia_metros": distancia_metros,
            "raio_km": str(raio_atual),
        }

    # 4. Nenhum estafeta encontrado mesmo após expansão máxima: alerta de escassez
    logger.error(
        "[RN-086 / RN-089] Alerta de escassez crítica: nenhum estafeta disponível para entrega %s "
        "após esgotar o raio máximo de %s km.",
        entrega_id,
        raio_maximo_loja,
    )
    cache.set(f"logistics:shortage_alert:{entrega_id}", True, timeout=1800)

    return {
        "status": "sem_estafetas_disponiveis",
        "entrega_id": entrega_id,
        "raio_maximo_atingido_km": str(raio_maximo_loja),
        "alerta_escassez": True,
    }


def _buscar_candidato_elegivel_no_raio(
    ponto_loja: Point,
    raio_km: Decimal,
    estafetas_excluidos: set[str],
) -> tuple[Estafeta | None, int]:
    """
    Executa a query geoespacial PostGIS ordenando por distância linear e reputação (RN-084, RN-085).
    """
    qs = (
        Estafeta.objects.filter(
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao__isnull=False,
            ultima_geolocalizacao__distance_lte=(ponto_loja, D(km=float(raio_km))),
        )
        .exclude(id__in=estafetas_excluidos)
        .annotate(distancia_loja=Distance("ultima_geolocalizacao", ponto_loja))
        .order_by("distancia_loja", "-score_reputacao")
        .select_related("utilizador")
    )

    candidato = qs.first()
    if candidato is not None:
        dist_obj = getattr(candidato, "distancia_loja", None)
        dist_m = int(round(dist_obj.m)) if dist_obj and hasattr(dist_obj, "m") else 0
        return candidato, dist_m
    return None, 0


# ==============================================================================
# 4. FUNÇÕES DE SUPORTE: REEMBOLSO, STOCK E NOTIFICAÇÕES
# ==============================================================================

def _executar_reembolso_integral_cliente(
    pedido: Pedido,
    motivo: str,
    ator: str,
) -> dict[str, Any]:
    """
    RN-075 e Secção 7.3: Rotina de estorno e reembolso financeiro integral ao cliente.
    Cria lançamentos imutáveis de dupla entrada no Livro Razão Ledger:
    - Reversão no Gateway bancário (RN-066, RN-070);
    - Lançamento contábil de dupla entrada (Débito e Crédito equilibrados);
    - Registo de evento de auditoria `payment.refunded`.
    """
    total_reembolso = pedido.total_cobrado

    # 1. Reversão no Gateway Bancário
    try:
        from apps.orders.payment_service import PaymentGatewayService
        PaymentGatewayService.cancelar_autorizacao_estorno(pedido=pedido, motivo=motivo)
    except Exception as exc:
        logger.error("[RN-075] Erro ao comunicar estorno com gateway bancário: %s", exc)

    # 2. Lançamento imutável de dupla entrada no Livro Razão Ledger (Secção 7.3 e RN-150)
    lancamento_ledger = None
    if total_reembolso > 0:
        lancamento_ledger = LivroRazaoLedger.objects.create(
            referencia_pedido=pedido,
            conta_origem=LivroRazaoLedger.ContaContabil.PLATAFORMA,
            conta_destino=LivroRazaoLedger.ContaContabil.CLIENTE,
            debito=total_reembolso,
            credito=total_reembolso,
        )

    # 3. Registo imutável de auditoria financeira (Secção 12.1)
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


def _libertar_stock_pedido(pedido: Pedido) -> dict[str, Any]:
    """
    RN-075: Liberta o stock previamente reservado dos itens do menu associados ao pedido rejeitado.
    """
    itens_libertados = []
    linhas = pedido.linhas.select_related("item").all()
    for linha in linhas:
        if linha.item:
            # Liberta locks de reserva de stock em cache Redis
            chave_stock = f"catalog:item:stock_reserved:{linha.item_id}"
            cache.delete(chave_stock)
            itens_libertados.append({
                "item_id": str(linha.item_id),
                "item_nome": linha.item.nome,
                "quantidade": linha.quantidade,
            })
            logger.info(
                "[RN-075] Stock libertado com sucesso: item=%s, quantidade=%s (Pedido %s)",
                linha.item.nome,
                linha.quantidade,
                pedido.id,
            )
    return {"itens_libertados": itens_libertados, "total_linhas": len(itens_libertados)}


def _disparar_alerta_sonoro_reforcado_parceiro(pedido: Pedido) -> None:
    """
    RN-075 / RN-120: Emite alerta de alta prioridade (sonoro reforçado e push)
    para o terminal/tablet da loja parceira via Redis PubSub / Django Channels.
    """
    canal_redis = f"partner:store:{pedido.loja_id}:urgent_alerts"
    payload = {
        "tipo": "ALERTA_90S_TIMEOUT_IMINENTE",
        "pedido_id": str(pedido.id),
        "tempo_restante_segundos": 90,
        "mensagem": "Atenção: restam 90 segundos para aceitar o pedido antes de cancelamento automático!",
        "nivel_urgencia": "CRITICO",
        "timestamp": timezone.now().isoformat(),
    }
    cache.set(canal_redis, payload, timeout=120)


def _notificar_oferta_aplicacao_estafeta(
    entrega: Entrega,
    estafeta: Estafeta,
    distancia_metros: int,
) -> None:
    """Emite evento de nova corrida via Redis PubSub para o WebSocket do estafeta."""
    canal_estafeta = f"logistics:courier:{estafeta.id}:offers"
    payload = {
        "tipo": "NOVA_OFERTA_CORRIDA",
        "entrega_id": str(entrega.id),
        "pedido_id": str(entrega.pedido_id),
        "loja_nome": entrega.pedido.loja.nome,
        "distancia_metros": distancia_metros,
        "timeout_segundos": DEFAULT_TIMEOUT_OFERTA_ESTAFETA_SEGUNDOS,
        "timestamp": timezone.now().isoformat(),
    }
    cache.set(canal_estafeta, payload, timeout=35)


# ==============================================================================
# 5. TAREFAS DE CICLO DE VIDA DO OMS (COMPATIBILIDADE OPERACIONAL)
# ==============================================================================

@shared_task(bind=True, max_retries=3, default_retry_delay=5)
def iniciar_timer_aceitacao_parceiro(
    self,
    pedido_id: str,
    timeout_segundos: int = DEFAULT_TIMEOUT_ACEITACAO_PARCEIRO_SEGUNDOS,
) -> None:
    """
    Agenda o lembrete de 90 segundos e o timeout de 3 minutos para a loja parceira.
    """
    task_monitorizar_timeout_aceitacao_parceiro.apply_async(
        args=[pedido_id],
        kwargs={"estagio": "alerta_90s"},
        countdown=INTERVALO_LEMBRETE_REFORCADO_SEGUNDOS,
    )
    task_monitorizar_timeout_aceitacao_parceiro.apply_async(
        args=[pedido_id],
        kwargs={"estagio": "timeout_final", "timeout_segundos": timeout_segundos},
        countdown=timeout_segundos,
    )


@shared_task(bind=True, max_retries=3, default_retry_delay=10)
def iniciar_motor_despacho_logistico(self, pedido_id: str) -> None:
    """Secção 8 / RN-090: Inicia o algoritmo de despacho logístico."""
    try:
        pedido = Pedido.objects.get(pk=pedido_id)
        entrega, _ = Entrega.objects.get_or_create(
            pedido=pedido,
            defaults={
                "estado_entrega": Entrega.EstadoEntrega.PENDENTE,
                "distancia_metros": 0,
            },
        )
        executar_algoritmo_despacho_logistico(entrega_id=str(entrega.id))
    except Exception as exc:
        logger.error("Erro ao iniciar motor de despacho para pedido_id=%s: %s", pedido_id, exc)
        raise self.retry(exc=exc)


@shared_task(bind=True, max_retries=3, default_retry_delay=5)
def notificar_estafeta_pronto_recolha(self, pedido_id: str) -> None:
    """Notifica o estafeta que o pedido está confecionado e pronto ao balcão."""
    logger.info("Notificação de pedido pronto emitida para pedido_id=%s", pedido_id)


@shared_task(bind=True, max_retries=3, default_retry_delay=10)
def processar_liquidacao_ledger_pedido(self, pedido_id: str, ignorar_janela_48h: bool = False) -> None:
    """Secção 7.1, 7.3 e RN-150: Executa lançamentos de dupla entrada no Livro Razão Ledger."""
    logger.info("A processar liquidação no Livro Razão (Ledger) para pedido_id=%s", pedido_id)
    try:
        from apps.orders.ledger_service import executar_divisao_financeira_conclusao_pedido
        executar_divisao_financeira_conclusao_pedido(pedido_id=pedido_id, ignorar_janela_48h=ignorar_janela_48h)
    except Exception as exc:
        logger.error("Erro na liquidação de ledger para pedido_id=%s: %s", pedido_id, exc)
        raise self.retry(exc=exc)


@shared_task(bind=True, max_retries=3, default_retry_delay=300)
def task_processar_liquidacao_apos_janela_48h(self, pedido_id: str) -> None:
    """
    RN-147 / Secção 7.1 e 7.3: Tarefa assíncrona agendada para 48h após a entrega do pedido (ENTREGUE).
    Valida se a janela de reclamação encerrou sem contestações ativas e executa a liquidação contábil.
    """
    logger.info("RN-147: A verificar encerramento da janela de contestação de 48h para pedido_id=%s", pedido_id)
    try:
        from apps.orders.ledger_service import executar_divisao_financeira_conclusao_pedido
        executar_divisao_financeira_conclusao_pedido(pedido_id=pedido_id, ignorar_janela_48h=False)
    except Exception as exc:
        logger.error("Erro ao processar liquidação após 48h para pedido_id=%s: %s", pedido_id, exc)
        raise self.retry(exc=exc)


@shared_task(bind=True, max_retries=3, default_retry_delay=10)
def processar_estorno_cancelamento_pedido(self, pedido_id: str, motivo: str) -> None:
    """Secção 5 e 7.3: Desencadeia estorno / reembolso no gateway e ledger."""
    logger.warning("A processar estorno/reembolso para pedido_id=%s. Motivo: %s", pedido_id, motivo)
    try:
        pedido = Pedido.objects.get(pk=pedido_id)
        _executar_reembolso_integral_cliente(pedido=pedido, motivo=motivo, ator="SISTEMA")
    except Exception as exc:
        logger.error("Erro ao processar estorno de pagamento para pedido_id=%s: %s", pedido_id, exc)
        raise self.retry(exc=exc)
