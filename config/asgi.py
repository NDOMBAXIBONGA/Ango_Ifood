"""
Configuração ASGI para Django Channels (HTTP + WebSockets).
"""
import os
from django.core.asgi import get_asgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

# Inicializa a aplicação ASGI do Django antes de importar consumers/rotas
django_asgi_app = get_asgi_application()

from channels.auth import AuthMiddlewareStack  # noqa: E402
from channels.routing import ProtocolTypeRouter, URLRouter  # noqa: E402
from channels.security.websocket import AllowedHostsOriginValidator  # noqa: E402

from apps.logistics.routing import websocket_urlpatterns as logistics_websocket_routes  # noqa: E402
from apps.orders.routing import websocket_urlpatterns as orders_websocket_routes  # noqa: E402

websocket_urlpatterns: list = [
    *logistics_websocket_routes,
    *orders_websocket_routes,
]

application = ProtocolTypeRouter(
    {
        "http": django_asgi_app,
        "websocket": AllowedHostsOriginValidator(
            AuthMiddlewareStack(
                URLRouter(websocket_urlpatterns)
            )
        ),
    }
)
