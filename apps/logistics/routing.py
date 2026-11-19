"""
Definição de Rotas WebSockets (URLRouter) para a aplicação 'logistics'.
Implementa o endpoint de tracking em tempo real (RN-094 e Secção 12.1).
"""
from django.urls import path

from apps.logistics import consumers

websocket_urlpatterns = [
    # Rota canónica de rastreamento em tempo real do estafeta por pedido (RN-094)
    path(
        "ws/delivery/tracking/<uuid:pedido_id>/",
        consumers.DeliveryTrackingConsumer.as_asgi(),
        name="ws_delivery_tracking",
    ),
    # Rota leve em tempo real para rastreamento de entrega (app cliente e estafeta)
    path(
        "ws/entrega/<str:pedido_id>/",
        consumers.TrackingEntregaConsumer.as_asgi(),
        name="ws_tracking_entrega",
    ),
]

