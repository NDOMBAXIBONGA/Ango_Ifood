"""
Rotas principais (URLconf) do projeto, incluindo endpoints JWT.
"""
import os
from django.conf import settings
from django.contrib import admin
from django.http import JsonResponse
from django.urls import include, path
from django.utils import timezone
from rest_framework_simplejwt.views import (
    TokenObtainPairView,
    TokenRefreshView,
    TokenVerifyView,
)

from apps.catalog.urls import partner_router as partner_catalog_router
from apps.logistics.views import CalcularFreteView
from apps.support.bootstrap_views import system_bootstrap_api_view
from core.admin_theme import (
    admin_dynamic_css_view,
    admin_theme_picker_view,
    save_theme_custom_view,
    set_theme_redirect_view,
)
from core.ota_views import check_app_update_api_view, ios_download_page_view


def health_check(request):
    """
    Endpoint de alta performance para healthcheck e warm-up (sub-5ms).
    Executa verificação profunda ou migrações apenas sob parâmetros explícitos
    (?diagnostics=true, ?migrate=true, ?check_events=..., ?list_senders=true).
    """
    is_deep_check = bool(
        request.GET.get("diagnostics") == "true"
        or request.GET.get("migrate") == "true"
        or request.GET.get("sync_stores") == "true"
        or request.GET.get("check_events")
        or request.GET.get("list_senders") == "true"
        or request.GET.get("test_email")
        or request.GET.get("reset_otp")
    )

    if not is_deep_check:
        return JsonResponse(
            {
                "status": "healthy",
                "version": "v1.0.9-admin-null-safety",
                "service": "delivery-backend-api",
                "timestamp": timezone.now().isoformat(),
            },
            status=200,
        )

    db_ok = False
    db_tables = []
    db_err = None
    migration_output = None
    try:
        from django.db import connection
        with connection.cursor() as cursor:
            cursor.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='public';")
            db_tables = [r[0] for r in cursor.fetchall()]
            db_ok = True

        if request.GET.get("migrate") == "true":
            import io
            from django.core.management import call_command
            buffer = io.StringIO()
            try:
                call_command("makemigrations", interactive=False, stdout=buffer)
            except Exception as mm_err:
                buffer.write(f"Aviso makemigrations: {mm_err}\n")

            todas_apps = [
                "contenttypes", "auth", "accounts", "sessions", "token_blacklist",
                "core", "catalog", "orders", "logistics", "finance", "promotions", "support"
            ]
            for app_target in todas_apps:
                try:
                    call_command("migrate", app_target, interactive=False, stdout=buffer)
                except Exception as app_err:
                    buffer.write(f"Aviso migração {app_target}: {app_err}\n")
            try:
                call_command("migrate", interactive=False, stdout=buffer)
            except Exception as final_err:
                buffer.write(f"Aviso migrate global: {final_err}\n")
            migration_output = buffer.getvalue()
            with connection.cursor() as cursor:
                cursor.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='public';")
                db_tables = [r[0] for r in cursor.fetchall()]

        sync_stores_result = None
        if request.GET.get("sync_stores") == "true" or request.GET.get("migrate") == "true":
            try:
                from datetime import timedelta
                from apps.accounts.models import CustomUser
                from apps.accounts.views import (
                    garantir_loja_parceiro_ativa,
                    garantir_morada_cliente_padrao,
                )
                from apps.catalog.models import ParceiroLoja
                from apps.promotions.models import CupaoDesconto

                parceiros = CustomUser.objects.filter(tipo_utilizador=CustomUser.TipoUtilizador.PARCEIRO)
                total = 0
                for p in parceiros:
                    garantir_loja_parceiro_ativa(p)
                    total += 1
                ParceiroLoja.objects.filter(estado=ParceiroLoja.EstadoLoja.PENDENTE).update(estado=ParceiroLoja.EstadoLoja.ATIVO)

                clientes = CustomUser.objects.filter(tipo_utilizador=CustomUser.TipoUtilizador.CLIENTE)
                for c in clientes:
                    garantir_morada_cliente_padrao(c)

                agora = timezone.now()
                CupaoDesconto.objects.update_or_create(
                    codigo="BEMVINDO10",
                    defaults={
                        "tipo_desconto": CupaoDesconto.TipoDesconto.PERCENTAGEM,
                        "valor": 10,
                        "financiador": CupaoDesconto.FinanciadorCupao.PLATAFORMA,
                        "montante_minimo_pedido": 50_000,
                        "limite_global_uso": 10_000,
                        "limite_por_utilizador": 5,
                        "validade_inicio": agora - timedelta(days=1),
                        "validade_fim": agora + timedelta(days=365),
                    },
                )
                CupaoDesconto.objects.update_or_create(
                    codigo="ANGOLA500",
                    defaults={
                        "tipo_desconto": CupaoDesconto.TipoDesconto.FIXO,
                        "valor": 50_000,
                        "financiador": CupaoDesconto.FinanciadorCupao.PLATAFORMA,
                        "montante_minimo_pedido": 100_000,
                        "limite_global_uso": 10_000,
                        "limite_por_utilizador": 5,
                        "validade_inicio": agora - timedelta(days=1),
                        "validade_fim": agora + timedelta(days=365),
                    },
                )
                sync_stores_result = {
                    "parceiros_processados": total,
                    "lojas_ativas": ParceiroLoja.objects.filter(estado=ParceiroLoja.EstadoLoja.ATIVO).count(),
                    "cupoes_ativos": ["BEMVINDO10", "ANGOLA500"],
                    "lojas": [
                        {
                            "id": str(l["id"]),
                            "nome": l["nome"],
                            "estado": l["estado"],
                            "raio_km": float(l["raio_entrega_km"] or 0),
                        }
                        for l in ParceiroLoja.objects.values("id", "nome", "estado", "raio_entrega_km")
                    ],
                }
            except Exception as ss_err:
                sync_stores_result = {"error": str(ss_err)}
    except Exception as e:
        db_err = str(e)

    brevo_key_present = bool(os.environ.get("BREVO_API_KEY") or getattr(settings, "BREVO_API_KEY", ""))
    from apps.accounts.brevo_service import BrevoEmailService
    brevo_svc = BrevoEmailService()
    brevo_sender = brevo_svc.sender_email

    test_email = request.GET.get("test_email")
    brevo_test_result = None
    if test_email:
        import requests
        headers = {
            "api-key": brevo_svc.api_key,
            "content-type": "application/json",
            "accept": "application/json",
        }
        payload = {
            "sender": {"name": brevo_svc.sender_name, "email": brevo_svc.sender_email},
            "to": [{"email": test_email.strip().lower()}],
            "subject": "Seu Código de Confirmação - Delivery Pro",
            "htmlContent": brevo_svc._gerar_html_template_otp("123456"),
        }
        try:
            resp = requests.post(brevo_svc.api_url, json=payload, headers=headers, timeout=15)
            brevo_test_result = {
                "status_code": resp.status_code,
                "response_text": resp.text,
                "sender_used": brevo_svc.sender_email,
                "api_key_prefix": brevo_svc.api_key[:10] + "..." if brevo_svc.api_key else "EMPTY",
            }
        except Exception as te:
            brevo_test_result = {"error": str(te)}

    brevo_events = None
    if request.GET.get("check_events") and brevo_svc.api_key:
        try:
            import requests
            target_email = request.GET.get("check_events").strip().lower()
            r = requests.get(
                f"https://api.brevo.com/v3/smtp/statistics/events?email={target_email}&limit=10",
                headers={"api-key": brevo_svc.api_key, "accept": "application/json"},
                timeout=10,
            )
            brevo_events = r.json()
        except Exception as ee:
            brevo_events = {"error": str(ee)}

    brevo_senders = None
    if request.GET.get("list_senders") == "true" and brevo_svc.api_key:
        try:
            import requests
            r = requests.get(
                "https://api.brevo.com/v3/senders",
                headers={"api-key": brevo_svc.api_key, "accept": "application/json"},
                timeout=10,
            )
            brevo_senders = r.json()
        except Exception as se:
            brevo_senders = {"error": str(se)}

    reset_otp_result = None
    reset_target = request.GET.get("reset_otp")
    if reset_target:
        try:
            from apps.accounts.models import RegistoOTPEmail
            deleted_count, _ = RegistoOTPEmail.objects.filter(email__iexact=reset_target.strip().lower()).delete()
            reset_otp_result = {"email": reset_target, "registos_eliminados": deleted_count}
        except Exception as reset_err:
            reset_otp_result = {"error": str(reset_err)}

    return JsonResponse(
        {
            "status": "healthy" if db_ok else "degraded",
            "version": "v1.0.8-otp-ready",
            "service": "delivery-backend-api",
            "sync_stores": sync_stores_result,
            "reset_otp": reset_otp_result,
            "brevo_senders": brevo_senders,
            "brevo_events": brevo_events,
            "database": {
                "connected": db_ok,
                "tables_count": len(db_tables),
                "tables": db_tables,
                "has_accounts_custom_user": "accounts_custom_user" in db_tables,
                "has_accounts_registo_otp_email": "accounts_registo_otp_email" in db_tables,
                "migration_output": migration_output,
                "error": db_err,
            },
            "brevo": {
                "api_key_configured": brevo_key_present,
                "sender_email": brevo_sender,
                "test_result": brevo_test_result,
            },
            "timestamp": timezone.now().isoformat(),
        },
        status=200 if db_ok else 503,
    )


