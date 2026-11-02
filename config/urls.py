"""
Rotas principais (URLconf) do projeto, incluindo endpoints JWT.
"""
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
    """Endpoint leve de verificação de integridade (Health Check) para acordar o Render."""
    return JsonResponse(
        {
            "status": "healthy",
            "service": "delivery-backend-api",
            "timestamp": timezone.now().isoformat(),
        },
        status=200,
    )


urlpatterns = [
    # Endpoints de Saúde e Despertar do Contentor Render (Cold Start Wake-up)
    path("api/v1/health/", health_check, name="health-check"),
    path("healthz/", health_check, name="healthz"),
    path("admin/", admin.site.urls),
    # Endpoints de Autenticação Passwordless OTP e Gestão de Conta (RN-001, RN-002, RN-003, RN-006)
    path("api/v1/auth/", include("apps.accounts.urls", namespace="accounts")),
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
