"""
Tarefas Celery da aplicação 'logistics' (Despacho Logístico, Rastreio e Gestão de Estafetas).
Implementa o algoritmo de otimização de despacho multicritério conforme RN-084, RN-085, RN-086 e Secção 6.8.
"""
from __future__ import annotations

import logging
import uuid
from decimal import Decimal
from typing import Any

from asgiref.sync import async_to_sync
from celery import shared_task
from django.conf import settings
from django.contrib.gis.db.models.functions import Distance
from django.contrib.gis.geos import Point
from django.contrib.gis.measure import D
from django.core.cache import cache
from django.db import transaction
from django.db.models import Count, Q
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

try:
    from channels.layers import get_channel_layer
except ImportError:
    get_channel_layer = lambda: None

from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import EventoPedido, Pedido
from celery_tasks import (
    REDIS_KEY_EXCLUIDOS_CORRIDA,
    task_timeout_oferta_estafeta,
)

logger = logging.getLogger(__name__)

# Matriz de expansão de raio canónica (Secção 8, RN-086): 3 km -> 5 km -> 7 km (em metros)
RAIOS_BUSCA_EXPANSAO_METROS: list[int] = [3000, 5000, 7000]

# Velocidades médias estimadas por tipo de veículo para cálculo de ETA (em m/s)
VELOCIDADES_VEICULO_MS: dict[str, float] = {
    Estafeta.TipoVeiculo.MOTA: 9.72,       # ~35 km/h
    Estafeta.TipoVeiculo.CARRO: 8.33,      # ~30 km/h
    Estafeta.TipoVeiculo.BICICLETA: 4.17,  # ~15 km/h
}


def _obter_taxa_aceitacao_recente(estafeta_id: uuid.UUID | str) -> float:
    """
    RN-085: Obtém a taxa de aceitação recente do estafeta a partir da cache Redis ou histórico.
    Retorna um float entre 0.00 e 1.00 (default: 0.95 / 95% para estafetas sem histórico).
    """
    cache_key = f"logistics:courier_acceptance_rate:{estafeta_id}"
    taxa = cache.get(cache_key)
    if taxa is not None:
        try:
            return max(0.0, min(1.0, float(taxa)))
        except (ValueError, TypeError):
            pass
    return 0.95


def _pedido_contem_artigos_restritos(pedido: Pedido) -> bool:
    """
    RN-044 / RN-084: Verifica se o pedido contém bebidas alcoólicas ou artigos restritos
    que exigem verificação de maioridade legal (>= 18 anos) para o estafeta e cliente.
    """
    palavras_restritas = {
        "alcool", "álcool", "cerveja", "vinho", "licor", "whisky", "whiskey",
        "vodka", "gin", "rum", "tequila", "espumante", "champagne", "sidra",
        "aguardente", "cocktail", "alcoólica", "alcoolica",
    }
    for linha in pedido.linhas.select_related("item", "item__categoria").all():
        item = linha.item
        nome = (item.nome or "").lower()
        desc = (item.descricao or "").lower()
        cat = (item.categoria.nome if item.categoria else "").lower()
        if any(termo in nome or termo in desc or termo in cat for termo in palavras_restritas):
            return True
    return False