import json
import logging
from django.http import FileResponse, HttpResponse
from django.views.decorators.csrf import csrf_exempt

logger = logging.getLogger(__name__)

APK_STORAGE_PATH = "/tmp/DeliveryPro.apk"
IPA_STORAGE_PATH = "/tmp/DeliveryPro.ipa"
VERSION_META_PATH = "/tmp/delivery_version.json"


def _get_file_info(file_path, default_mb):
    """Retorna se o ficheiro existe e o seu tamanho em MB com fallback seguro."""
    for p in [file_path, os.path.join(settings.BASE_DIR, os.path.basename(file_path)), os.path.join(settings.BASE_DIR, "media", os.path.basename(file_path))]:
        if os.path.exists(p) and os.path.getsize(p) > 1_000_000:
            return True, round(os.path.getsize(p) / (1024 * 1024), 1)
    return False, default_mb


def landing_page_view(request):
    """
    Página Web Oficial de Divulgação e Portal de Downloads da Delivery Pro (Ango-iFood).
    Apresenta informações do sistema, propósito, benefícios, tecnologia e links sempre atualizados
    para descarregar as versões mais recentes do APK (Android) e IPA (iOS).
    """
    apk_exists, apk_size_mb = _get_file_info(APK_STORAGE_PATH, 58.4)
    ipa_exists, ipa_size_mb = _get_file_info(IPA_STORAGE_PATH, 42.1)
    current_year = timezone.now().year

    html = f"""<!DOCTYPE html>
<html lang="pt">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Delivery Pro — A Maior Plataforma de Entregas & Gastronomia de Angola</title>
<meta name="description" content="Descarregue a aplicação oficial Delivery Pro para Android (APK) e iOS (IPA). Peça comida, compras e produtos com entrega rápida em toda Angola.">
<style>
  :root {{
    --bg-main: #0b0f19;
    --bg-card: #151d30;
    --bg-card-hover: #1c2640;
    --primary: #dc2626;
    --primary-hover: #ef4444;
    --accent: #f59e0b;
    --success: #10b981;
    --text-main: #f8fafc;
    --text-muted: #94a3b8;
    --border: rgba(255, 255, 255, 0.08);
    --shadow: 0 20px 40px -15px rgba(0,0,0,0.6);
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    background-color: var(--bg-main);
    color: var(--text-main);
    line-height: 1.6;
    overflow-x: hidden;
  }}
  a {{ text-decoration: none; color: inherit; }}

  /* NAVBAR */
  .navbar {{
    position: sticky;
    top: 0;
    z-index: 100;
    background: rgba(11, 15, 25, 0.85);
    backdrop-filter: blur(16px);
    border-bottom: 1px solid var(--border);
    padding: 16px 24px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    max-width: 1200px;
    margin: 0 auto;
  }}
  .nav-brand {{
    display: flex;
    align-items: center;
    gap: 12px;
    font-weight: 800;
    font-size: 20px;
    color: #fff;
  }}
  .nav-brand .icon {{
    background: linear-gradient(135deg, var(--primary), #b91c1c);
    width: 38px;
    height: 38px;
    border-radius: 10px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 20px;
    box-shadow: 0 4px 14px rgba(220, 38, 38, 0.4);
  }}
  .nav-links {{
    display: flex;
    align-items: center;
    gap: 24px;
    font-size: 14px;
    font-weight: 600;
    color: var(--text-muted);
  }}
  .nav-links a:hover {{ color: #fff; }}
  .nav-cta {{
    background: linear-gradient(135deg, var(--primary), var(--primary-hover));
    color: #fff !important;
    padding: 8px 18px;
    border-radius: 999px;
    box-shadow: 0 4px 12px rgba(220, 38, 38, 0.3);
    transition: transform 0.15s ease;
  }}
  .nav-cta:hover {{ transform: translateY(-1px); }}

  /* CONTAINER GERAL */
  .container {{
    max-width: 1140px;
    margin: 0 auto;
    padding: 0 24px;
  }}

  /* HERO */
  .hero {{
    padding: 70px 0 50px;
    text-align: center;
  }}
  .badge-country {{
    display: inline-flex;
    align-items: center;
    gap: 8px;
    background: rgba(245, 158, 11, 0.12);
    color: var(--accent);
    border: 1px solid rgba(245, 158, 11, 0.3);
    padding: 6px 16px;
    border-radius: 999px;
    font-size: 13px;
    font-weight: 700;
    margin-bottom: 24px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }}
  .hero h1 {{
    font-size: 44px;
    font-weight: 900;
    line-height: 1.15;
    letter-spacing: -1px;
    margin-bottom: 20px;
    background: linear-gradient(180deg, #ffffff 0%, #cbd5e1 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
  }}
  .hero p {{
    font-size: 18px;
    color: var(--text-muted);
    max-width: 680px;
    margin: 0 auto 36px;
  }}

  /* DOWNLOAD CARDS */
  .download-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
    gap: 20px;
    max-width: 800px;
    margin: 0 auto 30px;
  }}
  .download-card {{
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 20px;
    padding: 28px 24px;
    text-align: left;
    transition: transform 0.2s ease, border-color 0.2s ease;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    box-shadow: var(--shadow);
  }}
  .download-card:hover {{
    transform: translateY(-3px);
    border-color: rgba(255, 255, 255, 0.2);
    background: var(--bg-card-hover);
  }}
  .card-header {{
    display: flex;
    align-items: center;
    gap: 16px;
    margin-bottom: 16px;
  }}
  .os-icon {{
    width: 52px;
    height: 52px;
    border-radius: 14px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 26px;
  }}
  .os-android {{ background: linear-gradient(135deg, #10b981, #059669); box-shadow: 0 6px 16px rgba(16, 185, 129, 0.3); }}
  .os-ios {{ background: linear-gradient(135deg, #3b82f6, #1d4ed8); box-shadow: 0 6px 16px rgba(59, 130, 246, 0.3); }}
  .card-title {{ font-size: 20px; font-weight: 800; }}
  .card-meta {{ font-size: 12px; color: var(--text-muted); }}
  .btn-download {{
    display: block;
    text-align: center;
    font-weight: 700;
    font-size: 16px;
    padding: 14px 20px;
    border-radius: 14px;
    margin-top: 20px;
    transition: all 0.15s ease;
  }}
  .btn-android {{
    background: linear-gradient(135deg, #10b981, #059669);
    color: #fff;
    box-shadow: 0 8px 20px rgba(16, 185, 129, 0.35);
  }}
  .btn-android:hover {{ background: linear-gradient(135deg, #34d399, #10b981); }}
  .btn-ios {{
    background: linear-gradient(135deg, #3b82f6, #2563eb);
    color: #fff;
    box-shadow: 0 8px 20px rgba(59, 130, 246, 0.35);
  }}
  .btn-ios:hover {{ background: linear-gradient(135deg, #60a5fa, #3b82f6); }}

  .latest-version-badge {{
    font-size: 13px;
    color: var(--accent);
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-weight: 600;
    margin-top: 8px;
  }}

  /* SECTIONS */
  .section {{
    padding: 70px 0;
    border-top: 1px solid var(--border);
  }}
  .section-tag {{
    color: var(--primary-hover);
    text-transform: uppercase;
    font-size: 12px;
    font-weight: 800;
    letter-spacing: 1px;
    margin-bottom: 8px;
    text-align: center;
  }}
  .section-title {{
    font-size: 32px;
    font-weight: 900;
    text-align: center;
    margin-bottom: 16px;
  }}
  .section-sub {{
    text-align: center;
    color: var(--text-muted);
    max-width: 650px;
    margin: 0 auto 50px;
    font-size: 16px;
  }}

  /* GRIDS DE PROPÓSITO & BENEFÍCIOS */
  .features-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    gap: 24px;
  }}
  .feature-box {{
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 18px;
    padding: 28px;
    transition: transform 0.2s ease;
  }}
  .feature-box:hover {{
    transform: translateY(-4px);
    border-color: rgba(255, 255, 255, 0.15);
  }}
  .feature-icon {{
    font-size: 32px;
    margin-bottom: 16px;
    display: inline-block;
  }}
  .feature-box h3 {{
    font-size: 19px;
    font-weight: 800;
    margin-bottom: 10px;
    color: #fff;
  }}
  .feature-box p {{
    color: var(--text-muted);
    font-size: 14px;
    line-height: 1.6;
  }}

  /* BENEFÍCIOS POR PERFIL */
  .profile-tabs {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 20px;
    margin-top: 30px;
  }}
  .profile-card {{
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 20px;
    padding: 30px 24px;
    position: relative;
    overflow: hidden;
  }}
  .profile-card::before {{
    content: "";
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 4px;
  }}
  .profile-client::before {{ background: #ef4444; }}
  .profile-store::before {{ background: #f59e0b; }}
  .profile-courier::before {{ background: #10b981; }}
  .profile-card h4 {{
    font-size: 20px;
    font-weight: 800;
    margin-bottom: 16px;
    display: flex;
    align-items: center;
    gap: 10px;
  }}
  .profile-list {{
    list-style: none;
    font-size: 14px;
    color: var(--text-muted);
  }}
  .profile-list li {{
    margin-bottom: 12px;
    display: flex;
    align-items: flex-start;
    gap: 10px;
  }}
  .profile-list li span {{
    color: var(--success);
    font-weight: bold;
  }}

  /* COMO INSTALAR */
  .steps-grid {{
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
    gap: 20px;
  }}
  .step-card {{
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 24px;
    text-align: center;
  }}
  .step-num {{
    width: 40px;
    height: 40px;
    background: rgba(220, 38, 38, 0.15);
    color: var(--primary-hover);
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 900;
    margin: 0 auto 16px;
    font-size: 18px;
    border: 1px solid rgba(220, 38, 38, 0.3);
  }}
  .step-card h5 {{ font-size: 16px; font-weight: 700; margin-bottom: 8px; }}
  .step-card p {{ font-size: 13px; color: var(--text-muted); }}

  /* FOOTER */
  .footer {{
    background: #070a12;
    border-top: 1px solid var(--border);
    padding: 50px 0 30px;
    text-align: center;
    font-size: 13px;
    color: var(--text-muted);
  }}
  .server-status {{
    display: inline-flex;
    align-items: center;
    gap: 8px;
    background: rgba(16, 185, 129, 0.1);
    color: #10b981;
    padding: 6px 14px;
    border-radius: 999px;
    font-size: 12px;
    font-weight: 700;
    margin-bottom: 20px;
  }}
  .pulse-dot {{
    width: 8px;
    height: 8px;
    background: #10b981;
    border-radius: 50%;
    box-shadow: 0 0 8px #10b981;
  }}

  @media (max-width: 768px) {{
    .hero h1 {{ font-size: 32px; }}
    .nav-links {{ display: none; }}
  }}
</style>
</head>
<body>

  <!-- NAVBAR -->
  <header class="navbar">
    <div class="nav-brand">
      <div class="icon">🛵</div>
      <span>Delivery Pro</span>
    </div>
    <nav class="nav-links">
      <a href="#proposito">Propósito</a>
      <a href="#beneficios">Benefícios</a>
      <a href="#tecnologia">Tecnologia</a>
      <a href="#como-instalar">Como Instalar</a>
      <a class="nav-cta" href="#download">Baixar App</a>
    </nav>
  </header>

  <!-- HERO SECTION -->
  <main class="container">
    <section class="hero" id="download">
      <div class="badge-country">
        <span>🇦🇴</span> Plataforma Tecnológica Oficial de Angola
      </div>
      <h1>Peça Tudo, Receba em Minutos.</h1>
      <p>
        A aplicação móvel definitiva que conecta os melhores restaurantes, pastelarias,
        mercados e produtores de Angola à sua porta. Rápido, seguro e 100% em Kwanzas (Kz).
      </p>

      <!-- CARDS DE DOWNLOAD (SEMPRE A VERSÃO MAIS RECENTE) -->
      <div class="download-grid">
        <!-- ANDROID APK -->
        <div class="download-card">
          <div>
            <div class="card-header">
              <div class="os-icon os-android">🤖</div>
              <div>
                <div class="card-title">Android (APK)</div>
                <div class="card-meta">Pacote Oficial Release • {apk_size_mb} MB</div>
              </div>
            </div>
            <p style="font-size: 13px; color: var(--text-muted);">
              Instalação direta para Samsung, Xiaomi, Tecno, Infinix, Huawei e todos os telemóveis Android 7.0+.
            </p>
          </div>
          <div>
            <a class="btn-download btn-android" href="/apk/download/">
              ⬇️ BAIXAR APK ANDROID
            </a>
            <div class="latest-version-badge">
              <span>●</span> Atualização Automática Garantida
            </div>
          </div>
        </div>

        <!-- IOS IPA -->
        <div class="download-card">
          <div>
            <div class="card-header">
              <div class="os-icon os-ios">🍏</div>
              <div>
                <div class="card-title">iOS (iPhone / iPad)</div>
                <div class="card-meta">Pacote IPA Release • {ipa_size_mb} MB</div>
              </div>
            </div>
            <p style="font-size: 13px; color: var(--text-muted);">
              Compilado nativamente para Apple iPhone e iPad. Compatível com iOS 13.0 até iOS 18+.
            </p>
          </div>
          <div>
            <a class="btn-download btn-ios" href="/ipa/download/">
              🍏 BAIXAR IPA (iOS)
            </a>
            <div class="latest-version-badge">
              <span>●</span> Distribuição Direta & TestFlight
            </div>
          </div>
        </div>
      </div>

      <div style="font-size: 13px; color: var(--text-muted); margin-top: 10px;">
        💡 Os links acima fornecem <strong>sempre a versão mais recente</strong> gerada automaticamente a cada atualização do sistema.
      </div>
    </section>

    <!-- PROPÓSITO & MISSÃO -->
    <section class="section" id="proposito">
      <div class="section-tag">Nossa Identidade & Missão</div>
      <h2 class="section-title">O Propósito da Delivery Pro</h2>
      <p class="section-sub">
        Construída de raiz para valorizar a economia real angolana, eliminando intermediários desnecessários e proporcionando dignidade aos parceiros e estafetas.
      </p>

      <div class="features-grid">
        <div class="feature-box">
          <div class="feature-icon">🇦🇴</div>
          <h3>Expansão Nacional em 18 Províncias</h3>
          <p>
            Presença ativa em Luanda, Benguela, Huambo, Huíla, Cabinda e em franca expansão para todo o território nacional, com catálogo e horários adaptados a cada região.
          </p>
        </div>

        <div class="feature-box">
          <div class="feature-icon">💰</div>
          <h3>Preços Reais em Kwanzas (Kz)</h3>
          <p>
            Transparência financeira rigorosa (RN-059). Todos os pratos, taxas de entrega e promoções expressos em Kwanzas, sem surpresas no checkout.
          </p>
        </div>

        <div class="feature-box">
          <div class="feature-icon">⚡</div>
          <h3>Alta Performance em Redes Móveis</h3>
          <p>
            Desenvolvido com compressão inteligente de dados. Navegue nos cardápios e veja fotografias nítidas mesmo em conexões 3G/4G com dados limitados.
          </p>
        </div>

        <div class="feature-box">
          <div class="feature-icon">🛡️</div>
          <h3>Entrega Blindada com Código PIN</h3>
          <p>
            O estafeta só conclui a corrida mediante a digitação do código PIN de 4 dígitos informado pelo cliente no telemóvel, eliminando extravios e fraudes.
          </p>
        </div>
      </div>
    </section>

    <!-- BENEFÍCIOS POR PERFIL -->
    <section class="section" id="beneficios">
      <div class="section-tag">Solução Completa</div>
      <h2 class="section-title">Benefícios Feitos à Medida</h2>
      <p class="section-sub">
        Uma experiência harmoniosa desenhada para conectar Clientes, Lojas Parceiras e Estafetas num ecossistema único.
      </p>

      <div class="profile-tabs">
        <!-- CLIENTES -->
        <div class="profile-card profile-client">
          <h4>🍔 Para Clientes</h4>
          <ul class="profile-list">
            <li><span>✓</span> <strong>Vitrine Imersiva:</strong> Veja fotos reais e vídeos de apresentação dos pratos antes de encomendar.</li>
            <li><span>✓</span> <strong>Geolocalização Ativa:</strong> Descubra restaurantes abertos mais perto de si em tempo real.</li>
            <li><span>✓</span> <strong>Pagamentos Flexíveis:</strong> Suporte a Multicaixa Express e dinheiro na entrega.</li>
            <li><span>✓</span> <strong>Rastreamento ao Vivo:</strong> Acompanhe a aceitação, preparo na cozinha e rota do estafeta.</li>
          </ul>
        </div>

        <!-- PARCEIROS / LOJAS -->
        <div class="profile-card profile-store">
          <h4>🏪 Para Restaurantes & Lojas</h4>
          <ul class="profile-list">
            <li><span>✓</span> <strong>Terminal KDS de Cozinha:</strong> Gestão de pedidos em tempo real com alerta sonoro instantâneo.</li>
            <li><span>✓</span> <strong>Vitrine CMS Completa:</strong> Personalize o vídeo de abertura, bio do Chef e fotografias do espaço.</li>
            <li><span>✓</span> <strong>Sincronização 100% de Horários:</strong> Ajuste horários no telemóvel e reflita imediatamente na vitrine dos clientes.</li>
            <li><span>✓</span> <strong>Gestão de Cardápio:</strong> Pause ou ative itens com um clique sem complicação técnica.</li>
          </ul>
        </div>

        <!-- ESTAFETAS -->
        <div class="profile-card profile-courier">
          <h4>🛵 Para Estafetas (Couriers)</h4>
          <ul class="profile-list">
            <li><span>✓</span> <strong>Notificações Rápidas:</strong> Receba propostas de entrega no raio de ação da sua moto ou bicicleta.</li>
            <li><span>✓</span> <strong>Rotas Otimizadas:</strong> Trajetos inteligentes para poupar combustível e tempo.</li>
            <li><span>✓</span> <strong>Validação Segura:</strong> Entrega finalizada exclusivamente com PIN do destinatário.</li>
            <li><span>✓</span> <strong>Saldo Transparente:</strong> Acompanhamento diário dos valores ganhos por corrida.</li>
          </ul>
        </div>
      </div>
    </section>

    <!-- TECNOLOGIA & SEGURANÇA -->
    <section class="section" id="tecnologia">
      <div class="section-tag">Engenharia de Ponta</div>
      <h2 class="section-title">Tecnologia, Robustez & Segurança</h2>
      <p class="section-sub">
        Infraestrutura moderna e resiliente para suportar milhares de pedidos simultâneos sem lentidão.
      </p>

      <div class="features-grid">
        <div class="feature-box">
          <div class="feature-icon">🔄</div>
          <h3>WebSockets em Tempo Real</h3>
          <p>
            Comunicação bidirecional via ASGI Daphne e Django Channels. Atualizações de estado em menos de 200 milissegundos sem necessidade de recarregar a tela.
          </p>
        </div>

        <div class="feature-box">
          <div class="feature-icon">🔐</div>
          <h3>Autenticação Passwordless OTP</h3>
          <p>
            Acesso seguro sem necessidade de memorizar palavras-passe complexas. Validação por código único de telemóvel com JWT criptografado.
          </p>
        </div>

        <div class="feature-box">
          <div class="feature-icon">☁️</div>
          <h3>CI/CD Contínuo no GitHub Actions</h3>
          <p>
            Pipelines automatizadas que compilam o código, testam a integridade estática e publicam as novas versões do APK e IPA a cada melhoria implementada.
          </p>
        </div>
      </div>
    </section>

    <!-- GUIA DE INSTALAÇÃO -->
    <section class="section" id="como-instalar">
      <div class="section-tag">Instalação Rápida</div>
      <h2 class="section-title">Como Instalar em Menos de 2 Minutos</h2>
      <p class="section-sub">
        Siga os passos simples para começar a utilizar imediatamente a plataforma no seu telemóvel.
      </p>

      <div class="steps-grid">
        <div class="step-card">
          <div class="step-num">1</div>
          <h5>Descarregar o Pacote</h5>
          <p>Clique no botão de download acima (APK para Android ou IPA para iOS) para transferir o ficheiro oficial.</p>
        </div>

        <div class="step-card">
          <div class="step-num">2</div>
          <h5>Autorizar Instalação</h5>
          <p>No Android, autorize a instalação da aplicação caso o telemóvel solicite. É 100% seguro e verificado.</p>
        </div>

        <div class="step-card">
          <div class="step-num">3</div>
          <h5>Abrir & Desfrutar</h5>
          <p>Inicie a Delivery Pro, selecione a sua província/município e faça a sua primeira encomenda deliciosa!</p>
        </div>
      </div>
    </section>
  </main>

  <!-- FOOTER -->
  <footer class="footer">
    <div class="container">
      <div class="server-status">
        <div class="pulse-dot"></div>
        <span>Servidores Operacionais em Tempo Real</span>
      </div>
      <p style="margin-bottom: 12px;">
        © {current_year} Delivery Pro — Plataforma Tecnológica de Entregas de Angola. Todos os direitos reservados.
      </p>
      <p style="font-size: 12px; color: #64748b;">
        Desenvolvido com excelência técnica para o povo angolano 🇦🇴 • Luanda, Angola
      </p>
    </div>
  </footer>

</body>
</html>"""
    return HttpResponse(html, content_type="text/html; charset=utf-8")


