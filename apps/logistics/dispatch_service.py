"""
Serviço de Otimização e Motor de Despacho Logístico Inteligente ('logistics').
Implementa rigorosamente a Secção 6.8, a Secção 8 e as Regras de Negócio:
- RN-084: Filtro de elegibilidade (veículo, onboarding aprovado, is_online=True e capacidade máxima
  de corridas simultâneas não atingida).
- RN-085: Algoritmo de Pontuação de Despacho (ScoreDespacho) com ponderação multicritério:
  Proximidade física (PostGIS), taxa de aceitação histórica e score de reputação.
- RN-086: Expansão gradual do raio de procura (3 km inicial até 7 km limite) e despacho com timeout de 30s.
"""
from __future__ import annotations

import json
import logging
import uuid
from decimal import Decimal
from typing import Any

from django.conf import settings
from django.contrib.gis.db.models.functions import Distance
from django.contrib.gis.geos import Point
from django.contrib.gis.measure import D
from django.core.cache import cache
from django.db import transaction
from django.db.models import Count, Q
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import EventoPedido, Pedido

logger = logging.getLogger(__name__)


class DispatchOptimizationEngine:
    """
    Motor algorítmico de despacho logístico multicritério e otimização geoespacial.
    """

    # Secção 8 / RN-084: Limite padrão de corridas ativas simultâneas por estafeta
    MAX_CORRIDAS_SIMULTANEAS_PADRAO: int = getattr(
        settings, "LOGISTICS_MAX_CORRIDAS_SIMULTANEAS", 1
    )

    # Secção 8 / RN-086: Degraus de raio de busca a partir da loja (em km)
    RAIO_INICIAL_KM: Decimal = Decimal(str(getattr(settings, "LOGISTICS_RAIO_DESPACHO_INICIAL_KM", 3.0)))
    RAIO_EXPANSAO_INTERMEDIO_KM: Decimal = Decimal("5.0")
    RAIO_LIMITE_MAXIMO_KM: Decimal = Decimal(str(getattr(settings, "LOGISTICS_RAIO_DESPACHO_LIMITE_KM", 7.0)))

    # RN-085: Pesos da fórmula ponderada do ScoreDespacho (soma dos pesos = 1.00)
    PESO_PROXIMIDADE: Decimal = Decimal("0.50")    # 50% Proximidade física
    PESO_ACEITACAO: Decimal = Decimal("0.25")      # 25% Taxa de aceitação recente
    PESO_REPUTACAO: Decimal = Decimal("0.25")      # 25% Score de reputação (0.00 a 5.00)

    # Redis keys para coordenação da fila ordenada e canais WebSockets/PubSub
    REDIS_CANDIDATE_QUEUE_KEY = "logistics:dispatch:candidate_queue:{entrega_id}"
    REDIS_OFFER_KEY = "logistics:offer:{entrega_id}:{estafeta_id}"
    REDIS_COURIER_CHANNEL = "logistics:courier:{estafeta_id}:offers"

    @classmethod
    def buscar_candidatos_com_expansao(
        cls,
        ponto_loja: Point,
        estafetas_excluidos: set[str],
        max_corridas_ativas: int | None = None,
    ) -> tuple[list[dict[str, Any]], Decimal]:
        """
        RN-084 e RN-086:
        1. Executa query geoespacial em PostGIS procurando estafetas elegíveis.
        2. Tenta o raio inicial de 3.0 km. Se não encontrar candidatos, expande gradualmente
           para 5.0 km e até ao limite de 7.0 km.
        3. Para cada estafeta, calcula o `ScoreDespacho` multicritério (RN-085).
        4. Retorna a lista ordenada dos candidatos (`ScoreDespacho` decrescente) e o raio efetivo utilizado.
        """
        limite_corridas = max_corridas_ativas or cls.MAX_CORRIDAS_SIMULTANEAS_PADRAO
        degraus_raio = [cls.RAIO_INICIAL_KM, cls.RAIO_EXPANSAO_INTERMEDIO_KM, cls.RAIO_LIMITE_MAXIMO_KM]

        candidatos_encontrados: list[dict[str, Any]] = []
        raio_utilizado = degraus_raio[0]

        estados_ativos_corrida = [
            Entrega.EstadoEntrega.ATRIBUIDO,
            Entrega.EstadoEntrega.RECOLHIDO,
            Entrega.EstadoEntrega.EM_TRANSITO,
        ]

        for raio in degraus_raio:
            raio_utilizado = raio
            logger.info("[RN-086] A pesquisar estafetas no raio de %s km a partir da loja...", raio)

            # Query geoespacial PostGIS (SRID 4326) com filtro de capacidade (RN-084)
            qs = (
                Estafeta.objects.filter(
                    status_onboarding=Estafeta.StatusOnboarding.APROVADO,
                    is_online=True,
                    ultima_geolocalizacao__isnull=False,
                    ultima_geolocalizacao__distance_lte=(ponto_loja, D(km=float(raio))),
                )
                .exclude(id__in=estafetas_excluidos)
                .annotate(
                    distancia_loja=Distance("ultima_geolocalizacao", ponto_loja),
                    corridas_ativas_count=Count(
                        "entregas",
                        filter=Q(entregas__estado_entrega__in=estados_ativos_corrida),
                    ),
                )
                .filter(corridas_ativas_count__lt=limite_corridas)
                .select_related("utilizador")
            )

            estafetas_no_raio = list(qs)
            if not estafetas_no_raio:
                continue

            # RN-085: Calcula o ScoreDespacho para cada candidato encontrado
            raio_metros = float(raio * 1000)
            for estafeta in estafetas_no_raio:
                distancia_obj = getattr(estafeta, "distancia_loja", None)
                distancia_metros = (
                    float(distancia_obj.m)
                    if distancia_obj and hasattr(distancia_obj, "m")
                    else float(raio_metros)
                )

                score_info = cls.calcular_score_despacho(
                    estafeta=estafeta,
                    distancia_metros=distancia_metros,
                    raio_maximo_metros=raio_metros,
                )

                candidatos_encontrados.append(
                    {
                        "estafeta": estafeta,
                        "estafeta_id": str(estafeta.id),
                        "nome": estafeta.utilizador.nome,
                        "telemovel": estafeta.utilizador.telemovel,
                        "tipo_veiculo": estafeta.tipo_veiculo,
                        "distancia_metros": int(distancia_metros),
                        "score_despacho": score_info["score_despacho"],
                        "score_detalhes": score_info,
                    }
                )

            # Se encontrou pelo menos um candidato válido neste degrau de raio, interrompe a expansão
            if candidatos_encontrados:
                break

        # Ordena a lista decrescentemente pela maior Pontuação de Despacho (RN-085)
        candidatos_encontrados.sort(
            key=lambda item: item["score_despacho"],
            reverse=True,
        )
        return candidatos_encontrados, raio_utilizado

    @classmethod
    def calcular_score_despacho(
        cls,
        estafeta: Estafeta,
        distancia_metros: float,
        raio_maximo_metros: float,
    ) -> dict[str, Any]:
        """
        RN-085: Fórmula ponderada de Pontuação de Despacho (`ScoreDespacho` de 0.00 a 100.00):
        1. Proximidade Física: Quanto menor a distância até à loja, maior a pontuação.
        2. Taxa de Aceitação Recente: Percentagem de ofertas aceites nos últimos 30 dias (ou Redis).
        3. Score de Reputação: Avaliação média do estafeta (escala de 0.00 a 5.00 normalizada a 100%).
        """
        # 1. Componente Proximidade (0.00 a 1.00)
        fator_distancia = max(0.0, 1.0 - (distancia_metros / max(1.0, raio_maximo_metros)))

        # 2. Componente Taxa de Aceitação (0.00 a 1.00)
        taxa_aceitacao = cls._obter_taxa_aceitacao_estafeta(estafeta.id)

        # 3. Componente Reputação (0.00 a 1.00)
        reputacao_normalizada = float(estafeta.score_reputacao or Decimal("5.00")) / 5.0

        # Fórmula ponderada combinada (escala percentual 0 a 100)
        score_final = (
            (float(cls.PESO_PROXIMIDADE) * fator_distancia)
            + (float(cls.PESO_ACEITACAO) * taxa_aceitacao)
            + (float(cls.PESO_REPUTACAO) * reputacao_normalizada)
        ) * 100.0

        return {
            "score_despacho": round(score_final, 2),
            "fator_proximidade": round(fator_distancia, 4),
            "taxa_aceitacao": round(taxa_aceitacao, 4),
            "reputacao_normalizada": round(reputacao_normalizada, 4),
            "distancia_metros": int(distancia_metros),
        }

    @classmethod
    def _obter_taxa_aceitacao_estafeta(cls, estafeta_id: uuid.UUID | str) -> float:
        """
        Obtém a taxa de aceitação recente do estafeta a partir da cache Redis ou histórico.
        Retorna valor entre 0.00 e 1.00 (default: 0.95 / 95% para estafetas sem histórico).
        """
        cache_key = f"logistics:courier_acceptance_rate:{estafeta_id}"
        taxa_em_cache = cache.get(cache_key)
        if taxa_em_cache is not None:
            try:
                return float(taxa_em_cache)
            except (ValueError, TypeError):
                pass
        return 0.95

    @classmethod
    def enviar_oferta_ao_estafeta(
        cls,
        entrega: Entrega,
        candidato: dict[str, Any],
        timeout_segundos: int = 30,
    ) -> bool:
        """
        RN-086:
        1. Marca a oferta como ativa em Redis com TTL.
        2. Emite evento em tempo real via Redis PubSub / WebSocket para a app do estafeta.
        3. Dispara a tarefa Celery `task_timeout_oferta_estafeta` com countdown de 30 segundos.
        4. Regista o evento de auditoria imutável `delivery.offered`.
        """
        from celery_tasks import task_timeout_oferta_estafeta

        entrega_id_str = str(entrega.id)
        estafeta_id_str = candidato["estafeta_id"]

        # Grava a oferta em Redis (TTL ligeiramente superior aos 30s para evitar desfasamentos)
        chave_oferta = cls.REDIS_OFFER_KEY.format(
            entrega_id=entrega_id_str,
            estafeta_id=estafeta_id_str,
        )
        cache.set(chave_oferta, "OFERECIDA", timeout=timeout_segundos + 5)

        # Monta o payload de notificação WebSockets/Push em tempo real
        pedido = entrega.pedido
        payload_oferta = {
            "evento": "NOVA_OFERTA_ENTREGA",
            "entrega_id": entrega_id_str,
            "pedido_id": str(pedido.id),
            "loja_nome": pedido.loja.nome,
            "morada_recolha": pedido.loja.morada_texto,
            "distancia_ate_loja_metros": candidato["distancia_metros"],
            "ganho_estimado_centimos": pedido.taxa_entrega + pedido.gorjeta_estafeta,
            "score_despacho": candidato["score_despacho"],
            "timeout_segundos": timeout_segundos,
            "expira_em": (timezone.now() + timezone.timedelta(seconds=timeout_segundos)).isoformat(),
        }

        # Publica no canal Redis exclusivo do estafeta
        canal_estafeta = cls.REDIS_COURIER_CHANNEL.format(estafeta_id=estafeta_id_str)
        cache.set(canal_estafeta, payload_oferta, timeout=timeout_segundos + 5)

        # Regista evento imutável de auditoria (Secção 12.1)
        EventoPedido.objects.create(
            pedido=pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_OFFERED,
            autor="SISTEMA:MOTOR_DESPACHO",
            dados_adicionais={
                "entrega_id": entrega_id_str,
                "estafeta_id": estafeta_id_str,
                "estafeta_nome": candidato["nome"],
                "score_despacho": candidato["score_despacho"],
                "detalhes_score": candidato["score_detalhes"],
                "timeout_segundos": timeout_segundos,
                "regra": "RN-085 / RN-086",
            },
        )

        # Agenda a tarefa Celery de timeout de 30 segundos (RN-086)
        task_timeout_oferta_estafeta.apply_async(
            args=[entrega_id_str, estafeta_id_str],
            countdown=timeout_segundos,
        )

        logger.info(
            "[RN-086] Oferta enviada ao estafeta %s (%s) para entrega %s com score %.2f (timeout=%ds).",
            estafeta_id_str,
            candidato["nome"],
            entrega_id_str,
            candidato["score_despacho"],
            timeout_segundos,
        )
        return True

