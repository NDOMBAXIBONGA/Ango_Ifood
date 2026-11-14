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
    )

    if not is_deep_check:
        return JsonResponse(
            {
                "status": "healthy",
                "version": "v1.0.6-release",
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
                "catalog", "orders", "logistics", "finance", "promotions", "support"
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

    return JsonResponse(
        {
            "status": "healthy" if db_ok else "degraded",
            "version": "v1.0.6-release",
            "service": "delivery-backend-api",
            "sync_stores": sync_stores_result,
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


from django.http import FileResponse, HttpResponse
from django.views.decorators.csrf import csrf_exempt

APK_STORAGE_PATH = "/tmp/DeliveryPro.apk"


def apk_portal_view(request):
    """Portal web direto para download do APK Android em qualquer telemóvel ou PC."""
    exists = os.path.exists(APK_STORAGE_PATH)
    size_mb = round(os.path.getsize(APK_STORAGE_PATH) / (1024 * 1024), 1) if exists else 58.2
    html = f"""<!DOCTYPE html>
<html lang="pt">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Delivery Pro — Baixar APK Oficial</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; }}
  .card {{ background: #1e293b; border-radius: 24px; padding: 36px 28px; max-width: 440px; width: 100%; text-align: center; box-shadow: 0 25px 50px -12px rgba(0,0,0,0.5); border: 1px solid rgba(255,255,255,0.08); }}
  .icon {{ width: 80px; height: 80px; background: linear-gradient(135deg, #ef4444, #dc2626); border-radius: 22px; display: inline-flex; align-items: center; justify-content: center; font-size: 40px; margin-bottom: 20px; box-shadow: 0 10px 25px rgba(239,68,68,0.4); }}
  h1 {{ margin: 0 0 8px; font-size: 26px; font-weight: 800; }}
  p {{ color: #94a3b8; margin: 0 0 28px; font-size: 15px; line-height: 1.5; }}
  .btn {{ display: block; background: linear-gradient(135deg, #22c55e, #16a34a); color: #fff; text-decoration: none; font-weight: 700; font-size: 17px; padding: 18px 24px; border-radius: 16px; box-shadow: 0 10px 25px rgba(34,197,94,0.35); transition: transform 0.15s; }}
  .btn:active {{ transform: scale(0.98); }}
  .meta {{ margin-top: 20px; font-size: 13px; color: #64748b; }}
</style>
</head>
<body>
  <div class="card">
    <div class="icon">🛵</div>
    <h1>Delivery Pro</h1>
    <p>Plataforma Oficial de Entregas de Angola<br>Versão Android Release ({size_mb} MB)</p>
    <a class="btn" href="/apk/download/">⬇️ BAIXAR APK AGORA</a>
    <div class="meta">Compatível com Android 7.0+ • Instalação Direta</div>
  </div>
</body>
</html>"""
    return HttpResponse(html, content_type="text/html; charset=utf-8")


def apk_download_view(request):
    """Entrega o ficheiro binário DeliveryPro.apk diretamente para instalação com cache e auto-recuperação."""
    for path in [
        APK_STORAGE_PATH,
        os.path.join(settings.BASE_DIR, "DeliveryPro.apk"),
        os.path.join(settings.BASE_DIR, "media", "DeliveryPro.apk"),
    ]:
        if os.path.exists(path) and os.path.getsize(path) > 10_000_000:
            return FileResponse(
                open(path, "rb"),
                as_attachment=True,
                filename="DeliveryPro.apk",
                content_type="application/vnd.android.package-archive",
            )

    # Auto-recuperação resiliente: Se o /tmp/ tiver sido reiniciado no Render, recupera do GitHub Releases
    try:
        import urllib.request
        github_token = os.environ.get("GITHUB_TOKEN") or "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"
        req = urllib.request.Request(
            "https://api.github.com/repos/NDOMBAXIBONGA/Ango_Ifood/releases/tags/latest",
            headers={"Authorization": f"Bearer {github_token}", "User-Agent": "Render-DeliveryPro"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            for asset in data.get("assets", []):
                if asset.get("name", "").endswith(".apk"):
                    asset_url = asset["url"]
                    asset_req = urllib.request.Request(
                        asset_url,
                        headers={
                            "Authorization": f"Bearer {github_token}",
                            "Accept": "application/octet-stream",
                            "User-Agent": "Render-DeliveryPro",
                        },
                    )
                    with urllib.request.urlopen(asset_req, timeout=60) as a_resp:
                        apk_bytes = a_resp.read()
                        with open(APK_STORAGE_PATH, "wb") as f:
                            f.write(apk_bytes)
                        return FileResponse(
                            open(APK_STORAGE_PATH, "rb"),
                            as_attachment=True,
                            filename="DeliveryPro.apk",
                            content_type="application/vnd.android.package-archive",
                        )
    except Exception as err:
        logger.warning("Falha ao recuperar APK do GitHub Releases: %s", err)

    return HttpResponse(
        "O ficheiro APK está a ser sincronizado no servidor. Aguarde alguns segundos e recarregue a página.",
        status=404,
        content_type="text/plain; charset=utf-8",
    )


@csrf_exempt
def apk_upload_view(request):
    """Recebe o APK compilado pelo GitHub Actions CI/CD e guarda em /tmp/DeliveryPro.apk."""
    if request.method != "POST":
        return JsonResponse({"detail": "Método não permitido."}, status=405)
    apk_file = request.FILES.get("apk")
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
            "portal_url": "https://ango-ifood.onrender.com/apk/",
        },
        status=200,
    )


urlpatterns = [
    # Portal Público de Download Direto do APK Android
    path("apk/", apk_portal_view, name="apk-portal"),
    path("apk/download/", apk_download_view, name="apk-download"),
    path("apk/upload/", apk_upload_view, name="apk-upload"),
    # Endpoints de Saúde e Despertar do Contentor Render (Cold Start Wake-up)
    path("api/v1/health/", health_check, name="health-check"),
    path("healthz/", health_check, name="healthz"),
    path("admin/", admin.site.urls),
    # Endpoints de Autenticação Passwordless OTP e Gestão de Conta (RN-001, RN-002, RN-003, RN-006)
    path("api/v1/auth/", include(("apps.accounts.urls", "accounts"), namespace="accounts")),
    path("api/auth/", include(("apps.accounts.urls", "accounts"), namespace="accounts-api-alias")),
    path("auth/", include(("apps.accounts.urls", "accounts"), namespace="accounts-auth-alias")),
    # Endpoints de Descoberta Geoespacial de Lojas (RN-025 a RN-030)
    path("api/v1/catalog/", include("apps.catalog.urls", namespace="catalog")),
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
    # Endpoints de Administração e Dashboard Operacional de KPIs (Secção 10 e Secção 8.1)
    path("api/v1/admin/", include("apps.orders.admin_urls", namespace="admin-portal")),
    # Endpoints de Suporte, Mediação de Disputas e Incidentes (RN-106, RN-138 a RN-142)
    path("api/v1/support/", include("apps.support.urls", namespace="support")),
    # Endpoints de Gestão de Tokens JWT (SimpleJWT)
    path("api/v1/auth/token/", TokenObtainPairView.as_view(), name="token_obtain_pair"),
    path("api/v1/auth/token/refresh/", TokenRefreshView.as_view(), name="token_refresh"),
    path("api/v1/auth/token/verify/", TokenVerifyView.as_view(), name="token_verify"),
]

# Rota para servir ficheiros de mídia (uploads de imagens e vídeos dos parceiros e vitrine)
from django.views.static import serve
from django.urls import re_path

urlpatterns += [
    re_path(r"^media/(?P<path>.*)$", serve, {"document_root": settings.MEDIA_ROOT}),
]
