"""
Módulo de Gestão e Manipulação Dinâmica de Cores e Estilos do Django Admin (Unfold / Tailwind).
Disponibiliza o Estúdio de Personalização Visual Total com controlo sobre:
1. Botões & Ações Primárias (Primary Color Palette & Button Contrast)
2. Letras & Tipografia (Headings, Body Text, Subtle Labels, Font Family)
3. Fundos & Superfícies (Body, Sidebar, Header, Cards & DataTables)
4. Ícones, Badges & Bordas (Icons Accent, Status Badges, Border Radius)

Persistência unificada em BD (support.Parametro: 'ADMIN_THEME_CONFIG'), cookies de sessão e .env.
"""
from __future__ import annotations

import json
import os
from typing import Any, Dict, Optional, Tuple
from django.http import HttpRequest, HttpResponse, HttpResponseRedirect
from django.views.decorators.csrf import csrf_exempt


# ==============================================================================
# 1. CONFIGURAÇÃO BASE INSTITUCIONAL (DEFAULTS)
# ==============================================================================
DEFAULT_THEME_CONFIG: Dict[str, str] = {
    "theme_preset": "red",
    # 1. Botões & Ações Primárias
    "primary_hex": "#EA1D2C",
    "primary_contrast": "#FFFFFF",
    # 2. Letras & Tipografia
    "font_color_heading": "#111827",
    "font_color_default": "#1F2937",
    "font_color_subtle": "#6B7280",
    "font_family": "Inter, system-ui, -apple-system, sans-serif",
    # 3. Fundos & Superfícies
    "background_body": "#F9FAFB",
    "background_sidebar": "#FFFFFF",
    "background_cards": "#FFFFFF",
    "background_header": "#FFFFFF",
    # 4. Ícones, Badges & Bordas
    "icons_color": "#EA1D2C",
    "border_radius": "0.75rem",
    "dark_mode": "auto",
}


# ==============================================================================
# 2. PRESETS COMPLETOS PRÉ-CONFIGURADOS (TEMAS DE 1 CLIQUE)
# ==============================================================================
RICH_THEME_PRESETS: Dict[str, Dict[str, Any]] = {
    "red": {
        "name": "Ango_Ifood Oficial",
        "description": "Vermelho institucional vibrante, superfícies brancas e máximo contraste.",
        "primary_hex": "#EA1D2C",
        "primary_contrast": "#FFFFFF",
        "font_color_heading": "#111827",
        "font_color_default": "#1F2937",
        "font_color_subtle": "#6B7280",
        "font_family": "Inter, system-ui, sans-serif",
        "background_body": "#F9FAFB",
        "background_sidebar": "#FFFFFF",
        "background_cards": "#FFFFFF",
        "background_header": "#FFFFFF",
        "icons_color": "#EA1D2C",
        "border_radius": "0.75rem",
        "dark_mode": "light",
    },
    "emerald": {
        "name": "Esmeralda Logística",
        "description": "Verde esmeralda sustentável com tons naturais para despacho e frotas.",
        "primary_hex": "#10B981",
        "primary_contrast": "#FFFFFF",
        "font_color_heading": "#064E3B",
        "font_color_default": "#065F46",
        "font_color_subtle": "#6EE7B7",
        "font_family": "Inter, system-ui, sans-serif",
        "background_body": "#F0FDF4",
        "background_sidebar": "#FFFFFF",
        "background_cards": "#FFFFFF",
        "background_header": "#FFFFFF",
        "icons_color": "#10B981",
        "border_radius": "0.75rem",
        "dark_mode": "light",
    },
    "blue": {
        "name": "Azul Corporativo",
        "description": "Estilo clássico financeiro / bancário de alta solidez e legibilidade.",
        "primary_hex": "#2563EB",
        "primary_contrast": "#FFFFFF",
        "font_color_heading": "#0F172A",
        "font_color_default": "#1E293B",
        "font_color_subtle": "#64748B",
        "font_family": "Inter, system-ui, sans-serif",
        "background_body": "#F8FAFC",
        "background_sidebar": "#FFFFFF",
        "background_cards": "#FFFFFF",
        "background_header": "#FFFFFF",
        "icons_color": "#2563EB",
        "border_radius": "0.75rem",
        "dark_mode": "light",
    },
    "purple": {
        "name": "Roxo Tech & Inovação",
        "description": "Visual moderno voltado a tecnologia, inovação de produto e auditoria VIP.",
        "primary_hex": "#7C3AED",
        "primary_contrast": "#FFFFFF",
        "font_color_heading": "#2E1065",
        "font_color_default": "#3B0764",
        "font_color_subtle": "#7E22CE",
        "font_family": "Inter, system-ui, sans-serif",
        "background_body": "#FAF5FF",
        "background_sidebar": "#FFFFFF",
        "background_cards": "#FFFFFF",
        "background_header": "#FFFFFF",
        "icons_color": "#7C3AED",
        "border_radius": "0.75rem",
        "dark_mode": "light",
    },
    "amber": {
        "name": "Âmbar Restaurante",
        "description": "Tons quentes de gastronomia, ideal para gestão de cardápios e pedidos.",
        "primary_hex": "#F59E0B",
        "primary_contrast": "#FFFFFF",
        "font_color_heading": "#451A03",
        "font_color_default": "#78350F",
        "font_color_subtle": "#92400E",
        "font_family": "Inter, system-ui, sans-serif",
        "background_body": "#FFFBEB",
        "background_sidebar": "#FFFFFF",
        "background_cards": "#FFFFFF",
        "background_header": "#FFFFFF",
        "icons_color": "#D97706",
        "border_radius": "0.75rem",
        "dark_mode": "light",
    },
    "midnight": {
        "name": "Midnight AMOLED (Modo Noturno Total)",
        "description": "Fundo negro profundo com acentos ciano neon para operações noturnas e baixa fadiga.",
        "primary_hex": "#0EA5E9",
        "primary_contrast": "#FFFFFF",
        "font_color_heading": "#F8FAFC",
        "font_color_default": "#E2E8F0",
        "font_color_subtle": "#94A3B8",
        "font_family": "Inter, system-ui, sans-serif",
        "background_body": "#0B0F19",
        "background_sidebar": "#111827",
        "background_cards": "#1F2937",
        "background_header": "#111827",
        "icons_color": "#38BDF8",
        "border_radius": "0.75rem",
        "dark_mode": "dark",
    },
    "bronze": {
        "name": "Café & Bronze Luxo",
        "description": "Harmonia requintada de tons de café, couro e bronze com elegância sóbria.",
        "primary_hex": "#B45309",
        "primary_contrast": "#FFFFFF",
        "font_color_heading": "#1C1917",
        "font_color_default": "#292524",
        "font_color_subtle": "#78716C",
        "font_family": "Inter, system-ui, sans-serif",
        "background_body": "#FAFAF9",
        "background_sidebar": "#FFFFFF",
        "background_cards": "#FFFFFF",
        "background_header": "#FFFFFF",
        "icons_color": "#B45309",
        "border_radius": "0.75rem",
        "dark_mode": "light",
    },
}

