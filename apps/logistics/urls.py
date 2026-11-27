"""
Rotas de API REST para a aplicação 'logistics'.
Implementa os endpoints de encerramento de entrega, verificação de PIN e reporte de ausência.
"""
from django.urls import path

from apps.logistics.views import (
    CalcularFreteView,
    CourierActiveTripView,
    CourierAvailabilityView,
    CourierOnboardingView,
    CourierProfileMeView,
    CourierTripActionView,
    CourierTripsListView,
    CourierWalletView,
    DeliveryArrivalView,
    DeliveryReportAbsenceView,
    DeliveryVerifyPinView,
    OrderTrackingTelemetryView,
)

app_name = "logistics"

urlpatterns = [
    # Cálculo de frete, distância viária e polilinha OSRM (100% gratuito)
    path("calcular-frete/", CalcularFreteView.as_view(), name="calcular-frete"),
    # Onboarding documental e submissão de viatura/dados bancários do estafeta (RN-082)
    path("couriers/onboarding/", CourierOnboardingView.as_view(), name="courier-onboarding"),
    # Perfil real do estafeta autenticado (GET e PATCH)
    path("couriers/me/", CourierProfileMeView.as_view(), name="courier-me"),
    # Disponibilidade operacional Online/Offline e atualização de GPS PostGIS (RN-083)
    path("couriers/availability/", CourierAvailabilityView.as_view(), name="courier-availability"),
    # Carteira real do estafeta: saldo, ganhos de hoje, produtividade semanal, histórico e repasse (RN-146 / RN-151)
    path("couriers/wallet/", CourierWalletView.as_view(), name="courier-wallet"),
    # Corridas disponíveis prontas para recolha no radar
    path("trips/available/", CourierTripsListView.as_view(), name="courier-trips-available"),
    # Corrida ativa atualmente atribuída ou em curso pelo estafeta
    path("trips/active/", CourierActiveTripView.as_view(), name="courier-trip-active"),
    # Ações operacionais da corrida: accept, reject, arrive-store, pickup, incident
    path("trips/<uuid:pk>/<str:action>/", CourierTripActionView.as_view(), name="courier-trip-action"),
    # Telemetria de rastreamento em tempo real do pedido e estafeta
    path("orders/<uuid:pk>/tracking/", OrderTrackingTelemetryView.as_view(), name="order-tracking"),
    # RN-095: Encerramento de corrida com verificação de PIN de 4 dígitos
    path("delivery/verify-pin/", DeliveryVerifyPinView.as_view(), name="delivery-verify-pin"),
    # RN-096: Registo de chegada ao destino para início da tolerância de 7 minutos
    path("delivery/arrive/", DeliveryArrivalView.as_view(), name="delivery-arrive"),
    # RN-096 / RN-097: Reporte de ausência do cliente após 7 minutos de tolerância
    path("delivery/report-absence/", DeliveryReportAbsenceView.as_view(), name="delivery-report-absence"),
]
