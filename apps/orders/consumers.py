"""
Consumidor WebSockets Assíncrono (Django Channels) para Tracking de Pedidos em Tempo Real ('orders').
Módulo: apps/orders/consumers.py

Implementa com rigor técnico:
- RN-094: Rastreamento em tempo real do estafeta durante a rota de entrega com transmissão contínua de GPS;
- Secção 12.1: Disparo e reencaminhamento do evento canónico 'delivery.location_updated' para todos os subscritores;
- Autenticação JWT via Query String (?token=<jwt_access_token>) ou Cabeçalho WebSocket;
- Autorização RBAC Estrita: Apenas Cliente do Pedido, Estafeta Atribuído, Parceiro da Loja ou Staff;
- Atualização Espacial PostGIS: Ponto geográfico PointField (SRID 4326) no modelo Estafeta;
- Emissão de Sinal Django Assíncrono: 'estafeta_location_updated' para desacoplamento de listeners;
- Gestão de Grupos Distribuídos (Redis Channel Layer): 'group_order_tracking_{pedido_id}';
- Elevada Concorrência e Zero Memory Leaks: ciclo de vida limpo e operações assíncronas não-bloqueantes.
"""
from __future__ import annotations

import json
import logging
import urllib.parse
import uuid
from typing import Any, Optional

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncWebsocketConsumer
from django.contrib.auth import get_user_model
from django.contrib.gis.geos import Point
from django.utils import timezone
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError
from rest_framework_simplejwt.tokens import AccessToken

from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import Pedido
from apps.orders.signals import estafeta_location_updated

logger = logging.getLogger("orders.websocket.tracking")
User = get_user_model()


