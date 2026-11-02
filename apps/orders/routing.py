"""
Definição de Rotas WebSockets (URLRouter) para a aplicação 'orders'.
Implementa o endpoint de tracking em tempo real (RN-094 e Secção 12.1).
"""
from django.urls import path

from apps.orders import consumers

websocket_urlpatterns = [
    # Rota canónica de rastreamento em tempo real do pedido e transmissão GPS do estafeta (RN-094)
    path(
        "ws/v1/orders/tracking/<uuid:pedido_id>/",
        consumers.OrderTrackingConsumer.as_asgi(),
        name="ws_order_tracking",
    ),
]