@shared_task(
    name="apps.logistics.tasks.executar_algoritmo_despacho_logistico",
    bind=True,
    max_retries=3,
    default_retry_delay=5,
    autoretry_for=(Exception,),
    dont_autoretry_for=(Pedido.DoesNotExist, Entrega.DoesNotExist),
)
def executar_algoritmo_despacho_logistico(
    self,
    pedido_id: str,
    tentativa_raio_index: int = 0,
) -> dict[str, Any]:
    """
    RN-084, RN-085, RN-086 e Secção 6.8:
    Algoritmo core de despacho logístico da plataforma com otimização multicritério e PostGIS.

    Passos Lógicos:
    1. Recupera o Pedido e extrai as coordenadas PostGIS de recolha (Loja) e entrega (Morada Cliente).
    2. Define a matriz de expansão de raio [3000, 5000, 7000] metros (Secção 8, RN-086).
       Se ultrapassar o teto máximo de 7000m, regista alerta crítico de escassez em Redis.
    3. Executa a query espacial na tabela Estafeta via Django GIS ORM:
       - Online (is_online=True - RN-083);
       - No raio atual da loja (ultima_geolocalizacao__distance_lte);
       - Capacidade de corridas simultâneas não excedida (RN-084);
       - Conformidade legal (maioridade >= 18 anos se o pedido contiver álcool - RN-044, RN-084);
       - Exclusão de estafetas que já rejeitaram ou expiraram nesta corrida (REDIS_KEY_EXCLUIDOS_CORRIDA).
    4. Calcula o ScoreDespacho multicritério (RN-085) com a fórmula matemática exata:
       Score = ( (1 / distancia_metros) * 0.5 ) + ( estafeta.score_reputacao * 0.3 ) + ( estafeta.taxa_aceitacao_recente * 0.2 )
       Estima a ETA para a recolha com base no tipo de veículo.
    5. Atribuição e Notificação:
       - Ordena os candidatos de forma decrescente pelo Score.
       - Seleciona o 1.º classificado e atualiza metadados na Entrega.
       - Dispara notificação WebSocket via Django Channels (f"courier_{estafeta_id}").
       - Agenda o timeout de 30 segundos (task_timeout_oferta_estafeta) conforme RN-086.
       - Se nenhum estafeta for encontrado no raio atual, auto-reagenda com tentativa_raio_index + 1.
    """
    logger.info(
        "[DESPACHO] Início do algoritmo: pedido_id=%s, tentativa_raio_index=%d",
        pedido_id,
        tentativa_raio_index,
    )

    with transaction.atomic():
        # 1. Recupera o Pedido e as coordenadas de recolha e entrega (suporta pedido_id ou entrega_id)
        try:
            pedido = (
                Pedido.objects.select_for_update()
                .select_related("loja", "cliente")
                .prefetch_related("linhas__item__categoria")
                .get(pk=pedido_id)
            )
        except Pedido.DoesNotExist:
            try:
                entrega_ref = Entrega.objects.select_related("pedido").get(pk=pedido_id)
                pedido = (
                    Pedido.objects.select_for_update()
                    .select_related("loja", "cliente")
                    .prefetch_related("linhas__item__categoria")
                    .get(pk=entrega_ref.pedido_id)
                )
            except Entrega.DoesNotExist:
                logger.error("[DESPACHO] Pedido ou Entrega %s não encontrado.", pedido_id)
                return {"status": "pedido_nao_encontrado", "pedido_id": pedido_id}

        ponto_loja: Point | None = pedido.loja.geolocalizacao
        if not ponto_loja:
            logger.error("[DESPACHO] Loja %s não possui coordenadas geográficas PostGIS.", pedido.loja_id)
            return {"status": "loja_sem_coordenadas", "loja_id": str(pedido.loja_id)}

        morada_cliente = pedido.cliente.moradas.order_by("-id").first()
        ponto_entrega: Point | None = morada_cliente.geolocalizacao if morada_cliente else None

        # Garante a existência da entidade Entrega associada ao pedido
        entrega, _ = Entrega.objects.get_or_create(
            pedido=pedido,
            defaults={
                "estado_entrega": Entrega.EstadoEntrega.PENDENTE,
                "estado_logistico": Entrega.EstadoEntrega.PENDENTE,
                "distancia_metros": 0,
            },
        )

        if entrega.estado_entrega != Entrega.EstadoEntrega.PENDENTE:
            logger.info(
                "[DESPACHO] Entrega %s já não se encontra PENDENTE (%s).",
                entrega.id,
                entrega.estado_entrega,
            )
            return {"status": "entrega_ja_atribuida", "entrega_id": str(entrega.id)}

        entrega_id_str = str(entrega.id)

        # 2. Matriz de expansão de raio (Secção 8, RN-086)
        raios_busca = RAIOS_BUSCA_EXPANSAO_METROS
        if tentativa_raio_index >= len(raios_busca):
            # Teto de 7 km ultrapassado sem estafetas disponíveis
            logger.warning(
                "[DESPACHO] Teto de expansão de %d m atingido sem candidatos para pedido %s.",
                raios_busca[-1],
                pedido_id,
            )
            cache.set(f"logistics:shortage_alert:{pedido_id}", True, timeout=1800)
            cache.set(f"logistics:critical_shortage:{entrega_id_str}", True, timeout=1800)

            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.DELIVERY_FAILED,
                autor="SISTEMA:DESPACHO",
                dados_adicionais={
                    "evento": "escassez_estafetas_limite_alcancado",
                    "entrega_id": entrega_id_str,
                    "raio_limite_metros": raios_busca[-1],
                    "raios_tentados": raios_busca,
                    "regra": "RN-086",
                },
            )
            return {
                "status": "escassez_critica_sem_estafetas",
                "pedido_id": str(pedido.id),
                "entrega_id": entrega_id_str,
                "raio_limite_metros": raios_busca[-1],
            }

        raio_atual = raios_busca[tentativa_raio_index]
        logger.info(
            "[DESPACHO] A pesquisar estafetas no raio de %d m (tentativa %d/%d)...",
            raio_atual,
            tentativa_raio_index + 1,
            len(raios_busca),
        )

        # 3. Query espacial PostGIS na tabela Estafeta
        chave_excluidos = REDIS_KEY_EXCLUIDOS_CORRIDA.format(entrega_id=entrega_id_str)
        estafetas_excluidos: set[str] = set(cache.get(chave_excluidos) or [])

        estados_ativos_corrida = [
            Entrega.EstadoEntrega.ATRIBUIDO,
            Entrega.EstadoEntrega.RECOLHIDO,
            Entrega.EstadoEntrega.EM_TRANSITO,
        ]

        qs_candidatos = (
            Estafeta.objects.filter(
                status_onboarding=Estafeta.StatusOnboarding.APROVADO,
                is_online=True,
                ultima_geolocalizacao__isnull=False,
                ultima_geolocalizacao__distance_lte=(ponto_loja, D(m=raio_atual)),
            )
            .exclude(id__in=estafetas_excluidos)
            .annotate(
                distancia_calculada=Distance("ultima_geolocalizacao", ponto_loja),
                corridas_ativas=Count(
                    "entregas",
                    filter=Q(entregas__estado_entrega__in=estados_ativos_corrida),
                ),
            )
            .filter(corridas_ativas__lt=1)  # RN-084: Sem exceder capacidade simultânea
            .select_related("utilizador")
        )

        # RN-044 / RN-084: Conformidade com restrição de idade para bebidas alcoólicas
        pedido_tem_alcool = _pedido_contem_artigos_restritos(pedido)
        candidatos_elegiveis: list[dict[str, Any]] = []

        hoje = timezone.now().date()
        for estafeta in qs_candidatos:
            if pedido_tem_alcool:
                data_nascimento = getattr(estafeta.utilizador, "data_nascimento", None)
                if data_nascimento:
                    idade = hoje.year - data_nascimento.year - (
                        (hoje.month, hoje.day) < (data_nascimento.month, data_nascimento.day)
                    )
                    if idade < 18:
                        continue  # Inelegível para entregas de bebidas alcoólicas (RN-044)

            # 4. Cálculo do ScoreDespacho multicritério (RN-085)
            dist_obj = getattr(estafeta, "distancia_calculada", None)
            if dist_obj is not None and hasattr(dist_obj, "m"):
                distancia_metros = float(dist_obj.m)
            else:
                distancia_metros = float(raio_atual)

            # Guarda para evitar divisão por zero
            distancia_metros_segura = max(distancia_metros, 1.0)

            # Estimativa de ETA em minutos com base no tipo de veículo
            velocidade_ms = VELOCIDADES_VEICULO_MS.get(estafeta.tipo_veiculo, 8.33)
            eta_segundos = distancia_metros / velocidade_ms
            eta_minutos = max(1, round(eta_segundos / 60))

            # Taxa de aceitação recente e score de reputação
            taxa_aceitacao = _obter_taxa_aceitacao_recente(estafeta.id)
            score_reputacao = float(estafeta.score_reputacao or Decimal("5.00"))

            # Fórmula matemática exata da RN-085:
            # Score = ( (1 / distancia_metros) * 0.5 ) + ( estafeta.score_reputacao * 0.3 ) + ( estafeta.taxa_aceitacao_recente * 0.2 )
            score_final = (
                ((1.0 / distancia_metros_segura) * 0.5)
                + (score_reputacao * 0.3)
                + (taxa_aceitacao * 0.2)
            )

            candidatos_elegiveis.append({
                "estafeta": estafeta,
                "estafeta_id": str(estafeta.id),
                "nome": estafeta.utilizador.nome,
                "telemovel": estafeta.utilizador.telemovel,
                "tipo_veiculo": estafeta.tipo_veiculo,
                "distancia_metros": int(distancia_metros),
                "eta_minutos": eta_minutos,
                "score_reputacao": score_reputacao,
                "taxa_aceitacao": taxa_aceitacao,
                "score_despacho": score_final,
            })

        # Se não houver candidatos no raio atual, auto-reagenda com o próximo raio (RN-086)
        if not candidatos_elegiveis:
            proximo_index = tentativa_raio_index + 1
            if proximo_index < len(raios_busca):
                logger.info(
                    "[DESPACHO] Sem candidatos no raio de %d m. A agendar expansão para %d m...",
                    raio_atual,
                    raios_busca[proximo_index],
                )
                executar_algoritmo_despacho_logistico.apply_async(
                    args=[str(pedido.id), proximo_index],
                    countdown=2,
                )
                return {
                    "status": "expansao_raio_agendada",
                    "pedido_id": str(pedido.id),
                    "raio_atual_m": raio_atual,
                    "proximo_raio_index": proximo_index,
                    "proximo_raio_m": raios_busca[proximo_index],
                }
            else:
                # Teto limite atingido
                logger.warning("[DESPACHO] Teto de %d m esgotado sem estafetas.", raios_busca[-1])
                cache.set(f"logistics:shortage_alert:{pedido_id}", True, timeout=1800)
                cache.set(f"logistics:critical_shortage:{entrega_id_str}", True, timeout=1800)
                return {
                    "status": "escassez_critica_sem_estafetas",
                    "pedido_id": str(pedido.id),
                    "raio_limite_metros": raios_busca[-1],
                }

        # 5. Atribuição e Notificação: Ordena candidatos por Score decrescente
        candidatos_elegiveis.sort(key=lambda c: c["score_despacho"], reverse=True)
        vencedor = candidatos_elegiveis[0]
        suplentes = candidatos_elegiveis[1:]

        # Armazena fila de suplentes em Redis para consumo instantâneo se o 1.º recusar/expirar
        chave_fila_suplentes = f"logistics:dispatch:candidate_queue:{entrega_id_str}"
        cache.set(chave_fila_suplentes, [c["estafeta_id"] for c in suplentes], timeout=600)

        # Regista oferta ativa em Redis com TTL de 35s
        chave_oferta = f"logistics:offer:{entrega_id_str}:{vencedor['estafeta_id']}"
        cache.set(chave_oferta, "OFERECIDA", timeout=35)

        # Atualiza metadados da Entrega
        entrega.distancia_metros = vencedor["distancia_metros"]
        entrega.eta_estimada = timezone.now() + timezone.timedelta(minutes=vencedor["eta_minutos"])
        entrega.save(update_fields=["distancia_metros", "eta_estimada"])

        # Registo de auditoria imutável (Secção 12.1)
        EventoPedido.objects.create(
            pedido=pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_OFFERED,
            autor="SISTEMA:DESPACHO",
            dados_adicionais={
                "entrega_id": entrega_id_str,
                "estafeta_id": vencedor["estafeta_id"],
                "estafeta_nome": vencedor["nome"],
                "distancia_metros": vencedor["distancia_metros"],
                "eta_minutos": vencedor["eta_minutos"],
                "score_despacho": vencedor["score_despacho"],
                "raio_busca_metros": raio_atual,
                "tentativa_raio_index": tentativa_raio_index,
                "total_candidatos_no_raio": len(candidatos_elegiveis),
                "suplentes_em_fila": len(suplentes),
                "timeout_segundos": 30,
                "contem_alcool": pedido_tem_alcool,
                "regra": "RN-084 / RN-085 / RN-086",
            },
        )

        # Monta payload e envia notificação WebSocket via Django Channels
        ganho_total = pedido.taxa_entrega + pedido.gorjeta_estafeta
        payload_notificacao = {
            "evento": "NOVA_OFERTA_ENTREGA",
            "pedido_id": str(pedido.id),
            "entrega_id": entrega_id_str,
            "loja_nome": pedido.loja.nome,
            "morada_recolha": pedido.loja.morada_texto,
            "morada_entrega": morada_cliente.texto_endereco if morada_cliente else "",
            "distancia_metros": vencedor["distancia_metros"],
            "eta_minutos": vencedor["eta_minutos"],
            "ganho_estimado_centimos": ganho_total,
            "contem_alcool": pedido_tem_alcool,
            "score_despacho": round(vencedor["score_despacho"], 4),
            "timeout_segundos": 30,
            "expira_em": (timezone.now() + timezone.timedelta(seconds=30)).isoformat(),
        }

        channel_layer = get_channel_layer()
        if channel_layer:
            try:
                canal_estafeta = f"courier_{vencedor['estafeta_id']}"
                async_to_sync(channel_layer.group_send)(
                    canal_estafeta,
                    {
                        "type": "nova_oferta_entrega",
                        "payload": payload_notificacao,
                    },
                )
            except Exception as e:
                logger.warning("[DESPACHO] Falha ao enviar evento via Channel Layer: %s", e)

        # Também disponibiliza no canal Redis direto para contingência
        canal_redis = f"logistics:courier:{vencedor['estafeta_id']}:offers"
        cache.set(canal_redis, payload_notificacao, timeout=35)

        # Agenda a tarefa de timeout estrito de 30 segundos (RN-086)
        task_timeout_oferta_estafeta.apply_async(
            args=[entrega_id_str, vencedor["estafeta_id"]],
            countdown=30,
        )

        logger.info(
            "[DESPACHO] Oferta enviada com sucesso ao estafeta %s (%s) para pedido %s "
            "(Score: %.4f | Distância: %d m | Raio: %d m). Suplentes na fila: %d",
            vencedor["estafeta_id"],
            vencedor["nome"],
            pedido_id,
            vencedor["score_despacho"],
            vencedor["distancia_metros"],
            raio_atual,
            len(suplentes),
        )

        return {
            "status": "oferta_enviada",
            "pedido_id": str(pedido.id),
            "entrega_id": entrega_id_str,
            "estafeta_ofertado": {
                "id": vencedor["estafeta_id"],
                "nome": vencedor["nome"],
                "distancia_metros": vencedor["distancia_metros"],
                "eta_minutos": vencedor["eta_minutos"],
                "score_despacho": round(vencedor["score_despacho"], 4),
            },
            "raio_utilizado_metros": raio_atual,
            "tentativa_raio_index": tentativa_raio_index,
            "total_candidatos": len(candidatos_elegiveis),
            "suplentes_em_fila": len(suplentes),
        }