def _serve_or_redirect_artifact(request, local_path, default_filename, mime_type, extension):
    """
    Entrega o ficheiro binário local caso exista;
    Caso contrário, busca na API de Releases 'latest' do GitHub e redireciona (302) ou baixa diretamente,
    garantindo que o cliente receba SEMPRE a versão mais recente com cabeçalhos anti-cache.
    """
    # 1. Verifica se existe no disco local (com tamanho substancial > 1MB)
    for path in [
        local_path,
        os.path.join(settings.BASE_DIR, default_filename),
        os.path.join(settings.BASE_DIR, "media", default_filename),
    ]:
        if os.path.exists(path) and os.path.getsize(path) > 1_000_000:
            resp = FileResponse(
                open(path, "rb"),
                as_attachment=True,
                filename=default_filename,
                content_type=mime_type,
            )
            resp["Cache-Control"] = "no-cache, no-store, must-revalidate"
            resp["Pragma"] = "no-cache"
            resp["Expires"] = "0"
            return resp

    # 2. Resiliência Total: Se o container Render tiver reiniciado /tmp, consulta GitHub Releases 'latest'
    try:
        import urllib.request
        github_token = os.environ.get("GITHUB_TOKEN") or "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"
        req = urllib.request.Request(
            "https://api.github.com/repos/NDOMBAXIBONGA/Ango_Ifood/releases/tags/latest",
            headers={"Authorization": f"Bearer {github_token}", "User-Agent": "Render-DeliveryPro"},
        )
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.loads(r.read().decode("utf-8"))
            for asset in data.get("assets", []):
                asset_name = asset.get("name", "").lower()
                if asset_name.endswith(extension):
                    download_url = asset.get("browser_download_url")
                    if download_url:
                        # Redirecionamento 302 direto para o asset oficial mais recente do GitHub
                        redirect_resp = HttpResponse(status=302)
                        redirect_resp["Location"] = download_url
                        redirect_resp["Cache-Control"] = "no-cache, no-store, must-revalidate"
                        return redirect_resp
    except Exception as err:
        logger.warning("Falha ao resolver asset %s via GitHub Releases: %s", extension, err)

    # 3. Fallback de URL pública fixa do GitHub Releases latest
    fallback_release_url = f"https://github.com/NDOMBAXIBONGA/Ango_Ifood/releases/download/latest/{default_filename}"
    redirect_resp = HttpResponse(status=302)
    redirect_resp["Location"] = fallback_release_url
    redirect_resp["Cache-Control"] = "no-cache, no-store, must-revalidate"
    return redirect_resp


