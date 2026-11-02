"""
Configuração de URLs da aplicação 'orders' (OMS & Checkout).
Expõe a ViewSet `/api/v1/orders/checkout/` com as ações:
- `POST /api/v1/orders/checkout/preview/`
- `POST /api/v1/orders/checkout/confirm/`
"""
from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.orders.views import CheckoutViewSet

app_name = "orders"

router = DefaultRouter()
router.register(r"checkout", CheckoutViewSet, basename="orders-checkout")

urlpatterns = [
    path("", include(router.urls)),
]
