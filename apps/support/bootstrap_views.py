"""
Endpoint de Alta Performance para Bootstrap Unificado de Parâmetros e Server-Driven UI.
Disponibiliza 100% das configurações remotas para clientes Flutter Mobile e Web em < 5ms.
"""
from __future__ import annotations

import hashlib
import json
import logging
from typing import Any, Dict

from django.core.cache import cache
from django.http import HttpRequest, HttpResponse, JsonResponse
from django.utils import timezone
from django.views.decorators.http import require_GET

from apps.support.models import AppBannerDinamico, Parametro

logger = logging.getLogger(__name__)

CACHE_KEY_BOOTSTRAP = "system_bootstrap_payload_v1"
CACHE_TTL_SECONDS = 3600  # 1 hora (invalidado automaticamente via post_save signals)


def build_system_bootstrap_data(request: HttpRequest) -> Dict[str, Any]:
    """
    Constrói a árvore canónica completa de parâmetros do sistema,
    organizada por domínios de negócio para consumo mobile e web.
    """
    agora = timezone.now()

    # 1. Carrega todos os parâmetros ativos
    parametros = Parametro.objects.all()
    params_by_cat: Dict[str, Dict[str, Any]] = {}
    raw_params: Dict[str, Any] = {}

    for p in parametros:
        val = p.get_valor_resolvido()
        raw_params[p.chave] = val
        cat = p.categoria
        if cat not in params_by_cat:
            params_by_cat[cat] = {}
        params_by_cat[cat][p.chave] = val

    branding_map = params_by_cat.get(Parametro.CategoriaParametro.BRANDING, {})
    design_map = params_by_cat.get(Parametro.CategoriaParametro.DESIGN_SYSTEM, {})
    cms_map = params_by_cat.get(Parametro.CategoriaParametro.TEXTOS_CMS, {})
    financas_map = params_by_cat.get(Parametro.CategoriaParametro.FINANCAS_TAXAS, {})
    logistica_map = params_by_cat.get(Parametro.CategoriaParametro.LOGISTICA, {})
    flags_map = params_by_cat.get(Parametro.CategoriaParametro.FEATURE_FLAGS, {})

    # 2. Carrega banners vigentes e ativos
    banners_validos = []
    for b in AppBannerDinamico.objects.filter(ativo=True).order_by("ordem", "-criado_em"):
        if b.inicio_vigencia and b.inicio_vigencia > agora:
            continue
        if b.fim_vigencia and b.fim_vigencia < agora:
            continue

        img_url = b.url_imagem_final
        if img_url and not img_url.startswith("http"):
            try:
                img_url = request.build_absolute_uri(img_url)
            except Exception:
                pass

        banners_validos.append(
            {
                "id": str(b.id),
                "titulo": b.titulo,
                "subtitulo": b.subtitulo,
                "tipo_banner": b.tipo_banner,
                "publico_alvo": b.publico_alvo,
                "imagem_url": img_url,
                "deeplink": b.deeplink,
                "cor_fundo": b.cor_fundo_hex or "#EA1D2C",
                "cor_texto": b.cor_texto_hex or "#FFFFFF",
                "ordem": b.ordem,
            }
        )

    modo_manutencao = bool(raw_params.get("MODO_MANUTENCAO", False))
    msg_manutencao = str(
        raw_params.get(
            "MENSAGEM_MANUTENCAO",
            "A plataforma está em manutenção temporária para melhorias operacionais. Voltamos em breve!",
        )
    )

    # Sincroniza com SystemConfiguration (Singleton de Governança Global)
    try:
        from core.models import SystemConfiguration
        sys_config = SystemConfiguration.objects.filter(pk=1).first()
        if sys_config:
            if sys_config.modo_manutencao:
                modo_manutencao = True
            if sys_config.mensagem_manutencao and "MENSAGEM_MANUTENCAO" not in raw_params:
                msg_manutencao = sys_config.mensagem_manutencao
            if "TAXA_BASE_ENTREGA_AOA" not in raw_params and sys_config.taxa_base_entrega_aoa is not None:
                raw_params["TAXA_BASE_ENTREGA_AOA"] = float(sys_config.taxa_base_entrega_aoa)
            if "VALOR_KM_ENTREGA_AOA" not in raw_params and sys_config.valor_km_entrega_aoa is not None:
                raw_params["VALOR_KM_ENTREGA_AOA"] = float(sys_config.valor_km_entrega_aoa)
            if "COMISSAO_MARKETPLACE_PERCENTAGEM" not in raw_params and sys_config.comissao_marketplace_percentagem is not None:
                raw_params["COMISSAO_MARKETPLACE_PERCENTAGEM"] = float(sys_config.comissao_marketplace_percentagem)
    except Exception:
        pass

    data: Dict[str, Any] = {
        "schema_version": "1.0.0",
        "timestamp": agora.isoformat(),
        "branding": {
            "app_name": str(raw_params.get("APP_NAME", "Ango_Ifood Delivery")),
            "app_slogan": str(raw_params.get("APP_SLOGAN", "A maior plataforma de entregas de Angola")),
            "logo_url": str(raw_params.get("APP_LOGO_URL", "")),
            "icon_url": str(raw_params.get("APP_ICON_URL", "")),
        },
        "design_system": {
            "primary_color": str(raw_params.get("PRIMARY_COLOR", "#EA1D2C")),
            "secondary_color": str(raw_params.get("SECONDARY_COLOR", "#0F172A")),
            "accent_color": str(raw_params.get("ACCENT_COLOR", "#F59E0B")),
            "background_screen": str(raw_params.get("BACKGROUND_SCREEN_COLOR", "#F8FAFC")),
            "background_card": str(raw_params.get("CARD_BACKGROUND_COLOR", "#FFFFFF")),
            "border_radius_base": str(raw_params.get("BORDER_RADIUS_BASE", "14px")),
            "font_family": str(raw_params.get("FONT_FAMILY", "Inter, system-ui, sans-serif")),
        },
        "strings": cms_map,
        "finances_and_fees": {
            "taxa_base_entrega_aoa": float(raw_params.get("TAXA_BASE_ENTREGA_AOA", 500.0)),
            "valor_km_entrega_aoa": float(raw_params.get("VALOR_KM_ENTREGA_AOA", 150.0)),
            "comissao_marketplace_percentagem": float(raw_params.get("COMISSAO_MARKETPLACE_PERCENTAGEM", 10.0)),
            "valor_minimo_pedido_aoa": float(raw_params.get("VALOR_MINIMO_PEDIDO_AOA", 1000.0)),
            "valor_minimo_saque_aoa": float(raw_params.get("VALOR_MINIMO_SAQUE_AOA", 2000.0)),
        },
        "logistics": {
            "raio_maximo_entrega_km": float(raw_params.get("RAIO_MAXIMO_ENTREGA_KM", 25.0)),
            "fator_correcao_urbana": float(raw_params.get("FATOR_CORRECAO_URBANA", 1.25)),
            "exigir_pin_entrega": bool(raw_params.get("EXIGIR_PIN_ENTREGA", True)),
        },
        "feature_flags": {
            "modulo_gorjetas_ativo": bool(raw_params.get("MODULO_GORJETAS_ATIVO", True)),
            "pagamento_dinheiro_ativo": bool(raw_params.get("PAGAMENTO_DINHEIRO_ATIVO", True)),
            "pagamento_express_ativo": bool(raw_params.get("PAGAMENTO_EXPRESS_ATIVO", True)),
            "tracking_gps_ao_vivo": bool(raw_params.get("TRACKING_GPS_AO_VIVO", True)),
            "modo_manutencao": modo_manutencao,
        },
        "maintenance": {
            "ativo": modo_manutencao,
            "mensagem": msg_manutencao,
        },
        "banners": banners_validos,
        "raw_parameters": raw_params,
    }

    return data