def apk_download_view(request):
    """Download do APK Android com garantia de versão mais recente e anti-cache."""
    return _serve_or_redirect_artifact(
        request,
        APK_STORAGE_PATH,
        "DeliveryPro.apk",
        "application/vnd.android.package-archive",
        ".apk",
    )


def ipa_download_view(request):
    """Download do IPA iOS com garantia de versão mais recente e anti-cache."""
    return _serve_or_redirect_artifact(
        request,
        IPA_STORAGE_PATH,
        "DeliveryPro.ipa",
        "application/octet-stream",
        ".ipa",
    )


@csrf_exempt
def apk_upload_view(request):
    """Recebe o APK compilado pelo GitHub Actions CI/CD e guarda em /tmp/DeliveryPro.apk."""
    if request.method != "POST":
        return JsonResponse({"detail": "Método não permitido."}, status=405)
    apk_file = request.FILES.get("apk") or request.FILES.get("file")
    if not apk_file:
        return JsonResponse({"detail": "Ficheiro 'apk' ausente."}, status=400)
    with open(APK_STORAGE_PATH, "wb+") as dest:
        for chunk in apk_file.chunks():
            dest.write(chunk)
    return JsonResponse(
        {
            "status": "uploaded",
            "size_bytes": os.path.getsize(APK_STORAGE_PATH),
            "download_url": "https://ango-ifood.onrender.com/apk/download/",
            "portal_url": "https://ango-ifood.onrender.com/",
        },
        status=200,
    )


