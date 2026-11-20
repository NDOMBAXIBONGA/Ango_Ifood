"""
Configuração ASGI Principal para Django Channels (HTTP + WebSockets).
Suporta servidores ASGI de produção (Daphne / Uvicorn) no Render e outros ambientes cloud.
Gerencia roteamento bidirecional HTTP e WebSockets com validação de origem e autenticação JWT.
"""
import os
from urllib.parse import parse_qs

from django.core.asgi import get_asgi_application

# ==============================================================================
# 1. INICIALIZAÇÃO DO AMBIENTE DJANGO
# ==============================================================================
# Define o módulo de definições padrão antes de instanciar os consumers e models
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

# Inicializa a aplicação ASGI HTTP nativa do Django (garante que os models/apps estejam carregados)
django_asgi_app = get_asgi_application()

# ==============================================================================
# 2. IMPORTS ESPECÍFICOS DO CHANNELS E AUTENTICAÇÃO ASSÍNCRONA
# ==============================================================================
# Estes módulos devem ser importados estritamente APÓS get_asgi_application()
from channels.auth import AuthMiddlewareStack  # noqa: E402
from channels.db import database_sync_to_async  # noqa: E402
from channels.routing import ProtocolTypeRouter, URLRouter  # noqa: E402
from channels.security.websocket import AllowedHostsOriginValidator  # noqa: E402
from django.contrib.auth import get_user_model  # noqa: E402
from django.contrib.auth.models import AnonymousUser  # noqa: E402
from rest_framework_simplejwt.tokens import AccessToken  # noqa: E402

# Importação das rotas WebSockets das aplicações de negócio
from django.contrib.staticfiles.handlers import ASGIStaticFilesHandler  # noqa: E402
from apps.logistics.routing import websocket_urlpatterns as logistics_websocket_routes  # noqa: E402
from apps.orders.routing import websocket_urlpatterns as orders_websocket_routes  # noqa: E402


# ==============================================================================
# 3. MIDDLEWARE DE AUTENTICAÇÃO JWT PARA WEBSOCKETS (JwtAuthMiddleware)
# ==============================================================================
@database_sync_to_async
def get_user_from_jwt_token(token_key: str):
    """
    Decodifica o token JWT (SimpleJWT) e obtém o utilizador ativo na base de dados de forma assíncrona.
    Retorna AnonymousUser em caso de token expirado, inválido ou utilizador inexistente.
    """
    try:
        token = AccessToken(token_key)
        user_id = token.get("user_id") or token.get("sub")
        if not user_id:
            return AnonymousUser()
        User = get_user_model()
        return User.objects.get(id=user_id, is_active=True)
    except Exception:
        return AnonymousUser()


class JwtAuthMiddleware:
    """
    Middleware ASGI personalizado para autenticação JWT em conexões WebSockets.
    Suporta passagem de token via:
      1. Query String: ws://.../ws/v1/orders/tracking/<uuid>/?token=<jwt_access_token>
      2. Cabeçalho HTTP Authorization: 'Bearer <jwt_access_token>'
    """

    def __init__(self, inner):
        self.inner = inner

    async def __call__(self, scope, receive, send):
        # Apenas processa se o utilizador ainda não tiver sido autenticado
        if "user" not in scope or scope["user"].is_anonymous:
            token = None

            # 1. Tenta extrair da Query String (?token=...)
            query_string = scope.get("query_string", b"").decode("utf-8")
            query_params = parse_qs(query_string)
            if "token" in query_params and query_params["token"]:
                token = query_params["token"][0]

            # 2. Se não estiver na query string, tenta extrair dos cabeçalhos (Authorization: Bearer <jwt>)
            if not token and "headers" in scope:
                for header_name, header_value in scope["headers"]:
                    if header_name.lower() == b"authorization":
                        parts = header_value.decode("utf-8").split()
                        if len(parts) == 2 and parts[0].lower() == "bearer":
                            token = parts[1]
                            break

            # Valida e atribui o utilizador ao scope da conexão WebSocket
            if token:
                scope["user"] = await get_user_from_jwt_token(token)
            else:
                scope["user"] = AnonymousUser()

        return await self.inner(scope, receive, send)


def JwtAuthMiddlewareStack(inner):
    """
    Combina a pilha de autenticação padrão (AuthMiddlewareStack) com o JwtAuthMiddleware,
    assegurando suporte simultâneo a sessões tradicionais de backoffice e tokens JWT móveis/web.
    """
    return JwtAuthMiddleware(AuthMiddlewareStack(inner))


# ==============================================================================
# 4. ROTEAMENTO DE ROTAS WEBSOCKET
# ==============================================================================
# Consolida todos os endpoints WebSockets (telemetria de estafeta, tracking de encomendas, despachos)
websocket_urlpatterns = [
    *logistics_websocket_routes,
    *orders_websocket_routes,
]

# ==============================================================================
# 5. APLICAÇÃO ASGI PRINCIPAL (ProtocolTypeRouter)
# ==============================================================================
# Configura o encaminhamento de protocolos:
# - 'http': Processado com manipulador estático ASGI + núcleo Django (Views, REST Framework, Admin Unfold).
# - 'websocket': Filtrado pelo validador de origens e autenticado via JWT para o Daphne Server no Render.
application = ProtocolTypeRouter(
    {
        "http": ASGIStaticFilesHandler(django_asgi_app),
        "websocket": AllowedHostsOriginValidator(
            JwtAuthMiddlewareStack(
                URLRouter(websocket_urlpatterns)
            )
        ),
    }
)
