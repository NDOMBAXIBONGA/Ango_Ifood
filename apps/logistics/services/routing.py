"""
Serviço de Roteamento Geoespacial e Cálculo de Frete da Plataforma Delivery Pro.
Utiliza motor OSRM (Open Source Routing Machine) Self-Hosted com dados do OpenStreetMap de Angola.
Inclui fallback matemático por Haversine com fator de correção urbana em caso de indisponibilidade do motor.
"""
from __future__ import annotations

import logging
import math
import os
from typing import Any, Dict, List, Tuple

import requests

logger = logging.getLogger(__name__)

# URL base do motor OSRM (definido via Docker ou variável de ambiente)
OSRM_BASE_URL = os.getenv("OSRM_BASE_URL", "http://osrm:5000").rstrip("/")
OSRM_TIMEOUT_SECONDS = float(os.getenv("OSRM_TIMEOUT_SECONDS", "3.0"))

# Parâmetros de precificação de entrega para Angola (AOA - Kwanzas)
TAXA_BASE_AOA = float(os.getenv("TAXA_BASE_ENTREGA_AOA", "500.0"))
VALOR_KM_AOA = float(os.getenv("VALOR_POR_KM_AOA", "150.0"))
FATOR_CORRECAO_URBANA = float(os.getenv("FATOR_CORRECAO_URBANA", "1.3"))
VELOCIDADE_MEDIA_URBANA_KMH = float(os.getenv("VELOCIDADE_MEDIA_URBANA_KMH", "25.0"))


def calcular_distancia_haversine(
    lat1: float, lon1: float, lat2: float, lon2: float
) -> float:
    """
    Calcula a distância em linha reta entre dois pontos geográficos em quilómetros
    utilizando a fórmula de Haversine sobre a esfera terrestre (Raio médio = 6371 km).
    """
    raio_terra_km = 6371.0

    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)

    a = (
        math.sin(delta_phi / 2.0) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0) ** 2
    )
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))

    return raio_terra_km * c


def calcular_preco_frete(distancia_km: float) -> int:
    """
    Calcula a taxa de entrega em Kwanzas (AOA) com base na distância percorrida:
      Preço = Taxa Base (500 AOA) + (Distância * 150 AOA/km)
    Aplica arredondamento comercial justo para múltiplos de 50 Kz (moeda corrente em Angola).
    """
    preco_bruto = TAXA_BASE_AOA + (max(0.0, distancia_km) * VALOR_KM_AOA)
    # Arredonda para o múltiplo de 50 mais próximo (ex: 650, 700, 750)
    preco_arredondado = int(round(preco_bruto / 50.0) * 50)
    return max(int(TAXA_BASE_AOA), preco_arredondado)


def calcular_rota_e_frete(
    lat_origem: float,
    lon_origem: float,
    lat_destino: float,
    lon_destino: float,
) -> Dict[str, Any]:
    """
    Calcula a rota de condução entre dois pontos e estima o valor do frete.

    1. Tenta consultar a instância local/self-hosted do OSRM.
    2. Se o OSRM responder com sucesso, extrai a distância real pela malha viária,
       a duração estimada de tráfego e as coordenadas GeoJSON da rota.
    3. Se o OSRM estiver inacessível ou falhar, ativa automaticamente o fallback
       robusto via Haversine com fator de correção viária (1.3x).

    Retorna dicionário pronto para serialização JSON:
    {
        "sucesso": True,
        "distancia_km": 4.25,
        "duracao_minutos": 12,
        "preco_aoa": 1150,
        "moeda": "AOA",
        "geometria": [[lon1, lat1], [lon2, lat2], ...],
        "fonte": "osrm" | "haversine_fallback"
    }
    """
    # 1. Tentar consulta ao OSRM Self-Hosted
    # OSRM espera formato: {lon1},{lat1};{lon2},{lat2}
    endpoint_url = (
        f"{OSRM_BASE_URL}/route/v1/driving/"
        f"{lon_origem:.6f},{lat_origem:.6f};{lon_destino:.6f},{lat_destino:.6f}"
        f"?overview=full&geometries=geojson"
    )

    try:
        response = requests.get(endpoint_url, timeout=OSRM_TIMEOUT_SECONDS)
        if response.status_code == 200:
            data = response.json()
            if data.get("code") == "Ok" and data.get("routes"):
                rota_principal = data["routes"][0]
                distancia_metros = float(rota_principal.get("distance", 0.0))
                duracao_segundos = float(rota_principal.get("duration", 0.0))
                coordenadas_geojson = rota_principal.get("geometry", {}).get(
                    "coordinates", []
                )

                distancia_km = round(distancia_metros / 1000.0, 2)
                duracao_minutos = max(1, int(round(duracao_segundos / 60.0)))
                preco_aoa = calcular_preco_frete(distancia_km)

                return {
                    "sucesso": True,
                    "distancia_km": distancia_km,
                    "duracao_minutos": duracao_minutos,
                    "preco_aoa": preco_aoa,
                    "moeda": "AOA",
                    "geometria": coordenadas_geojson,
                    "fonte": "osrm",
                }
            else:
                logger.warning(
                    "OSRM retornou código não-Ok: %s. A ativar fallback Haversine.",
                    data.get("code"),
                )
        else:
            logger.warning(
                "OSRM respondeu com status HTTP %s. A ativar fallback Haversine.",
                response.status_code,
            )
    except Exception as exc:
        logger.warning(
            "Servidor OSRM indisponível (%s: %s). A utilizar fallback resiliente Haversine.",
            type(exc).__name__,
            exc,
        )

    # 2. Fallback de Alta Resiliência: Fórmula de Haversine * Fator de Correção Urbana (1.3)
    distancia_linha_reta = calcular_distancia_haversine(
        lat_origem, lon_origem, lat_destino, lon_destino
    )
    distancia_estimada_km = round(distancia_linha_reta * FATOR_CORRECAO_URBANA, 2)

    # Duração estimada com base na velocidade média urbana em Angola
    horas_estimadas = distancia_estimada_km / max(5.0, VELOCIDADE_MEDIA_URBANA_KMH)
    duracao_estimada_min = max(2, int(round(horas_estimadas * 60.0)))

    preco_aoa = calcular_preco_frete(distancia_estimada_km)

    # Geometria simplificada em linha reta entre os 2 pontos: [[lon1, lat1], [lon2, lat2]]
    geometria_fallback = [
        [round(lon_origem, 6), round(lat_origem, 6)],
        [round(lon_destino, 6), round(lat_destino, 6)],
    ]

    return {
        "sucesso": True,
        "distancia_km": distancia_estimada_km,
        "duracao_minutos": duracao_estimada_min,
        "preco_aoa": preco_aoa,
        "moeda": "AOA",
        "geometria": geometria_fallback,
        "fonte": "haversine_fallback",
    }
