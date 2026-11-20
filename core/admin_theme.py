"""
Módulo de Gestão e Manipulação Dinâmica de Cores Visuais do Django Admin (Unfold / Tailwind).
Permite alterar as cores primárias, secundárias e paletas de badges em tempo real via:
1. Parâmetro na URL (?admin_theme=blue ou ?admin_color=#10B981)
2. Cookie de sessão do operador (personalização individual)
3. Parâmetro configurado na Base de Dados (support.Parametro: 'ADMIN_THEME_COLOR')
4. Variável de ambiente (.env: DJANGO_ADMIN_THEME ou DJANGO_ADMIN_PRIMARY_COLOR)
5. Padrão institucional Ango_Ifood (#EA1D2C)
"""
from __future__ import annotations

import os
from typing import Any, Dict, Optional, Tuple


# ==============================================================================
# 1. TEMAS PRÉ-DEFINIDOS (PRESETS)
# ==============================================================================
THEME_PRESETS: Dict[str, Dict[str, str]] = {
    # 🔴 Padrão Oficial Ango_Ifood / iFood
    "red": {
        "name": "Ango_Ifood Vermelho Oficial",
        "hex": "#EA1D2C",
        "50": "254 244 244",
        "100": "253 232 234",
        "200": "250 198 202",
        "300": "247 165 171",
        "400": "240 97 107",
        "500": "234 29 44",
        "600": "199 25 37",
        "700": "164 20 31",
        "800": "129 16 24",
        "900": "94 12 18",
        "950": "58 7 11",
    },
    # 🟢 Verde Esmeralda / Logística Sustentável
    "emerald": {
        "name": "Esmeralda Logística",
        "hex": "#10B981",
        "50": "236 253 245",
        "100": "209 250 229",
        "200": "167 243 208",
        "300": "110 231 183",
        "400": "52 211 153",
        "500": "16 185 129",
        "600": "5 150 105",
        "700": "4 120 87",
        "800": "6 95 70",
        "900": "6 78 59",
        "950": "2 44 34",
    },
    # 🔵 Azul Real / Corporativo
    "blue": {
        "name": "Azul Corporativo",
        "hex": "#2563EB",
        "50": "239 246 255",
        "100": "219 234 254",
        "200": "191 219 254",
        "300": "147 197 253",
        "400": "96 165 250",
        "500": "37 99 235",
        "600": "29 78 216",
        "700": "29 64 175",
        "800": "30 58 138",
        "900": "30 45 106",
        "950": "23 37 84",
    },
    # 🟣 Roxo Tech / VIP
    "purple": {
        "name": "Roxo Tech",
        "hex": "#7C3AED",
        "50": "245 243 255",
        "100": "237 233 254",
        "200": "221 214 254",
        "300": "196 181 253",
        "400": "167 139 250",
        "500": "124 58 237",
        "600": "109 40 217",
        "700": "91 33 182",
        "800": "76 29 149",
        "900": "67 25 123",
        "950": "46 16 101",
    },
    # 🟠 Âmbar / Fast Food & Promoções
    "amber": {
        "name": "Âmbar Restaurante",
        "hex": "#F59E0B",
        "50": "255 251 235",
        "100": "254 243 199",
        "200": "253 230 138",
        "300": "252 211 77",
        "400": "251 191 36",
        "500": "245 158 11",
        "600": "217 119 6",
        "700": "180 83 9",
        "800": "146 64 14",
        "900": "120 53 15",
        "950": "69 26 3",
    },
    # ⚪ Slate / Minimalista Escuro
    "slate": {
        "name": "Slate Minimalista",
        "hex": "#475569",
        "50": "248 250 252",
        "100": "241 245 249",
        "200": "226 232 240",
        "300": "203 213 225",
        "400": "148 163 184",
        "500": "71 85 105",
        "600": "51 65 85",
        "700": "30 41 59",
        "800": "15 23 42",
        "900": "10 15 30",
        "950": "2 6 23",
    },
}


