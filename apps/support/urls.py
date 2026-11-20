"""
URLs da aplicação 'support' (Mediação de Disputas, Helpdesk e Incidentes).
Módulo: apps/support/urls.py
"""
from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.support.bootstrap_views import system_bootstrap_api_view
from apps.support.views import DisputeResolutionViewSet

app_name = "support"

router = DefaultRouter()
router.register(r"disputes", DisputeResolutionViewSet, basename="disputes")

urlpatterns = [
    path("system/bootstrap/", system_bootstrap_api_view, name="system-bootstrap-support"),
    path("", include(router.urls)),
]