class OrderTrackingConsumer(AsyncWebsocketConsumer):
    """
    Consumidor WebSocket de alta performance para tracking e telemetria de pedidos em tempo real.

    Ciclo de Vida da Conexão:
    1. 'connect()':
       - Valida o parâmetro de rota URL 'pedido_id' como UUID v4 canónico.
       - Extrai o token JWT da query string ('?token=...') e autentica o utilizador no SimpleJWT.
       - Verifica as permissões de acesso ao pedido (Cliente, Estafeta atribuído, Parceiro dono da loja).
       - Se autorizado, adiciona o canal ao grupo exclusivo 'group_order_tracking_{pedido_id}'.
       - Aceita a ligação ('await self.accept()') e emite o payload inicial de confirmação.
       - Se não autorizado, encerra a ligação com códigos WebSocket semânticos (4000, 4001, 4003).

    2. 'receive()':
       - Processa mensagens enviadas pelos clientes conectados.
       - Se a mensagem provier do Estafeta com coordenadas ('latitude', 'longitude'):
         * Valida os limites geográficos (-90 <= lat <= 90, -180 <= lng <= 180).
         * Atualiza de forma assíncrona o campo 'ultima_geolocalizacao' (PointField SRID 4326) no PostGIS.
         * Dispara o sinal Django 'estafeta_location_updated' para listeners adicionais (ex.: geofencing, ETA).
         * Transmite via channel layer para todo o grupo o evento 'delivery.location_updated' (Secção 12.1).

    3. 'delivery_location_updated()':
       - Handler do Channel Layer que serializa e envia as coordenadas aos clientes conectados (Cliente e Parceiro).

    4. 'disconnect()':
       - Remove o canal do grupo Redis correspondente, prevenindo fugas de memória ou canais órfãos.
    """

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.pedido_id: Optional[str] = None
        self.group_name: Optional[str] = None
        self.user: Optional[User] = None
        self.user_role: Optional[str] = None  # 'cliente', 'estafeta', 'parceiro', 'staff'
        self.estafeta_obj: Optional[Estafeta] = None

    # ==========================================================================
    # 1. CONEXÃO (CONNECT)
    # ==========================================================================

    async def connect(self) -> None:
        """
        Estabelece a ligação WebSocket com autenticação JWT e validação de permissões RBAC.
        """
        # Extrai e valida o UUID do pedido a partir dos parâmetros de rota URL
        raw_pedido_id = self.scope.get("url_route", {}).get("kwargs", {}).get("pedido_id")
        try:
            self.pedido_id = str(uuid.UUID(str(raw_pedido_id)))
        except (ValueError, TypeError):
            logger.warning("Conexão WebSocket rejeitada: 'pedido_id' com formato UUID inválido (%s).", raw_pedido_id)
            await self.close(code=4000)  # Bad Request
            return

        # Define o nome canónico do grupo exclusivo no Django Channels (Secção 12.1)
        self.group_name = f"group_order_tracking_{self.pedido_id}"

        # Extração do Token JWT da Query String (?token=...) ou Cabeçalhos
        token_raw = self._extrair_token_da_requisicao()
        if not token_raw:
            logger.warning(
                "Conexão WebSocket rejeitada: Ausência de token JWT para o pedido %s.",
                self.pedido_id,
            )
            await self.close(code=4001)  # Unauthorized
            return

        # Autenticação assíncrona do utilizador via SimpleJWT
        self.user = await self._autenticar_jwt(token_raw)
        if not self.user:
            logger.warning(
                "Conexão WebSocket rejeitada: Token JWT inválido, adulterado ou expirado para o pedido %s.",
                self.pedido_id,
            )
            await self.close(code=4001)  # Unauthorized
            return

        # Autorização RBAC: Apenas Cliente, Estafeta atribuído, Parceiro dono da loja ou Staff
        autorizado, self.user_role, self.estafeta_obj = await self._verificar_autorizacao_pedido(
            user_id=self.user.id,
            pedido_id=self.pedido_id,
        )

        if not autorizado:
            logger.warning(
                "Conexão WebSocket rejeitada (4003): Utilizador %s (%s) sem autorização para aceder ao pedido %s.",
                self.user.id,
                getattr(self.user, "email", "sem_email"),
                self.pedido_id,
            )
            await self.close(code=4003)  # Forbidden
            return

        # Adiciona o canal atual ao grupo do pedido no Channel Layer (Redis)
        await self.channel_layer.group_add(
            self.group_name,
            self.channel_name,
        )

        # Aceita formalmente a ligação WebSocket
        await self.accept()

        logger.info(
            "WebSocket conectado com sucesso: Pedido %s | User %s | Papel: %s | Canal %s",
            self.pedido_id,
            self.user.id,
            self.user_role,
            self.channel_name,
        )

        # Emite evento de confirmação de ligação estabelecida ao cliente
        await self.send(
            text_data=json.dumps(
                {
                    "event": "connection_established",
                    "pedido_id": self.pedido_id,
                    "user_id": str(self.user.id),
                    "role": self.user_role,
                    "timestamp": timezone.now().isoformat(),
                }
            )
        )

    # ==========================================================================
    # 2. DESCONEXÃO (DISCONNECT)
    # ==========================================================================

    async def disconnect(self, close_code: int) -> None:
        """
        Liberta recursos assíncronos e remove o canal do grupo Redis, eliminando fugas de memória.
        """
        if self.group_name:
            await self.channel_layer.group_discard(
                self.group_name,
                self.channel_name,
            )

        logger.info(
            "WebSocket desconectado: Pedido %s | User %s | Canal %s | Código: %s",
            self.pedido_id,
            getattr(self.user, "id", "Anon"),
            self.channel_name,
            close_code,
        )

    # ==========================================================================
    # 3. RECEÇÃO DE MENSAGENS (RECEIVE) - TELEMETRIA GPS RN-094
    # ==========================================================================

    async def receive(self, text_data: Optional[str] = None, bytes_data: Optional[bytes] = None) -> None:
        """
        Trata as mensagens recebidas via WebSocket.
        Se o ator for o Estafeta autenticado transmitindo coordenadas GPS:
        - Valida a conformidade do payload JSON: {"latitude": float, "longitude": float};
        - Atualiza o campo 'ultima_geolocalizacao' (PostGIS SRID 4326) no modelo Estafeta (RN-094);
        - Dispara o sinal assíncrono 'estafeta_location_updated';
        - Reencaminha o evento canónico 'delivery.location_updated' (Secção 12.1) para todo o grupo.
        """
        if not text_data:
            return

        try:
            payload = json.loads(text_data)
        except (json.JSONDecodeError, UnicodeDecodeError):
            await self.send(
                text_data=json.dumps(
                    {"error": "Formato de mensagem JSON inválido.", "codigo": "INVALID_JSON"}
                )
            )
            return

        tipo_acao = payload.get("action") or payload.get("event") or payload.get("type")

        # Heartbeat ping / pong para manter a ligação ativa e detetar desconexões
        if tipo_acao == "ping":
            await self.send(
                text_data=json.dumps(
                    {"event": "pong", "timestamp": timezone.now().isoformat()}
                )
            )
            return

        # Identificação de coordenadas de GPS enviadas pelo Estafeta (RN-094)
        lat = payload.get("latitude") if "latitude" in payload else payload.get("lat")
        lng = payload.get("longitude") if "longitude" in payload else payload.get("lng")

        if lat is not None or lng is not None or tipo_acao in ("location_update", "delivery.location_updated"):
            # 1. Apenas o estafeta oficialmente atribuído tem autorização para emitir telemetria
            if self.user_role != "estafeta" or not self.estafeta_obj:
                await self.send(
                    text_data=json.dumps(
                        {
                            "error": "Apenas o estafeta atribuído a este pedido tem autorização para transmitir coordenadas GPS.",
                            "codigo": "PERMISSION_DENIED",
                        }
                    )
                )
                return

            # 2. Validação obrigatória dos campos de latitude e longitude
            if lat is None or lng is None:
                await self.send(
                    text_data=json.dumps(
                        {
                            "error": "Campos 'latitude' e 'longitude' são obrigatórios.",
                            "codigo": "MISSING_COORDINATES",
                        }
                    )
                )
                return

            try:
                lat_float = float(lat)
                lng_float = float(lng)
            except (ValueError, TypeError):
                await self.send(
                    text_data=json.dumps(
                        {
                            "error": "Coordenadas numéricas de latitude e longitude inválidas.",
                            "codigo": "MALFORMED_COORDINATES",
                        }
                    )
                )
                return

            # 3. Validação dos limites geográficos padrão WGS84
            if not (-90.0 <= lat_float <= 90.0 and -180.0 <= lng_float <= 180.0):
                await self.send(
                    text_data=json.dumps(
                        {
                            "error": "Coordenadas fora dos limites do globo terrestre (-90 a 90, -180 a 180).",
                            "codigo": "COORDINATES_OUT_OF_BOUNDS",
                        }
                    )
                )
                return

            heading = payload.get("heading") or payload.get("bearing", 0.0)
            speed = payload.get("speed") or payload.get("velocidade_kmh", 0.0)
            precisao = payload.get("accuracy") or payload.get("precisao_metros", 5.0)

            # 4. Atualiza de forma assíncrona o modelo Estafeta no PostGIS e dispara sinal (RN-094)
            await self._atualizar_geolocalizacao_estafeta(
                estafeta_id=self.estafeta_obj.id,
                pedido_id=self.pedido_id,
                lat=lat_float,
                lng=lng_float,
                heading=float(heading) if heading is not None else 0.0,
                speed=float(speed) if speed is not None else 0.0,
            )

            # 5. Prepara o payload canónico do evento da Secção 12.1
            agora_iso = timezone.now().isoformat()
            evento_payload = {
                "type": "delivery_location_updated",
                "event": "delivery.location_updated",
                "pedido_id": self.pedido_id,
                "estafeta_id": str(self.estafeta_obj.id),
                "latitude": lat_float,
                "longitude": lng_float,
                "heading": float(heading) if heading is not None else 0.0,
                "speed": float(speed) if speed is not None else 0.0,
                "precisao_metros": float(precisao) if precisao is not None else 5.0,
                "timestamp": agora_iso,
            }

            # 6. Transmite instantaneamente para todos os membros do grupo (App Cliente e Portal Parceiro)
            await self.channel_layer.group_send(
                self.group_name,
                evento_payload,
            )

    # ==========================================================================
    # 4. HANDLER DE GRUPO DO CHANNEL LAYER (SECÇÃO 12.1)
    # ==========================================================================

    async def delivery_location_updated(self, event: dict[str, Any]) -> None:
        """
        Handler invocado pelo Channel Layer quando uma nova coordenada é difundida no grupo.
        Envia o payload JSON diretamente ao cliente WebSocket subscrito.
        """
        payload_saida = {
            "event": "delivery.location_updated",
            "pedido_id": event.get("pedido_id", self.pedido_id),
            "estafeta_id": event.get("estafeta_id"),
            "latitude": event["latitude"],
            "longitude": event["longitude"],
            "heading": event.get("heading", 0.0),
            "speed": event.get("speed", 0.0),
            "precisao_metros": event.get("precisao_metros", 5.0),
            "timestamp": event.get("timestamp", timezone.now().isoformat()),
        }
        await self.send(text_data=json.dumps(payload_saida))

    # ==========================================================================
    # 5. MÉTODOS DE BASE DE DADOS E SEGURANÇA (ASYNC TO SYNC)
    # ==========================================================================

    def _extrair_token_da_requisicao(self) -> Optional[str]:
        """Extrai o token JWT a partir da query string (?token=...) ou do cabeçalho Authorization."""
        # 1. Query string
        query_string = self.scope.get("query_string", b"").decode("utf-8")
        query_params = urllib.parse.parse_qs(query_string)
        tokens = query_params.get("token") or query_params.get("jwt") or query_params.get("access_token")
        if tokens:
            return tokens[0]

        # 2. Cabeçalho HTTP Authorization (Bearer <token>)
        headers = dict(self.scope.get("headers", []))
        auth_header = headers.get(b"authorization", b"").decode("utf-8")
        if auth_header.startswith("Bearer "):
            return auth_header.split(" ", 1)[1].strip()

        return None

    @database_sync_to_async
    def _autenticar_jwt(self, raw_token: str) -> Optional[User]:
        """Valida o token JWT através do SimpleJWT e devolve o utilizador ativo."""
        try:
            token = AccessToken(raw_token)
            user_id = token.get("user_id")
            if not user_id:
                return None
            return User.objects.filter(id=user_id, is_active=True).first()
        except (InvalidToken, TokenError, KeyError, Exception) as exc:
            logger.debug("Falha na validação do token JWT SimpleJWT: %s", exc)
            return None

    @database_sync_to_async
    def _verificar_autorizacao_pedido(
        self,
        user_id: int | str | uuid.UUID,
        pedido_id: str,
    ) -> tuple[bool, Optional[str], Optional[Estafeta]]:
        """
        Valida as permissões de acesso ao pedido de acordo com as regras de negócio:
        - Cliente do Pedido (autor da encomenda);
        - Parceiro Comercial (responsável legal/gestor da Loja);
        - Estafeta Atribuído (responsável logístico pela Entrega);
        - Administrador / Staff da plataforma.

        :return: Tuplo (autorizado: bool, papel: str, estafeta_obj: Optional[Estafeta])
        """
        try:
            pedido = (
                Pedido.objects.select_related("loja", "loja__responsavel", "cliente")
                .filter(id=pedido_id)
                .first()
            )
            if not pedido:
                logger.warning("Verificação de permissão falhou: Pedido %s não encontrado.", pedido_id)
                return False, None, None

            # 1. Cliente do Pedido
            if str(pedido.cliente_id) == str(user_id):
                return True, "cliente", None

            # 2. Parceiro Dono da Loja
            if pedido.loja and str(pedido.loja.responsavel_id) == str(user_id):
                return True, "parceiro", None

            # 3. Estafeta Atribuído à Entrega
            entrega = (
                Entrega.objects.select_related("estafeta", "estafeta__utilizador")
                .filter(pedido_id=pedido_id)
                .first()
            )
            if (
                entrega
                and entrega.estafeta
                and str(entrega.estafeta.utilizador_id) == str(user_id)
            ):
                return True, "estafeta", entrega.estafeta

            # 4. Administrador / Staff de Operações
            user = User.objects.filter(id=user_id).first()
            if user and (user.is_staff or user.is_superuser):
                return True, "staff", None

            return False, None, None

        except Exception as exc:
            logger.error(
                "Erro ao verificar permissão do utilizador %s no pedido %s: %s",
                user_id,
                pedido_id,
                exc,
            )
            return False, None, None

    @database_sync_to_async
    def _atualizar_geolocalizacao_estafeta(
        self,
        estafeta_id: uuid.UUID | str,
        pedido_id: str,
        lat: float,
        lng: float,
        heading: float,
        speed: float,
    ) -> None:
        """
        RN-094: Atualiza a posição geográfica PostGIS no modelo Estafeta
        e dispara o sinal 'estafeta_location_updated'.
        """
        try:
            agora = timezone.now()
            ponto_geom = Point(lng, lat, srid=4326)

            # Atualização atómica do campo ultima_geolocalizacao em PostGIS
            Estafeta.objects.filter(id=estafeta_id).update(
                ultima_geolocalizacao=ponto_geom,
            )

            # Emissão do sinal Django desacoplado para subsistemas interessados
            estafeta_location_updated.send(
                sender=Estafeta,
                estafeta_id=str(estafeta_id),
                pedido_id=pedido_id,
                latitude=lat,
                longitude=lng,
                heading=heading,
                speed=speed,
                timestamp=agora,
            )

        except Exception as exc:
            logger.error(
                "Erro ao atualizar geolocalização PostGIS do estafeta %s: %s",
                estafeta_id,
                exc,
            )

