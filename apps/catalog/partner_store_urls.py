"""
Rotas do Django REST Framework para operação e status da loja do Parceiro (RN-012, RN-013).
"""
from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.catalog.views import (
    PartnerMediaUploadView,
    PartnerStoreFinancesView,
    PartnerStoreHoursView,
    PartnerStoreSettingsView,
    PartnerStoreStatusView,
    PartnerStorefrontCMSView,
)
from apps.orders.views import PartnerOrderViewSet

app_name = "partner-store"

partner_order_router = DefaultRouter()
partner_order_router.register(r"orders", PartnerOrderViewSet, basename="partner-store-orders")

urlpatterns = [
    # PATCH /api/v1/partner/store/status/ (RN-013: Pausa temporária e reativação automática)
    path("status/", PartnerStoreStatusView.as_view(), name="store-status"),
    # GET /api/v1/partner/store/finances/ (Faturação real, pedidos concluídos e comissões da loja)
    path("finances/", PartnerStoreFinancesView.as_view(), name="store-finances"),
    # GET/PATCH /api/v1/partner/store/settings/ (Tempo de preparo, raio PostGIS e dados bancários IBAN)
    path("settings/", PartnerStoreSettingsView.as_view(), name="store-settings"),
    # GET/POST/PUT /api/v1/partner/store/hours/ (RN-012: Matriz de horários semanais)
    path("hours/", PartnerStoreHoursView.as_view(), name="store-hours"),
    # GET/POST/PUT/PATCH /api/v1/partner/store/storefront/ (Controlo Total CMS da Vitrine, Reservas e Mensagens)
    path("storefront/", PartnerStorefrontCMSView.as_view(), name="store-cms"),
    # POST /api/v1/partner/store/upload/ (Upload de Imagens e Vídeos da Galeria)
    path("upload/", PartnerMediaUploadView.as_view(), name="store-upload"),
    # Endpoints do Terminal KDS de Gestão de Pedidos do Parceiro (GET list, POST accept, ready, reject)
    path("", include(partner_order_router.urls)),
]

