"""
Rotas administrativas da aplicação 'orders'.
Disponibiliza o endpoint `/api/v1/admin/dashboard/kpis/` para consulta de KPIs e SLAs operacionais (Secção 10 e 8.1).
"""
from django.urls import include, path
from rest_framework.routers import DefaultRouter

from apps.orders.dashboard_views import (
    OperationalDashboardViewSet,
    OperationalMetricsDashboardViewSet,
)

app_name = "admin_orders"

router = DefaultRouter()
router.register(r"dashboard", OperationalMetricsDashboardViewSet, basename="admin-dashboard")

urlpatterns = [
    path("", include(router.urls)),
]
