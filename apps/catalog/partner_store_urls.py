"""
Rotas do Django REST Framework para operação e status da loja do Parceiro (RN-012, RN-013).
"""
from django.urls import path

from apps.catalog.views import (
    PartnerMediaUploadView,
    PartnerStoreHoursView,
    PartnerStoreStatusView,
    PartnerStorefrontCMSView,
)

app_name = "partner-store"

urlpatterns = [
    # PATCH /api/v1/partner/store/status/ (RN-013: Pausa temporária e reativação automática)
    path("status/", PartnerStoreStatusView.as_view(), name="store-status"),
    # GET/POST/PUT /api/v1/partner/store/hours/ (RN-012: Matriz de horários semanais)
    path("hours/", PartnerStoreHoursView.as_view(), name="store-hours"),
    # GET/POST/PUT/PATCH /api/v1/partner/store/storefront/ (Controlo Total CMS da Vitrine, Reservas e Mensagens)
    path("storefront/", PartnerStorefrontCMSView.as_view(), name="store-cms"),
    # POST /api/v1/partner/store/upload/ (Upload de Imagens e Vídeos da Galeria)
    path("upload/", PartnerMediaUploadView.as_view(), name="store-upload"),
]

