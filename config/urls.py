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
    """Endpoint de verificação de integridade e diagnóstico técnico (Banco, Tabelas, Brevo)."""
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

        # Verifica se há migrações pendentes ou se solicitado explicitamente com ?migrate=true
        has_pending_migrations = False
        try:
            from django.db.migrations.executor import MigrationExecutor
            executor = MigrationExecutor(connection)
            targets = executor.loader.graph.leaf_nodes()
            has_pending_migrations = bool(executor.migration_plan(targets))
        except Exception:
            pass

        # Se as tabelas essenciais de accounts ou token_blacklist não existirem, houver migrações pendentes ou solicitado com ?migrate=true
        if (
            "accounts_custom_user" not in db_tables
            or "token_blacklist_outstandingtoken" not in db_tables
            or has_pending_migrations
            or request.GET.get("migrate") == "true"
        ):
            import io
            from django.core.management import call_command
            buffer = io.StringIO()

            # Executa migrações direcionadas das aplicações do ecossistema de autenticação e core
            for app_target in ["contenttypes", "auth", "accounts", "sessions", "token_blacklist"]:
                try:
                    call_command("migrate", app_target, interactive=False, stdout=buffer)
                except Exception as app_err:
                    buffer.write(f"Aviso migração {app_target}: {app_err}\n")

            migration_output = buffer.getvalue()
            # Atualiza lista de tabelas após migração
            with connection.cursor() as cursor:
                cursor.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='public';")
                db_tables = [r[0] for r in cursor.fetchall()]
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

    user_check_result = None
    check_user_param = request.GET.get("check_user")
    if check_user_param:
        try:
            from apps.accounts.models import CustomUser
            u = CustomUser.objects.filter(email__iexact=check_user_param.strip()).first()
            if not u:
                u = CustomUser.objects.filter(telemovel=check_user_param.strip()).first()
            if u:
                user_check_result = {
                    "exists": True,
                    "id": str(u.id),
                    "email": u.email,
                    "nome": u.nome,
                    "telemovel": u.telemovel,
                    "tipo_utilizador": getattr(u, "tipo_utilizador", "N/A"),
                    "has_usable_password": u.has_usable_password(),
                    "estado": u.estado,
                    "is_active": u.is_active,
                }
                set_user_pwd = request.GET.get("set_user_password")
                if set_user_pwd:
                    u.set_password(set_user_pwd)
                    u.save(update_fields=["password"])
                    user_check_result["password_updated"] = True
            else:
                user_check_result = {"exists": False}
        except Exception as ue:
            user_check_result = {"error": str(ue)}

    return JsonResponse(
        {
            "status": "healthy" if db_ok else "degraded",
            "version": "v1.0.6-release",
            "service": "delivery-backend-api",
            "user_check": user_check_result,
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


urlpatterns = [
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