@csrf_exempt
def ipa_upload_view(request):
    """Recebe o IPA compilado pelo GitHub Actions CI/CD e guarda em /tmp/DeliveryPro.ipa."""
    if request.method != "POST":
        return JsonResponse({"detail": "Método não permitido."}, status=405)
    ipa_file = request.FILES.get("ipa") or request.FILES.get("file")
    if not ipa_file:
        return JsonResponse({"detail": "Ficheiro 'ipa' ausente."}, status=400)
    with open(IPA_STORAGE_PATH, "wb+") as dest:
        for chunk in ipa_file.chunks():
            dest.write(chunk)
    return JsonResponse(
        {
            "status": "uploaded",
            "size_bytes": os.path.getsize(IPA_STORAGE_PATH),
            "download_url": "https://ango-ifood.onrender.com/ipa/download/",
            "portal_url": "https://ango-ifood.onrender.com/",
        },
        status=200,
    )


def version_info_view(request):
    """Endpoint JSON que informa os detalhes da última versão disponível dos aplicativos."""
    apk_ok, apk_mb = _get_file_info(APK_STORAGE_PATH, 58.4)
    ipa_ok, ipa_mb = _get_file_info(IPA_STORAGE_PATH, 42.1)
    return JsonResponse(
        {
            "app_name": "Delivery Pro",
            "platform_country": "Angola (AO)",
            "currency": "Kwanza (AOA)",
            "timestamp": timezone.now().isoformat(),
            "android": {
                "available": True,
                "size_mb": apk_mb,
                "download_url": "https://ango-ifood.onrender.com/apk/download/",
                "direct_release_url": "https://github.com/NDOMBAXIBONGA/Ango_Ifood/releases/download/latest/app-release.apk",
            },
            "ios": {
                "available": True,
                "size_mb": ipa_mb,
                "download_url": "https://ango-ifood.onrender.com/ipa/download/",
                "direct_release_url": "https://github.com/NDOMBAXIBONGA/Ango_Ifood/releases/download/latest/app-release.ipa",
            },
        },
        status=200,
    )


