"""
Módulo de Vistas para Gestão de Atualizações Remotas (OTA / Kill Switch).
Disponibiliza:
1. Página Web de Download para iOS (GET /download/ios/): Interface Safari responsiva para instalação de pacotes .ipa.
2. Endpoint Público da API (GET /api/app/check-update/): Verificação em runtime de novas versões e Kill Switch.
"""
from __future__ import annotations

import logging
from typing import Optional

from django.http import HttpRequest, HttpResponse, JsonResponse
from django.shortcuts import render
from django.views.decorators.http import require_GET

from core.models import AppVersion

logger = logging.getLogger(__name__)


@require_GET
def ios_download_page_view(request: HttpRequest) -> HttpResponse:
    """
    Página web oficial e responsiva de download da aplicação para iOS (GET /download/ios/).
    Obtém a versão iOS ativa mais recente, exibe notas de atualização e apresenta
    um botão destacado para descarregar o ficheiro .ipa ou redirecionar para a URL da página web.
    """
    latest_ios: Optional[AppVersion] = (
        AppVersion.objects.filter(
            plataforma=AppVersion.Plataforma.IOS,
            ativa=True,
        )
        .order_by("-versao_codigo", "-criado_em")
        .first()
    )

    download_url: str = ""
    if latest_ios:
        if latest_ios.ficheiro_instalacao:
            download_url = request.build_absolute_uri(latest_ios.ficheiro_instalacao.url)
        elif latest_ios.url_pagina_web:
            download_url = latest_ios.url_pagina_web

    context = {
        "versao": latest_ios,
        "download_url": download_url,
    }

    return render(request, "ota/ios_download.html", context)


@require_GET
def check_app_update_api_view(request: HttpRequest) -> JsonResponse:
    """
    Endpoint público da API para verificação remota de atualizações móveis (GET /api/app/check-update/).
    Recebe os parâmetros via QueryString:
    - ?plataforma=ANDROID|IOS
    - ?versao_atual=1 (número inteiro da build do aplicativo local)

    Lógica de negócio e Kill Switch:
    1. Procura a versão ativa mais recente para a plataforma.
    2. Determina se existe atualização (versao_recente.versao_codigo > versao_atual).
    3. Verifica se existe QUALQUER versão superior à atual com 'obrigatoria=True' (Kill Switch para saltos de versão).
    4. Constrói 'action_url' conforme a plataforma:
       - ANDROID: Link direto absoluto para download in-app do ficheiro .apk.
       - IOS: Link absoluto da página web de download (/download/ios/ ou url_pagina_web) para abrir no Safari.
    """
    # 1. Validação do parâmetro 'plataforma'
    plat_raw = request.GET.get("plataforma", "").strip().upper()
    if plat_raw not in (AppVersion.Plataforma.ANDROID, AppVersion.Plataforma.IOS):
        return JsonResponse(
            {
                "erro": "Parâmetro 'plataforma' inválido ou ausente. Valores aceites: 'ANDROID' ou 'IOS'.",
            },
            status=400,
        )

    # 2. Validação do parâmetro 'versao_atual'
    versao_atual_raw = request.GET.get("versao_atual")
    if versao_atual_raw is None or not str(versao_atual_raw).strip():
        return JsonResponse(
            {
                "erro": "Parâmetro 'versao_atual' (número inteiro do build) é obrigatório.",
            },
            status=400,
        )

    try:
        versao_atual = int(str(versao_atual_raw).strip())
        if versao_atual < 0:
            raise ValueError()
    except ValueError:
        return JsonResponse(
            {
                "erro": "O parâmetro 'versao_atual' deve ser um número inteiro positivo.",
            },
            status=400,
        )

    # 3. Consulta da versão ativa mais recente para a plataforma
    versao_mais_recente: Optional[AppVersion] = (
        AppVersion.objects.filter(
            plataforma=plat_raw,
            ativa=True,
        )
        .order_by("-versao_codigo", "-criado_em")
        .first()
    )

    # Se não houver versão publicada ativa no banco
    if not versao_mais_recente:
        return JsonResponse(
            {
                "atualizacao_disponivel": False,
                "forcar_atualizacao": False,
                "versao_nome": "",
                "versao_codigo": versao_atual,
                "action_url": "",
                "notas_atualizacao": "A aplicação está atualizada. Nenhuma versão mais recente disponível.",
            },
            status=200,
        )

    # 4. Verificação de disponibilidade de atualização
    atualizacao_disponivel = versao_mais_recente.versao_codigo > versao_atual

    # 5. Verificação do modo Kill Switch (obrigatoriedade)
    # Se o utilizador estiver em versão inferior e qualquer versão intermediária ou a final foi marcada como obrigatória
    forcar_atualizacao = False
    if atualizacao_disponivel:
        forcar_atualizacao = AppVersion.objects.filter(
            plataforma=plat_raw,
            ativa=True,
            obrigatoria=True,
            versao_codigo__gt=versao_atual,
        ).exists()

    # 6. Determinação da 'action_url' conforme a regra de plataforma
    action_url = ""
    if plat_raw == AppVersion.Plataforma.ANDROID:
        # Se Android: retorna o link direto do ficheiro .apk para download in-app
        if versao_mais_recente.ficheiro_instalacao:
            action_url = request.build_absolute_uri(versao_mais_recente.ficheiro_instalacao.url)
        elif versao_mais_recente.url_pagina_web:
            action_url = versao_mais_recente.url_pagina_web
        else:
            action_url = request.build_absolute_uri("/apk/download/")
    elif plat_raw == AppVersion.Plataforma.IOS:
        # Se iOS: retorna a URL absoluta da página web de download para abrir no Safari
        if versao_mais_recente.url_pagina_web:
            action_url = versao_mais_recente.url_pagina_web
        else:
            action_url = request.build_absolute_uri("/download/ios/")

    resposta = {
        "atualizacao_disponivel": atualizacao_disponivel,
        "forcar_atualizacao": forcar_atualizacao,
        "versao_nome": versao_mais_recente.versao_nome,
        "versao_codigo": versao_mais_recente.versao_codigo,
        "action_url": action_url,
        "notas_atualizacao": versao_mais_recente.notas_atualizacao,
    }

    logger.info(
        f"[OTA CHECK] Plataforma={plat_raw} | VersaoAtual={versao_atual} | "
        f"MaisRecente={versao_mais_recente.versao_codigo} | "
        f"Disponivel={atualizacao_disponivel} | KillSwitch={forcar_atualizacao}"
    )

    return JsonResponse(resposta, status=200)