# Compatibilidade retroativa com THEME_PRESETS simples
THEME_PRESETS = {
    k: {
        "name": v["name"],
        "hex": v["primary_hex"],
    }
    for k, v in RICH_THEME_PRESETS.items()
}


# ==============================================================================
# 3. MATEMÁTICA E CONVERSÃO DE CORES (HEX -> RGB -> TAILWIND)
# ==============================================================================
def hex_to_rgb(hex_code: str) -> Tuple[int, int, int]:
    """Converte código hexadecimal (#RRGGBB ou #RGB) em tupla RGB (r, g, b)."""
    if not hex_code:
        return (234, 29, 44)
    hex_clean = hex_code.strip().lstrip("#")
    if len(hex_clean) == 3:
        hex_clean = "".join(c * 2 for c in hex_clean)
    if len(hex_clean) != 6:
        return (234, 29, 44)
    try:
        return tuple(int(hex_clean[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore
    except ValueError:
        return (234, 29, 44)


def _blend_rgb(c1: Tuple[int, int, int], c2: Tuple[int, int, int], factor: float) -> Tuple[int, int, int]:
    """Interpolação linear precisa entre duas cores RGB."""
    return tuple(int(round(a + (b - a) * factor)) for a, b in zip(c1, c2))  # type: ignore


def generate_tailwind_palette(base_hex: str) -> Dict[str, str]:
    """
    Gera automaticamente as 11 tonalidades do Tailwind CSS (50 a 950)
    a partir de QUALQUER cor hexadecimal fornecida.
    """
    base_rgb = hex_to_rgb(base_hex)
    white = (255, 255, 255)
    black = (0, 0, 0)

    weights = {
        "50": _blend_rgb(base_rgb, white, 0.95),
        "100": _blend_rgb(base_rgb, white, 0.90),
        "200": _blend_rgb(base_rgb, white, 0.75),
        "300": _blend_rgb(base_rgb, white, 0.60),
        "400": _blend_rgb(base_rgb, white, 0.30),
        "500": base_rgb,
        "600": _blend_rgb(base_rgb, black, 0.15),
        "700": _blend_rgb(base_rgb, black, 0.30),
        "800": _blend_rgb(base_rgb, black, 0.45),
        "900": _blend_rgb(base_rgb, black, 0.60),
        "950": _blend_rgb(base_rgb, black, 0.75),
    }

    return {weight: f"{rgb[0]} {rgb[1]} {rgb[2]}" for weight, rgb in weights.items()}


def get_contrast_color(hex_code: str) -> str:
    """Calcula luminância relativa (WCAG 2.1) e retorna #FFFFFF ou #111827 para legibilidade perfeita."""
    r, g, b = hex_to_rgb(hex_code)
    luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    return "#111827" if luminance > 0.55 else "#FFFFFF"


# ==============================================================================
# 4. RESOLUÇÃO COMPLETA DE CONFIGURAÇÃO VISUAL
# ==============================================================================
def get_full_theme_config(request: Optional[HttpRequest] = None) -> Dict[str, str]:
    """
    Resolve a configuração visual completa respeitando rigorosamente a hierarquia:
    1. Query Params (?admin_color=... ou ?admin_theme=...)
    2. Cookie de sessão individual ('django_admin_theme_config' ou 'django_admin_color')
    3. Parâmetro global persistido na BD ('ADMIN_THEME_CONFIG' ou 'ADMIN_THEME_COLOR')
    4. Variáveis de ambiente
    5. Configuração base Institucional Ango_Ifood (#EA1D2C)
    """
    config: Dict[str, str] = dict(DEFAULT_THEME_CONFIG)

    # 1. Tenta carregar configuração global da Base de Dados
    try:
        from apps.support.models import Parametro
        p_json = Parametro.objects.filter(chave="ADMIN_THEME_CONFIG").first()
        if p_json and p_json.valor:
            try:
                db_data = json.loads(p_json.valor)
                if isinstance(db_data, dict):
                    config.update(db_data)
            except Exception:
                pass
        else:
            # Compatibilidade com parâmetro de cor simples
            p_simple = Parametro.objects.filter(chave="ADMIN_THEME_COLOR").first()
            if p_simple and p_simple.valor:
                val = str(p_simple.valor).strip()
                if val.lower() in RICH_THEME_PRESETS:
                    config.update(RICH_THEME_PRESETS[val.lower()])
                elif val.startswith("#"):
                    config["primary_hex"] = val
                    config["icons_color"] = val
                    config["primary_contrast"] = get_contrast_color(val)
    except Exception:
        pass

    # 2. Sobrescreve com Variáveis de Ambiente se configuradas
    env_theme = os.environ.get("DJANGO_ADMIN_THEME")
    env_primary = os.environ.get("DJANGO_ADMIN_PRIMARY_COLOR")
    if env_theme and env_theme.lower() in RICH_THEME_PRESETS:
        config.update(RICH_THEME_PRESETS[env_theme.lower()])
    if env_primary and env_primary.startswith("#"):
        config["primary_hex"] = env_primary
        config["icons_color"] = env_primary
        config["primary_contrast"] = get_contrast_color(env_primary)

    # 3. Sobrescreve com Cookie Individual do Operador (se existir)
    if request and hasattr(request, "COOKIES"):
        cookie_cfg = request.COOKIES.get("django_admin_theme_config")
        if cookie_cfg:
            try:
                cookie_data = json.loads(cookie_cfg)
                if isinstance(cookie_data, dict):
                    config.update(cookie_data)
            except Exception:
                pass
        else:
            cookie_color = request.COOKIES.get("django_admin_color")
            cookie_theme = request.COOKIES.get("django_admin_theme")
            if cookie_color and cookie_color.startswith("#"):
                config["primary_hex"] = cookie_color
                config["icons_color"] = cookie_color
                config["primary_contrast"] = get_contrast_color(cookie_color)
            elif cookie_theme and cookie_theme.lower() in RICH_THEME_PRESETS:
                config.update(RICH_THEME_PRESETS[cookie_theme.lower()])

    # 4. Sobrescreve com parâmetros diretos de URL (para testes instantâneos)
    if request and hasattr(request, "GET"):
        url_theme = request.GET.get("admin_theme")
        url_color = request.GET.get("admin_color")
        if url_theme and url_theme.lower() in RICH_THEME_PRESETS:
            config.update(RICH_THEME_PRESETS[url_theme.lower()])
        if url_color and url_color.startswith("#"):
            config["primary_hex"] = url_color
            config["icons_color"] = url_color
            config["primary_contrast"] = get_contrast_color(url_color)

    # Garante coerência no contraste do botão primário
    if not config.get("primary_contrast"):
        config["primary_contrast"] = get_contrast_color(config.get("primary_hex", "#EA1D2C"))

    return config


def get_admin_colors(request: Optional[HttpRequest] = None) -> Dict[str, Dict[str, str]]:
    """
    Callback dinâmico chamado pelo Unfold para construir as paletas Tailwind do Admin.
    """
    config = get_full_theme_config(request)
    primary_palette = generate_tailwind_palette(config["primary_hex"])

    # Base palette calculada dinamicamente a partir da cor de fundo configurada
    bg_hex = config.get("background_body", "#F9FAFB")
    base_palette = generate_tailwind_palette(bg_hex)

    return {
        "primary": primary_palette,
        "base": base_palette,
        "font": {
            "subtle-light": config.get("font_color_subtle", "#6B7280"),
            "subtle-dark": "#9CA3AF",
            "default-light": config.get("font_color_default", "#1F2937"),
            "default-dark": "#F3F4F6",
            "important-light": config.get("font_color_heading", "#111827"),
            "important-dark": "#FFFFFF",
        },
    }


def get_theme_border_radius(request: Optional[HttpRequest] = None) -> str:
    """Retorna o raio de curvatura de bordas ativo."""
    cfg = get_full_theme_config(request)
    return cfg.get("border_radius", "0.75rem")


def save_full_theme_config(config_dict: Dict[str, Any], global_save: bool = True) -> bool:
    """
    Persiste a configuração completa do tema no banco de dados na tabela Parametro.
    """
    cleaned: Dict[str, str] = {}
    for key, val in config_dict.items():
        if val is not None:
            cleaned[key] = str(val).strip()

    if global_save:
        try:
            from apps.support.models import Parametro
            json_str = json.dumps(cleaned, ensure_ascii=False)
            Parametro.objects.update_or_create(
                chave="ADMIN_THEME_CONFIG",
                defaults={
                    "nome": "Configuração Visual Total do Django Admin",
                    "valor": json_str,
                    "unidade": "JSON Config",
                    "ambito": "SISTEMA",
                },
            )
            # Atualiza também a chave legada simples com a cor primária
            if "primary_hex" in cleaned:
                Parametro.objects.update_or_create(
                    chave="ADMIN_THEME_COLOR",
                    defaults={
                        "nome": "Cor Visual Primária do Django Admin",
                        "valor": cleaned["primary_hex"],
                        "unidade": "HEX",
                        "ambito": "SISTEMA",
                    },
                )
            return True
        except Exception:
            return False
    return True


def set_admin_theme(theme_name_or_hex: str) -> bool:
    """Compatibilidade retroativa: ativa um preset ou uma cor primária."""
    val = theme_name_or_hex.strip()
    if val.lower() in RICH_THEME_PRESETS:
        preset_cfg = dict(RICH_THEME_PRESETS[val.lower()])
        preset_cfg["theme_preset"] = val.lower()
        return save_full_theme_config(preset_cfg, global_save=True)
    elif val.startswith("#"):
        cfg = dict(DEFAULT_THEME_CONFIG)
        cfg["theme_preset"] = "custom"
        cfg["primary_hex"] = val
        cfg["icons_color"] = val
        cfg["primary_contrast"] = get_contrast_color(val)
        return save_full_theme_config(cfg, global_save=True)
    return False


def list_available_themes() -> list[dict[str, str]]:
    """Lista todos os presets prontos com metadados e cores."""
    return [
        {
            "id": key,
            "name": data["name"],
            "description": data["description"],
            "hex": data["primary_hex"],
            "bg": data["background_body"],
        }
        for key, data in RICH_THEME_PRESETS.items()
    ]


# ==============================================================================
# 5. ENDPOINT DINÂMICO DE CSS (/admin/theme/dynamic.css)
# ==============================================================================
def admin_dynamic_css_view(request: HttpRequest) -> HttpResponse:
    """
    Gera dinamicamente a folha de estilos CSS injetada no Django Admin.
    Controla letras, botões, fundos, cabeçalho, sidebar e ícones com especificidade cirúrgica.
    """
    cfg = get_full_theme_config(request)
    primary_hex = cfg.get("primary_hex", "#EA1D2C")
    contrast_hex = cfg.get("primary_contrast", "#FFFFFF")
    bg_body = cfg.get("background_body", "#F9FAFB")
    bg_sidebar = cfg.get("background_sidebar", "#FFFFFF")
    bg_cards = cfg.get("background_cards", "#FFFFFF")
    bg_header = cfg.get("background_header", "#FFFFFF")
    text_heading = cfg.get("font_color_heading", "#111827")
    text_default = cfg.get("font_color_default", "#1F2937")
    text_subtle = cfg.get("font_color_subtle", "#6B7280")
    icons_color = cfg.get("icons_color", primary_hex)
    border_rad = cfg.get("border_radius", "0.75rem")
    font_fam = cfg.get("font_family", "Inter, sans-serif")

    # Calcula variantes de hover (15% mais escuro)
    pr, pg, pb = hex_to_rgb(primary_hex)
    hover_rgb = _blend_rgb((pr, pg, pb), (0, 0, 0), 0.15)
    hover_hex = f"#{hover_rgb[0]:02x}{hover_rgb[1]:02x}{hover_rgb[2]:02x}"

    css_content = f"""/* ==============================================================================
   Ango_Ifood Delivery — Folha de Estilos Dinâmica do Django Admin
   Gerada em runtime por core.admin_theme.admin_dynamic_css_view
   ============================================================================== */

:root {{
    --ango-primary: {primary_hex};
    --ango-primary-hover: {hover_hex};
    --ango-primary-contrast: {contrast_hex};
    --ango-bg-body: {bg_body};
    --ango-bg-sidebar: {bg_sidebar};
    --ango-bg-cards: {bg_cards};
    --ango-bg-header: {bg_header};
    --ango-text-heading: {text_heading};
    --ango-text-default: {text_default};
    --ango-text-subtle: {text_subtle};
    --ango-icons: {icons_color};
    --ango-radius: {border_rad};
    --border-radius: {border_rad};
    --font-family-sans: {font_fam};
}}

/* 1. TIPOGRAFIA & LETRAS */
body, html {{
    font-family: var(--font-family-sans) !important;
    color: var(--ango-text-default);
}}

h1, h2, h3, .content-title, .module h2 {{
    color: var(--ango-text-heading) !important;
}}

.text-font-subtle-light, .help, .help-tooltip {{
    color: var(--ango-text-subtle) !important;
}}

/* 2. FUNDOS & SUPERFÍCIES */
body {{
    background-color: var(--ango-bg-body) !important;
}}

/* Barra Lateral (Sidebar) */
#nav-sidebar, aside, [x-ref="sidebar"] {{
    background-color: var(--ango-bg-sidebar) !important;
}}

/* Cabeçalho Superior */
header, #header, .header-container {{
    background-color: var(--ango-bg-header) !important;
}}

/* Cartões, Módulos e Tabelas */
.module, .card, .bg-white, table thead th, .change-list .filtered {{
    border-radius: var(--ango-radius) !important;
}}

/* 3. BOTÕES & AÇÕES */
/* Botões Primários */
.btn-primary, button[type="submit"]:not(.btn-secondary), input[type="submit"]:not(.btn-secondary),
.button.default, .actions button[type="submit"] {{
    background-color: var(--ango-primary) !important;
    color: var(--ango-primary-contrast) !important;
    border-color: var(--ango-primary) !important;
    border-radius: var(--ango-radius) !important;
    font-weight: 600 !important;
    transition: all 0.15s ease-in-out !important;
}}

.btn-primary:hover, button[type="submit"]:not(.btn-secondary):hover, input[type="submit"]:not(.btn-secondary):hover {{
    background-color: var(--ango-primary-hover) !important;
    border-color: var(--ango-primary-hover) !important;
}}

/* Foco de Acessibilidade */
button:focus-visible, input:focus-visible, a:focus-visible {{
    outline: 2px solid var(--ango-primary) !important;
    outline-offset: 2px !important;
}}

/* 4. ÍCONES & ACENTOS */
/* Ícones da Sidebar e Ações */
.material-symbols-outlined, .sidebar-icon, .nav-icon {{
    color: var(--ango-icons) !important;
}}

/* Links Ativos da Navegação */
.nav-link.active, .sidebar-item-active {{
    border-left-color: var(--ango-primary) !important;
    background-color: rgba({pr}, {pg}, {pb}, 0.08) !important;
    color: var(--ango-primary) !important;
}}

/* Badges e Acentos Arredondados */
.rounded-lg, .rounded-xl {{
    border-radius: var(--ango-radius) !important;
}}
"""
    response = HttpResponse(css_content, content_type="text/css; charset=utf-8")
    response["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response["Pragma"] = "no-cache"
    response["Expires"] = "0"
    return response


# ==============================================================================
# 6. ESTÚDIO DE PERSONALIZAÇÃO VISUAL TOTAL (/admin/theme/)
# ==============================================================================
def admin_theme_picker_view(request: HttpRequest) -> HttpResponse:
    """
    Interface Web do Estúdio de Personalização Visual Total do Django Admin.
    Permite manipular em tempo real:
    - Botões & Cor Primária
    - Letras (Títulos, Textos e Subtis)
    - Fundos (Corpo, Barra Lateral, Cartões, Cabeçalho)
    - Ícones, Badges & Bordas
    Inclui Mockup Interativo com Preview ao Vivo com JavaScript.
    """
    if not request.user.is_authenticated or not request.user.is_staff:
        return HttpResponseRedirect(f"/admin/login/?next={request.path}")

    cfg = get_full_theme_config(request)
    saved_param = request.GET.get("saved")

    # Renderização dos Cards de Presets Rápidos
    presets_html = ""
    for pid, pdata in RICH_THEME_PRESETS.items():
        is_active = cfg.get("theme_preset") == pid or cfg.get("primary_hex") == pdata["primary_hex"]
        active_badge = (
            '<span class="px-2 py-0.5 text-[10px] font-bold text-white bg-green-600 rounded-full">ATIVO</span>'
            if is_active
            else ""
        )
        border_cls = "ring-2 ring-primary-500 border-primary-500" if is_active else "border-gray-200 hover:border-gray-400"

        presets_html += f"""
        <div class="bg-white rounded-xl border {border_cls} p-4 shadow-sm hover:shadow-md transition-all flex flex-col justify-between">
            <div>
                <div class="flex items-center justify-between mb-3">
                    <span class="font-bold text-gray-900 text-sm">{pdata['name']}</span>
                    {active_badge}
                </div>
                <div class="flex items-center space-x-2 mb-3">
                    <div class="w-8 h-8 rounded-lg shadow-sm border border-black/10" style="background-color: {pdata['primary_hex']};" title="Primária"></div>
                    <div class="w-8 h-8 rounded-lg shadow-sm border border-gray-300" style="background-color: {pdata['background_body']};" title="Fundo"></div>
                    <div class="w-8 h-8 rounded-lg shadow-sm border border-gray-300" style="background-color: {pdata['font_color_heading']};" title="Letras"></div>
                </div>
                <p class="text-xs text-gray-500 line-clamp-2 mb-4 leading-relaxed">{pdata['description']}</p>
            </div>
            <a href="/admin/theme/set/{pid}/" class="block w-full py-2 px-3 text-center text-xs font-bold rounded-lg transition-colors text-white shadow-sm" style="background-color: {pdata['primary_hex']};">
                {"✓ Em Uso" if is_active else "Ativar Preset"}
            </a>
        </div>
        """

    saved_alert = ""
    if saved_param == "global":
        saved_alert = """
        <div class="mb-6 p-4 rounded-xl bg-green-50 border border-green-200 flex items-center justify-between animate-fade-in">
            <div class="flex items-center space-x-3 text-green-800 text-sm font-semibold">
                <span class="text-xl">✅</span>
                <span>Configuração visual gravada com sucesso em todo o sistema (Banco de Dados)!</span>
            </div>
            <a href="/admin/" class="text-xs bg-green-600 hover:bg-green-700 text-white font-bold py-1.5 px-3 rounded-lg">Abrir Admin</a>
        </div>
        """
    elif saved_param == "session":
        saved_alert = """
        <div class="mb-6 p-4 rounded-xl bg-blue-50 border border-blue-200 flex items-center justify-between animate-fade-in">
            <div class="flex items-center space-x-3 text-blue-800 text-sm font-semibold">
                <span class="text-xl">👤</span>
                <span>Configuração visual guardada apenas para a sua sessão pessoal neste navegador!</span>
            </div>
            <a href="/admin/" class="text-xs bg-blue-600 hover:bg-blue-700 text-white font-bold py-1.5 px-3 rounded-lg">Abrir Admin</a>
        </div>
        """

    html = f"""<!DOCTYPE html>
<html lang="pt">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Ango_Ifood — Estúdio de Personalização Visual Total</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=Material+Symbols+Outlined:opsz,wght,FILL,GRAD@24,400,0,0" rel="stylesheet">
    <style>
        body {{ font-family: 'Inter', system-ui, sans-serif; }}
        .color-preview-box {{ transition: all 0.2s ease-in-out; }}
    </style>
</head>
<body class="bg-gray-100 min-h-screen text-gray-800 antialiased pb-24">
    <!-- Top Bar -->
    <header class="bg-white border-b border-gray-200 sticky top-0 z-30 shadow-sm">
        <div class="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
            <div class="flex items-center space-x-3">
                <div class="w-10 h-10 rounded-xl flex items-center justify-center text-white shadow-md" style="background-color: {cfg['primary_hex']};">
                    <span class="material-symbols-outlined text-2xl">palette</span>
                </div>
                <div>
                    <h1 class="text-lg font-bold text-gray-900 leading-tight">Estúdio de Personalização Visual do Django Admin</h1>
                    <p class="text-xs text-gray-500">Ango_Ifood Delivery &bull; Gestão Completa de Letras, Botões, Fundos e Ícones</p>
                </div>
            </div>
            <div class="flex items-center space-x-3">
                <a href="/admin/" class="inline-flex items-center px-4 py-2 bg-gray-100 hover:bg-gray-200 text-gray-800 text-sm font-semibold rounded-lg transition">
                    ← Voltar ao Painel Admin
                </a>
            </div>
        </div>
    </header>

    <main class="max-w-7xl mx-auto px-6 py-8">
        {saved_alert}

        <!-- Secção 1: Presets Rápidos -->
        <div class="mb-10">
            <div class="flex items-center justify-between mb-4">
                <div>
                    <h2 class="text-base font-bold text-gray-900">Temas Completos Prontos (1-Clique)</h2>
                    <p class="text-xs text-gray-500">Paletas pré-configuradas e testadas para máxima harmonia visual e acessibilidade.</p>
                </div>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
                {presets_html}
            </div>
        </div>

        <!-- Secção 2: Personalizador Detalhado das 4 Dimensões + Mockup Ao Vivo -->
        <form id="themeForm" method="POST" action="/admin/theme/save/">
            <div class="grid grid-cols-1 lg:grid-cols-12 gap-8 items-start">
                
                <!-- Coluna de Controlos das 4 Dimensões (7 Colunas) -->
                <div class="lg:col-span-7 space-y-6">
                    <div class="bg-white rounded-2xl border border-gray-200 shadow-sm overflow-hidden">
                        <div class="p-5 border-b border-gray-100 bg-gray-50/70 flex items-center justify-between">
                            <div>
                                <h3 class="font-bold text-gray-900 text-base">Painel de Controlo das 4 Camadas Visuais</h3>
                                <p class="text-xs text-gray-500">Ajuste individualmente cores de texto, superfícies, ações e ornamentos.</p>
                            </div>
                            <span class="text-xs px-2.5 py-1 bg-gray-200 text-gray-700 font-mono rounded-lg">Tailwind/Unfold</span>
                        </div>

                        <div class="p-6 space-y-8">
                            <!-- 1. Botões & Ações Primárias -->
                            <div>
                                <div class="flex items-center space-x-2 mb-3">
                                    <span class="w-6 h-6 rounded-md flex items-center justify-center text-xs font-bold bg-red-100 text-red-600">1</span>
                                    <h4 class="font-bold text-sm text-gray-900 uppercase tracking-wide">Botões & Ações Primárias</h4>
                                </div>
                                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Cor Primária dos Botões (HEX)</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="primary_hex_picker" value="{cfg['primary_hex']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('primary_hex', this.value)">
                                            <input type="text" id="primary_hex" name="primary_hex" value="{cfg['primary_hex']}" class="w-full text-xs font-mono uppercase font-bold py-2.5 px-3 border border-gray-300 rounded-lg focus:ring-2 focus:ring-primary-500" oninput="syncColor('primary_hex_picker', this.value)">
                                        </div>
                                    </div>
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Texto de Contraste do Botão</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="primary_contrast_picker" value="{cfg['primary_contrast']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('primary_contrast', this.value)">
                                            <input type="text" id="primary_contrast" name="primary_contrast" value="{cfg['primary_contrast']}" class="w-full text-xs font-mono uppercase font-bold py-2.5 px-3 border border-gray-300 rounded-lg" oninput="syncColor('primary_contrast_picker', this.value)">
                                        </div>
                                    </div>
                                </div>
                            </div>

                            <!-- 2. Letras & Tipografia -->
                            <div class="border-t border-gray-100 pt-6">
                                <div class="flex items-center space-x-2 mb-3">
                                    <span class="w-6 h-6 rounded-md flex items-center justify-center text-xs font-bold bg-blue-100 text-blue-600">2</span>
                                    <h4 class="font-bold text-sm text-gray-900 uppercase tracking-wide">Letras & Tipografia</h4>
                                </div>
                                <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Títulos & Cabeçalhos</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="font_heading_picker" value="{cfg['font_color_heading']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('font_color_heading', this.value)">
                                            <input type="text" id="font_color_heading" name="font_color_heading" value="{cfg['font_color_heading']}" class="w-full text-xs font-mono uppercase font-bold py-2 px-2 border border-gray-300 rounded-lg" oninput="syncColor('font_heading_picker', this.value)">
                                        </div>
                                    </div>
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Texto Principal (Corpo)</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="font_default_picker" value="{cfg['font_color_default']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('font_color_default', this.value)">
                                            <input type="text" id="font_color_default" name="font_color_default" value="{cfg['font_color_default']}" class="w-full text-xs font-mono uppercase font-bold py-2 px-2 border border-gray-300 rounded-lg" oninput="syncColor('font_default_picker', this.value)">
                                        </div>
                                    </div>
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Textos Subtis / Legendas</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="font_subtle_picker" value="{cfg['font_color_subtle']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('font_color_subtle', this.value)">
                                            <input type="text" id="font_color_subtle" name="font_color_subtle" value="{cfg['font_color_subtle']}" class="w-full text-xs font-mono uppercase font-bold py-2 px-2 border border-gray-300 rounded-lg" oninput="syncColor('font_subtle_picker', this.value)">
                                        </div>
                                    </div>
                                </div>
                            </div>

                            <!-- 3. Fundos & Superfícies -->
                            <div class="border-t border-gray-100 pt-6">
                                <div class="flex items-center space-x-2 mb-3">
                                    <span class="w-6 h-6 rounded-md flex items-center justify-center text-xs font-bold bg-green-100 text-green-600">3</span>
                                    <h4 class="font-bold text-sm text-gray-900 uppercase tracking-wide">Fundos & Superfícies</h4>
                                </div>
                                <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Fundo da Página (Body)</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="bg_body_picker" value="{cfg['background_body']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('background_body', this.value)">
                                            <input type="text" id="background_body" name="background_body" value="{cfg['background_body']}" class="w-full text-xs font-mono uppercase font-bold py-2 px-2 border border-gray-300 rounded-lg" oninput="syncColor('bg_body_picker', this.value)">
                                        </div>
                                    </div>
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Fundo Barra Lateral (Sidebar)</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="bg_sidebar_picker" value="{cfg['background_sidebar']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('background_sidebar', this.value)">
                                            <input type="text" id="background_sidebar" name="background_sidebar" value="{cfg['background_sidebar']}" class="w-full text-xs font-mono uppercase font-bold py-2 px-2 border border-gray-300 rounded-lg" oninput="syncColor('bg_sidebar_picker', this.value)">
                                        </div>
                                    </div>
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Fundo dos Cartões / Tabelas</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="bg_cards_picker" value="{cfg['background_cards']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('background_cards', this.value)">
                                            <input type="text" id="background_cards" name="background_cards" value="{cfg['background_cards']}" class="w-full text-xs font-mono uppercase font-bold py-2 px-2 border border-gray-300 rounded-lg" oninput="syncColor('bg_cards_picker', this.value)">
                                        </div>
                                    </div>
                                </div>
                            </div>

                            <!-- 4. Ícones, Bordas & Arredondamentos -->
                            <div class="border-t border-gray-100 pt-6">
                                <div class="flex items-center space-x-2 mb-3">
                                    <span class="w-6 h-6 rounded-md flex items-center justify-center text-xs font-bold bg-purple-100 text-purple-600">4</span>
                                    <h4 class="font-bold text-sm text-gray-900 uppercase tracking-wide">Ícones & Bordas</h4>
                                </div>
                                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Cor dos Ícones de Destaque</label>
                                        <div class="flex items-center space-x-2">
                                            <input type="color" id="icons_picker" value="{cfg['icons_color']}" class="w-10 h-10 p-0.5 rounded-lg border border-gray-300 cursor-pointer" oninput="syncColor('icons_color', this.value)">
                                            <input type="text" id="icons_color" name="icons_color" value="{cfg['icons_color']}" class="w-full text-xs font-mono uppercase font-bold py-2.5 px-3 border border-gray-300 rounded-lg" oninput="syncColor('icons_picker', this.value)">
                                        </div>
                                    </div>
                                    <div>
                                        <label class="block text-xs font-semibold text-gray-700 mb-1">Raio de Arredondamento</label>
                                        <select id="border_radius" name="border_radius" class="w-full text-xs font-bold py-3 px-3 border border-gray-300 rounded-lg bg-white" onchange="updateLivePreview()">
                                            <option value="0.375rem" {"selected" if cfg.get("border_radius") == "0.375rem" else ""}>Pequeno (6px - Compacto)</option>
                                            <option value="0.5rem" {"selected" if cfg.get("border_radius") == "0.5rem" else ""}>Médio (8px - Padrão)</option>
                                            <option value="0.75rem" {"selected" if cfg.get("border_radius") == "0.75rem" else ""}>Arredondado (12px - Moderno Ango_Ifood)</option>
                                            <option value="1rem" {"selected" if cfg.get("border_radius") == "1rem" else ""}>Grande (16px - Suave)</option>
                                            <option value="9999px" {"selected" if cfg.get("border_radius") == "9999px" else ""}>Pílula Total (Pill Style)</option>
                                        </select>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Coluna de Mockup Interativo Ao Vivo (5 Colunas) -->
                <div class="lg:col-span-5 sticky top-24 space-y-4">
                    <div class="bg-gray-900 rounded-2xl p-4 text-white shadow-lg">
                        <div class="flex items-center justify-between mb-3">
                            <div class="flex items-center space-x-2">
                                <span class="w-2.5 h-2.5 rounded-full bg-green-500 animate-pulse"></span>
                                <span class="text-xs font-bold tracking-wider uppercase text-gray-300">Preview em Tempo Real</span>
                            </div>
                            <span class="text-[11px] text-gray-400 font-mono">Atualização Instantânea</span>
                        </div>
                        
                        <!-- Janela de Simulação do Admin -->
                        <div id="previewWindow" class="rounded-xl border border-gray-700 overflow-hidden shadow-inner flex" style="background-color: {cfg['background_body']}; min-height: 420px;">
                            <!-- Mini Sidebar -->
                            <div id="previewSidebar" class="w-28 border-r border-gray-200 p-3 flex flex-col justify-between" style="background-color: {cfg['background_sidebar']};">
                                <div>
                                    <div class="flex items-center space-x-1.5 mb-4">
                                        <div id="previewLogo" class="w-4 h-4 rounded flex items-center justify-center text-[9px] text-white font-bold" style="background-color: {cfg['primary_hex']};">A</div>
                                        <span class="text-[9px] font-bold text-gray-800">Ango_Ifood</span>
                                    </div>
                                    <div class="space-y-2">
                                        <div class="flex items-center space-x-1.5 px-1.5 py-1 rounded bg-black/5 text-[9px] font-semibold text-gray-800">
                                            <span id="previewIcon1" class="material-symbols-outlined text-[13px]" style="color: {cfg['icons_color']};">shopping_bag</span>
                                            <span>Pedidos</span>
                                        </div>
                                        <div class="flex items-center space-x-1.5 px-1.5 py-1 text-[9px] text-gray-500">
                                            <span id="previewIcon2" class="material-symbols-outlined text-[13px]" style="color: {cfg['icons_color']};">two_wheeler</span>
                                            <span>Estafetas</span>
                                        </div>
                                        <div class="flex items-center space-x-1.5 px-1.5 py-1 text-[9px] text-gray-500">
                                            <span id="previewIcon3" class="material-symbols-outlined text-[13px]" style="color: {cfg['icons_color']};">storefront</span>
                                            <span>Lojas</span>
                                        </div>
                                    </div>
                                </div>
                                <div class="text-[8px] text-gray-400 font-mono">v2.0 Admin</div>
                            </div>

                            <!-- Mini Conteúdo -->
                            <div class="flex-1 p-3 flex flex-col justify-between">
                                <div>
                                    <div class="flex items-center justify-between pb-2 mb-3 border-b border-black/5">
                                        <h5 id="previewHeading" class="text-xs font-bold" style="color: {cfg['font_color_heading']};">Painel de Controlo</h5>
                                        <span id="previewBadge" class="text-[9px] px-2 py-0.5 rounded-full font-bold" style="background-color: {cfg['primary_hex']}; color: {cfg['primary_contrast']};">ATIVO</span>
                                    </div>

                                    <!-- Mini Cartão de Métrica -->
                                    <div id="previewCard" class="p-2.5 rounded-lg shadow-sm border border-black/5 mb-3" style="background-color: {cfg['background_cards']};">
                                        <span id="previewSubtle" class="text-[9px] block mb-0.5" style="color: {cfg['font_color_subtle']};">Total de Pedidos Hoje</span>
                                        <span id="previewMetric" class="text-sm font-extrabold" style="color: {cfg['font_color_heading']};">48 Pedidos</span>
                                    </div>

                                    <!-- Mini Tabela -->
                                    <div class="rounded border border-black/5 overflow-hidden text-[9px] bg-white">
                                        <div class="bg-gray-50 px-2 py-1 font-bold text-gray-700 border-b border-black/5">Pedido #B9B202</div>
                                        <div id="previewDefaultText" class="px-2 py-1.5" style="color: {cfg['font_color_default']};">Restaurante Luanda Gourmet &bull; 12.500 Kz</div>
                                    </div>
                                </div>

                                <!-- Mini Botões -->
                                <div class="flex items-center space-x-2 pt-2">
                                    <button type="button" id="previewBtn" class="flex-1 py-1.5 px-2 text-[10px] font-bold rounded shadow-sm transition text-center" style="background-color: {cfg['primary_hex']}; color: {cfg['primary_contrast']};">
                                        Confirmar Pedido
                                    </button>
                                    <button type="button" class="py-1.5 px-2 text-[10px] font-semibold bg-gray-200 text-gray-700 rounded">
                                        CSV
                                    </button>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- Botões de Ação de Salvamento -->
                    <div class="bg-white rounded-2xl p-5 border border-gray-200 shadow-sm space-y-3">
                        <button type="submit" name="scope" value="global" class="w-full py-3.5 px-4 bg-gray-900 hover:bg-black text-white text-sm font-bold rounded-xl shadow transition flex items-center justify-center space-x-2">
                            <span>💾</span>
                            <span>Salvar em Todo o Sistema (Global)</span>
                        </button>
                        <button type="submit" name="scope" value="session" class="w-full py-3 px-4 bg-gray-100 hover:bg-gray-200 text-gray-800 text-xs font-bold rounded-xl transition flex items-center justify-center space-x-2">
                            <span>👤</span>
                            <span>Aplicar Apenas no Meu Navegador</span>
                        </button>
                        <a href="/admin/theme/set/red/" class="block w-full text-center py-2 text-xs font-semibold text-gray-500 hover:text-red-600 transition">
                            ↺ Restaurar Vermelho Oficial Ango_Ifood
                        </a>
                    </div>
                </div>

            </div>
        </form>
    </main>

    <script>
        function syncColor(targetId, val) {{
            const target = document.getElementById(targetId);
            if (target) {{
                target.value = val;
            }}
            updateLivePreview();
        }}

        function updateLivePreview() {{
            const primary = document.getElementById('primary_hex').value;
            const contrast = document.getElementById('primary_contrast').value;
            const heading = document.getElementById('font_color_heading').value;
            const defaultText = document.getElementById('font_color_default').value;
            const subtleText = document.getElementById('font_color_subtle').value;
            const bgBody = document.getElementById('background_body').value;
            const bgSidebar = document.getElementById('background_sidebar').value;
            const bgCards = document.getElementById('background_cards').value;
            const icons = document.getElementById('icons_color').value;
            const radius = document.getElementById('border_radius').value;

            // Elementos da janela de simulação
            document.getElementById('previewWindow').style.backgroundColor = bgBody;
            document.getElementById('previewSidebar').style.backgroundColor = bgSidebar;
            document.getElementById('previewCard').style.backgroundColor = bgCards;
            document.getElementById('previewCard').style.borderRadius = radius;
            document.getElementById('previewHeading').style.color = heading;
            document.getElementById('previewMetric').style.color = heading;
            document.getElementById('previewDefaultText').style.color = defaultText;
            document.getElementById('previewSubtle').style.color = subtleText;
            document.getElementById('previewLogo').style.backgroundColor = primary;
            document.getElementById('previewBtn').style.backgroundColor = primary;
            document.getElementById('previewBtn').style.color = contrast;
            document.getElementById('previewBtn').style.borderRadius = radius;
            document.getElementById('previewBadge').style.backgroundColor = primary;
            document.getElementById('previewBadge').style.color = contrast;

            ['previewIcon1', 'previewIcon2', 'previewIcon3'].forEach(id => {{
                const el = document.getElementById(id);
                if (el) el.style.color = icons;
            }});
        }}

        // Inicializa o preview dinâmico no carregamento da página
        document.addEventListener('DOMContentLoaded', updateLivePreview);
    </script>
</body>
</html>"""
    return HttpResponse(html)


# ==============================================================================
# 7. ROTAS DE GRAVAÇÃO E REDIRECIONAMENTO
# ==============================================================================
@csrf_exempt
def save_theme_custom_view(request: HttpRequest) -> HttpResponseRedirect:
    """
    Recebe os dados do formulário do Estúdio e persiste conforme o escopo (Global ou Sessão).
    """
    if request.method == "POST":
        scope = request.POST.get("scope", "global")
        config_data = {
            "theme_preset": "custom",
            "primary_hex": request.POST.get("primary_hex", "#EA1D2C"),
            "primary_contrast": request.POST.get("primary_contrast", "#FFFFFF"),
            "font_color_heading": request.POST.get("font_color_heading", "#111827"),
            "font_color_default": request.POST.get("font_color_default", "#1F2937"),
            "font_color_subtle": request.POST.get("font_color_subtle", "#6B7280"),
            "background_body": request.POST.get("background_body", "#F9FAFB"),
            "background_sidebar": request.POST.get("background_sidebar", "#FFFFFF"),
            "background_cards": request.POST.get("background_cards", "#FFFFFF"),
            "icons_color": request.POST.get("icons_color", "#EA1D2C"),
            "border_radius": request.POST.get("border_radius", "0.75rem"),
        }

        # 1. Se for global, grava na BD
        if scope == "global":
            save_full_theme_config(config_data, global_save=True)
            res = HttpResponseRedirect("/admin/theme/?saved=global")
            # Limpa cookies individuais para herdar o padrão global
            res.delete_cookie("django_admin_theme_config", path="/")
            res.delete_cookie("django_admin_color", path="/")
            res.delete_cookie("django_admin_theme", path="/")
            return res
        else:
            # 2. Se for sessão, grava em cookie
            res = HttpResponseRedirect("/admin/theme/?saved=session")
            res.set_cookie(
                "django_admin_theme_config",
                json.dumps(config_data),
                max_age=365 * 24 * 3600,
                path="/",
            )
            return res

    return HttpResponseRedirect("/admin/theme/")


@csrf_exempt
def set_theme_redirect_view(request: HttpRequest, theme_name: str) -> HttpResponseRedirect:
    """
    Ativa um dos presets rápidos com 1 clique.
    """
    val = theme_name.strip().lower()
    set_admin_theme(val)

    next_url = request.GET.get("next") or request.META.get("HTTP_REFERER") or "/admin/theme/"
    response = HttpResponseRedirect(next_url)

    # Limpa cookies individuais para assumir o preset oficial
    response.delete_cookie("django_admin_theme_config", path="/")
    response.delete_cookie("django_admin_color", path="/")
    response.set_cookie("django_admin_theme", val, max_age=365 * 24 * 3600, path="/")

    return response
