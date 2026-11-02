"""
URLs da aplicação 'support' (Mediação de Disputas, Helpdesk e Incidentes).
Módulo: apps/support/urls.py
"""
from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.support.views import DisputeResolutionViewSet

app_name = "support"

router = DefaultRouter()
router.register(r"disputes", DisputeResolutionViewSet, basename="disputes")

urlpatterns = [
    path("", include(router.urls)),
]

