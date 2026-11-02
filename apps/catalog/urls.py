"""
Rotas da aplicação 'catalog' para Descoberta Geoespacial e Gestão do Catálogo pelo Parceiro.
"""
from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.catalog.views import (
    PartnerCategoryViewSet,
    PartnerMenuItemViewSet,
    StoreDiscoveryViewSet,
)

app_name = "catalog"

discovery_router = DefaultRouter()
discovery_router.register(r"stores", StoreDiscoveryViewSet, basename="store-discovery")

partner_router = DefaultRouter()
partner_router.register(
    r"categories",
    PartnerCategoryViewSet,
    basename="partner-catalog-categories",
)
partner_router.register(
    r"items",
    PartnerMenuItemViewSet,
    basename="partner-catalog-items",
)

urlpatterns = [
    path("", include(discovery_router.urls)),
]
