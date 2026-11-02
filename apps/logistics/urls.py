"""
Rotas de API REST para a aplicação 'logistics'.
Implementa os endpoints de encerramento de entrega, verificação de PIN e reporte de ausência.
"""
from django.urls import path

from apps.logistics.views import (
    DeliveryArrivalView,
    DeliveryReportAbsenceView,
    DeliveryVerifyPinView,
)

app_name = "logistics"

urlpatterns = [
    # RN-095: Encerramento de corrida com verificação de PIN de 4 dígitos
    path(
        "delivery/verify-pin/",
        DeliveryVerifyPinView.as_view(),
        name="delivery-verify-pin",
    ),
    # RN-096: Registo de chegada ao destino para início da tolerância de 7 minutos
    path(
        "delivery/arrive/",
        DeliveryArrivalView.as_view(),
        name="delivery-arrive",
    ),
    # RN-096 / RN-097: Reporte de ausência do cliente após 7 minutos de tolerância
    path(
        "delivery/report-absence/",
        DeliveryReportAbsenceView.as_view(),
        name="delivery-report-absence",
    ),
]