@require_GET
def system_bootstrap_api_view(request: HttpRequest) -> HttpResponse:
    """
    Endpoint: `GET /api/v1/system/bootstrap/`
    Retorna o estado consolidado de parametrização e Design System da aplicação.
    Suporta cache inteligente e ETag com resposta HTTP 304 Not Modified.
    """
    cached_data = cache.get(CACHE_KEY_BOOTSTRAP)
    if not cached_data:
        cached_data = build_system_bootstrap_data(request)
        cache.set(CACHE_KEY_BOOTSTRAP, cached_data, timeout=CACHE_TTL_SECONDS)

    payload_bytes = json.dumps(cached_data, sort_keys=True).encode("utf-8")
    etag = f'"{hashlib.md5(payload_bytes).hexdigest()}"'

    # Se o cliente já tiver a mesma versão no cache local, retorna HTTP 304 (0 bytes transferidos)
    client_etag = request.headers.get("If-None-Match")
    if client_etag and client_etag == etag:
        return HttpResponse(status=304)

    response = JsonResponse(cached_data, safe=False, status=200)
    response["ETag"] = etag
    response["Cache-Control"] = "public, max-age=60, stale-while-revalidate=120"
    return response


def invalidate_bootstrap_cache() -> None:
    """Invalida atómicamente a chave de cache do bootstrap em caso de mutação no Django Admin."""
    try:
        cache.delete(CACHE_KEY_BOOTSTRAP)
        logger.info("[CACHE] Chave de bootstrap do sistema invalidada com sucesso.")
    except Exception as e:
        logger.warning("[CACHE] Falha ao invalidar cache de bootstrap: %s", e)