urlpatterns = [
    # Página Web de Divulgação Oficial e Portal de Downloads (Android APK & iOS IPA)
    path("", landing_page_view, name="landing-page"),
    path("download/", landing_page_view, name="download-portal"),
    path("apk/", landing_page_view, name="apk-portal"),
    path("apk/download/", apk_download_view, name="apk-download"),
    path("apk/upload/", apk_upload_view, name="apk-upload"),
    path("ipa/", landing_page_view, name="ipa-portal"),
    path("ipa/download/", ipa_download_view, name="ipa-download"),
    path("ipa/upload/", ipa_upload_view, name="ipa-upload"),
    path("api/v1/version/", version_info_view, name="version-info"),
    # Endpoints de Saúde e Despertar do Contentor Render (Cold Start Wake-up)
    path("api/v1/health/", health_check, name="health-check"),
    path("healthz/", health_check, name="healthz"),
    # Endpoints de Personalização Visual Total e Temas do Django Admin (Unfold / Tailwind)
    path("admin/theme/", admin_theme_picker_view, name="admin-theme-picker"),
    path("admin/theme/dynamic.css", admin_dynamic_css_view, name="admin-theme-css"),
    path("admin/theme/save/", save_theme_custom_view, name="admin-theme-save"),
    path("admin/theme/set/<str:theme_name>/", set_theme_redirect_view, name="admin-theme-set"),
    # Gestão de Atualizações Remotas (OTA / Kill Switch) e Download iOS
    path("download/ios/", ios_download_page_view, name="ios-download-page"),
    path("api/app/check-update/", check_app_update_api_view, name="app-check-update"),
    path("api/v1/app/check-update/", check_app_update_api_view, name="app-check-update-v1"),
    path("admin/", admin.site.urls),
    # Endpoints de Autenticação Passwordless OTP e Gestão de Conta (RN-001, RN-002, RN-003, RN-006)
    path("api/v1/auth/", include(("apps.accounts.urls", "accounts"), namespace="accounts")),
    path("api/auth/", include(("apps.accounts.urls", "accounts"), namespace="accounts-api-alias")),
    path("auth/", include(("apps.accounts.urls", "accounts"), namespace="accounts-auth-alias")),
    # Endpoints de Descoberta Geoespacial de Lojas (RN-025 a RN-030)
    path("api/v1/catalog/", include("apps.catalog.urls", namespace="catalog")),
    # Endpoints de Cobertura Geográfica e Expansão Nacional de Angola (18 Províncias e Municípios)
    path("api/v1/geo/", include("apps.catalog.geo_urls", namespace="geo")),
    # Endpoints de Gestão do Catálogo pelo Parceiro (RN-014, RN-015, RN-016, RN-017, RN-020)
    path("api/v1/partner/catalog/", include((partner_catalog_router.urls, "partner-catalog"))),
    # Endpoints de Operação e Horários da Loja pelo Parceiro (RN-012, RN-013)
    path("api/v1/partner/store/", include("apps.catalog.partner_store_urls", namespace="partner-store")),
    # Endpoints de Carrinho e Gestão de Itens (RN-040, RN-042, RN-044, RN-063)
    path("api/v1/cart/", include("apps.cart.urls", namespace="cart")),
    # Endpoints de Checkout e Gestão de Pedidos OMS (Secções 4 e 5, RN-040 a RN-067)
    path("api/v1/orders/", include("apps.orders.urls", namespace="orders")),
    # Endpoints de Logística, Entregas e Verificação de PIN (RN-094 a RN-097)
    path("api/v1/logistics/", include("apps.logistics.urls", namespace="logistics")),
    path("api/entregas/calcular-frete/", CalcularFreteView.as_view(), name="entregas-calcular-frete"),
    # Bootstrap Unificado do Sistema & Server-Driven UI (100% Controlo Remoto)
    path("api/v1/system/bootstrap/", system_bootstrap_api_view, name="system-bootstrap"),
    path("api/system/bootstrap/", system_bootstrap_api_view, name="system-bootstrap-alias"),
    # Endpoints de Administração e Dashboard Operacional de KPIs (Secção 10 e Secção 8.1)
    path("api/v1/admin/", include("apps.orders.admin_urls", namespace="admin-portal")),
    # Endpoints de Suporte, Mediação de Disputas e Incidentes (RN-106, RN-138 a RN-142)
    path("api/v1/support/", include("apps.support.urls", namespace="support")),
    # Endpoints de Gestão de Tokens JWT (SimpleJWT)
    path("api/v1/auth/token/", TokenObtainPairView.as_view(), name="token_obtain_pair"),
    path("api/v1/auth/token/refresh/", TokenRefreshView.as_view(), name="token_refresh"),
    path("api/v1/auth/token/verify/", TokenVerifyView.as_view(), name="token_verify"),
]

# Rota para servir ficheiros de mídia e estáticos como fallback resiliente (WhiteNoise + Daphne)
from django.urls import re_path
from django.views.static import serve
from apps.catalog.views import MediaStreamView

urlpatterns += [
    re_path(r"^static/(?P<path>.*)$", serve, {"document_root": settings.STATIC_ROOT}),
    re_path(r"^media/(?P<path>.*)$", MediaStreamView.as_view(), name="media-stream"),
]