# ==============================================================================
# 2. FUNÇÕES DE CONVERSÃO MATEMÁTICA DE CORES (HEX -> RGB -> TAILWIND)
# ==============================================================================
def hex_to_rgb(hex_code: str) -> Tuple[int, int, int]:
    """Converte código hexadecimal (#RRGGBB ou #RGB) em tupla RGB (r, g, b)."""
    hex_code = hex_code.strip().lstrip("#")
    if len(hex_code) == 3:
        hex_code = "".join(c * 2 for c in hex_code)
    if len(hex_code) != 6:
        # Fallback de segurança para o vermelho padrão
        return (234, 29, 44)
    try:
        return tuple(int(hex_code[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore
    except ValueError:
        return (234, 29, 44)


def _blend_rgb(c1: Tuple[int, int, int], c2: Tuple[int, int, int], factor: float) -> Tuple[int, int, int]:
    """Massa de interpolação linear entre duas cores RGB."""
    return tuple(int(round(a + (b - a) * factor)) for a, b in zip(c1, c2))  # type: ignore


def generate_tailwind_palette(base_hex: str) -> Dict[str, str]:
    """
    Gera automaticamente as 11 tonalidades do Tailwind CSS (50 a 950)
    a partir de QUALQUER cor hexadecimal fornecida pelo utilizador.
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


# ==============================================================================
# 3. RESOLUÇÃO DINÂMICA DE CORES DO ADMIN (CALLBACK UNFOLD)
# ==============================================================================
def get_admin_colors(request: Optional[Any] = None) -> Dict[str, Dict[str, str]]:
    """
    Resolve dinamicamente a paleta de cores primária e secundária do Django Admin.
    Permite manipular a cor em tempo real por URL, Cookie, BD ou .env.
    """
    theme_choice: Optional[str] = None
    custom_hex: Optional[str] = None

    # 1. Consulta parâmetros na URL da requisição (ex.: ?admin_theme=emerald ou ?admin_color=%2310B981)
    if request and hasattr(request, "GET"):
        theme_choice = request.GET.get("admin_theme")
        custom_hex = request.GET.get("admin_color")

    # 2. Consulta cookie de personalização visual do utilizador
    if not theme_choice and not custom_hex and request and hasattr(request, "COOKIES"):
        theme_choice = request.COOKIES.get("django_admin_theme")
        custom_hex = request.COOKIES.get("django_admin_color")

    # 3. Consulta parâmetro global ativo na Base de Dados (se acessível)
    if not theme_choice and not custom_hex:
        try:
            from apps.support.models import Parametro
            param = Parametro.objects.filter(chave="ADMIN_THEME_COLOR").first()
            if param and param.valor:
                val = str(param.valor).strip()
                if val.startswith("#"):
                    custom_hex = val
                elif val.lower() in THEME_PRESETS:
                    theme_choice = val.lower()
        except Exception:
            pass

    # 4. Consulta variável de ambiente (.env)
    if not theme_choice and not custom_hex:
        env_color = os.environ.get("DJANGO_ADMIN_PRIMARY_COLOR") or os.environ.get("ADMIN_THEME_COLOR")
        env_theme = os.environ.get("DJANGO_ADMIN_THEME")
        if env_color and env_color.startswith("#"):
            custom_hex = env_color
        elif env_theme and env_theme.lower() in THEME_PRESETS:
            theme_choice = env_theme.lower()

    # 5. Constrói a paleta primária
    if custom_hex:
        primary_palette = generate_tailwind_palette(custom_hex)
    elif theme_choice and theme_choice.lower() in THEME_PRESETS:
        preset = THEME_PRESETS[theme_choice.lower()]
        primary_palette = {k: v for k, v in preset.items() if k not in ("name", "hex")}
    else:
        # Padrão: Vermelho Ango_Ifood
        preset = THEME_PRESETS["red"]
        primary_palette = {k: v for k, v in preset.items() if k not in ("name", "hex")}

    return {
        "primary": primary_palette,
    }


# ==============================================================================
# 4. FUNÇÃO DE CONFIGURAÇÃO PROGRAMÁTICA DO TEMA
# ==============================================================================
def set_admin_theme(theme_name_or_hex: str) -> bool:
    """
    Grava ou atualiza o tema visual do Django Admin no banco de dados
    através da tabela apps.support.models.Parametro.
    
    Exemplos:
        set_admin_theme("emerald")
        set_admin_theme("blue")
        set_admin_theme("#FF5722")
    """
    val = theme_name_or_hex.strip()
    if not val.startswith("#") and val.lower() not in THEME_PRESETS:
        raise ValueError(f"Tema inválido '{theme_name_or_hex}'. Escolha um de {list(THEME_PRESETS.keys())} ou um código hexadecimal.")

    try:
        from apps.support.models import Parametro
        param, _ = Parametro.objects.get_or_update_or_create(
            chave="ADMIN_THEME_COLOR",
            defaults={
                "nome": "Cor Visual Primária do Django Admin",
                "valor": val,
                "unidade": "HEX / Nome do Tema",
                "ambito": "SISTEMA",
            },
        )
        return True
    except Exception:
        # Se get_or_update_or_create não estiver definido, usa padrão Django
        from apps.support.models import Parametro
        Parametro.objects.update_or_create(
            chave="ADMIN_THEME_COLOR",
            defaults={
                "nome": "Cor Visual Primária do Django Admin",
                "valor": val,
                "unidade": "HEX / Nome do Tema",
                "ambito": "SISTEMA",
            },
        )
        return True


def list_available_themes() -> list[dict[str, str]]:
    """Lista todos os temas visuais prontos para uso com nome, código hexadecimal e pré-visualização."""
    return [
        {"id": key, "name": data["name"], "hex": data["hex"]}
        for key, data in THEME_PRESETS.items()
    ]