@shared_task(name="apps.logistics.tasks.executar_despacho_logistico")
def executar_despacho_logistico(pedido_id: str) -> dict[str, Any]:
    """
    Wrapper de retrocompatibilidade para o motor de despacho principal.
    Invoca `executar_algoritmo_despacho_logistico` no raio inicial (índice 0 = 3000m).
    """
    return executar_algoritmo_despacho_logistico(pedido_id=pedido_id, tentativa_raio_index=0)


@shared_task(name="apps.logistics.tasks.avancar_proximo_estafeta_fila")
def avancar_proximo_estafeta_fila(entrega_id: str) -> dict[str, Any]:
    """
    RN-086: Chamada imediatamente quando um estafeta rejeita a corrida antes dos 30s
    ou quando a oferta expira, retirando o próximo estafeta da fila pré-ordenada no Redis.
    Se a fila de suplentes estiver vazia, reexecuta o algoritmo de despacho com expansão de raio.
    """
    logger.info("[DESPACHO] A avançar para o próximo estafeta na fila para entrega_id=%s", entrega_id)

    try:
        entrega = Entrega.objects.select_related("pedido", "pedido__loja").get(pk=entrega_id)
    except Entrega.DoesNotExist:
        return {"status": "entrega_nao_encontrada"}

    if entrega.estado_entrega != Entrega.EstadoEntrega.PENDENTE:
        return {"status": "entrega_ja_atribuida"}

    chave_fila = f"logistics:dispatch:candidate_queue:{entrega_id}"
    fila_suplentes: list[str] = cache.get(chave_fila) or []

    while fila_suplentes:
        proximo_id = fila_suplentes.pop(0)
        cache.set(chave_fila, fila_suplentes, timeout=600)

        # Verifica se o candidato suplente ainda está online e aprovado
        estafeta = Estafeta.objects.filter(
            id=proximo_id,
            is_online=True,
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
        ).select_related("utilizador").first()

        if estafeta is None:
            continue

        ponto_loja = entrega.pedido.loja.geolocalizacao
        distancia_metros = 0.0
        if estafeta.ultima_geolocalizacao and ponto_loja:
            distancia_m = estafeta.ultima_geolocalizacao.distance(ponto_loja) * 111319.49
            distancia_metros = float(distancia_m)

        distancia_metros_segura = max(distancia_metros, 1.0)
        velocidade_ms = VELOCIDADES_VEICULO_MS.get(estafeta.tipo_veiculo, 8.33)
        eta_minutos = max(1, round((distancia_metros / velocidade_ms) / 60))

        score_reputacao = float(estafeta.score_reputacao or Decimal("5.00"))
        taxa_aceitacao = _obter_taxa_aceitacao_recente(estafeta.id)

        score_final = (
            ((1.0 / distancia_metros_segura) * 0.5)
            + (score_reputacao * 0.3)
            + (taxa_aceitacao * 0.2)
        )

        # Regista oferta ativa em Redis
        chave_oferta = f"logistics:offer:{entrega_id}:{estafeta.id}"
        cache.set(chave_oferta, "OFERECIDA", timeout=35)

        # Regista evento imutável
        EventoPedido.objects.create(
            pedido=entrega.pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_OFFERED,
            autor="SISTEMA:DESPACHO",
            dados_adicionais={
                "entrega_id": entrega_id,
                "estafeta_id": str(estafeta.id),
                "estafeta_nome": estafeta.utilizador.nome,
                "distancia_metros": int(distancia_metros),
                "eta_minutos": eta_minutos,
                "score_despacho": score_final,
                "origem": "fila_suplentes_redis",
                "timeout_segundos": 30,
            },
        )

        # Notificação WebSocket via Channels
        payload_notificacao = {
            "evento": "NOVA_OFERTA_ENTREGA",
            "pedido_id": str(entrega.pedido_id),
            "entrega_id": entrega_id,
            "loja_nome": entrega.pedido.loja.nome,
            "morada_recolha": entrega.pedido.loja.morada_texto,
            "distancia_metros": int(distancia_metros),
            "eta_minutos": eta_minutos,
            "ganho_estimado_centimos": entrega.pedido.taxa_entrega + entrega.pedido.gorjeta_estafeta,
            "score_despacho": round(score_final, 4),
            "timeout_segundos": 30,
            "expira_em": (timezone.now() + timezone.timedelta(seconds=30)).isoformat(),
        }

        channel_layer = get_channel_layer()
        if channel_layer:
            try:
                async_to_sync(channel_layer.group_send)(
                    f"courier_{estafeta.id}",
                    {"type": "nova_oferta_entrega", "payload": payload_notificacao},
                )
            except Exception as e:
                logger.warning("[DESPACHO] Falha ao enviar via channel_layer: %s", e)

        # Agenda timeout de 30s
        task_timeout_oferta_estafeta.apply_async(
            args=[entrega_id, str(estafeta.id)],
            countdown=30,
        )

        return {
            "status": "oferta_enviada_suplente",
            "entrega_id": entrega_id,
            "estafeta_id": str(estafeta.id),
            "score_despacho": round(score_final, 4),
        }

    # Se a fila esgotou, reinicia a busca com o algoritmo global
    return executar_algoritmo_despacho_logistico(pedido_id=str(entrega.pedido_id), tentativa_raio_index=0)
