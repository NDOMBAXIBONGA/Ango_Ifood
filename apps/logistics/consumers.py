"""
Consumidor WebSockets (Django Channels) para Rastreamento em Tempo Real do Estafeta ('logistics').
Implementa rigorosamente:
- RN-094: Rastreamento em tempo real do estafeta durante o transporte com transmissões a cada 5 segundos.
- Secção 12.1: Disparo do evento canónico 'delivery.location_updated' para todos os subscritores (Cliente e Loja).
- Autenticação e autorização via JWT na query string (Token Bearer / SimpleJWT).
- Atualização espacial PostGIS (PointField SRID 4326) da última geolocalização do estafeta.
- Gestão de grupos dedicados por pedido ('delivery_tracking_<uuid:pedido_id>').
"""
from __future__ import annotations

import json
import logging
import urllib.parse
import uuid
from typing import Any, Optional

from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer, AsyncWebsocketConsumer
from django.contrib.auth import get_user_model
from django.contrib.gis.geos import Point
from django.utils import timezone
from rest_framework_simplejwt.exceptions import InvalidToken, TokenError
from rest_framework_simplejwt.tokens import AccessToken

from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import EventoPedido, Pedido

logger = logging.getLogger(__name__)
User = get_user_model()


class DeliveryTrackingConsumer(AsyncWebsocketConsumer):
    """
    Consumer assíncrono para tracking GPS em tempo real entre Estafeta, Cliente e Parceiro Comercial.

    Fluxo de Conexão:
    1. O cliente, loja ou estafeta liga-se a `ws/delivery/tracking/<uuid:pedido_id>/?token=<jwt_access_token>`.
    2. Valida o token JWT e extrai o utilizador autenticado.
    3. Valida permissão RBAC sobre o `pedido_id` (Cliente autor, Dono da Loja, Estafeta atribuído ou Staff).
    4. Adiciona o canal ao grupo `delivery_tracking_<pedido_id>`.

    Fluxo de Transmissão de GPS (RN-094):
    1. O Estafeta envia via WebSocket a cada 5s um payload contendo:
       `{"latitude": -8.8383, "longitude": 13.2344, "heading": 120.5, "velocidade_kmh": 35.0}`
    2. O consumidor valida a identidade de estafeta atribuído ao pedido.
    3. Atualiza `ultima_geolocalizacao` no modelo `Estafeta` (PostGIS SRID 4326).
    4. Reencaminha imediatamente o evento `delivery.location_updated` (Secção 12.1) para o grupo.
    """

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.pedido_id: Optional[str] = None
        self.room_group_name: Optional[str] = None
        self.user: Optional[User] = None
        self.is_estafeta_do_pedido: bool = False
        self.estafeta_obj: Optional[Estafeta] = None

    # ==========================================================================
    # 1. CONEXÃO (CONNECT)
    # ==========================================================================

    async def connect(self) -> None:
        """
        Ao ligar:
        - Extrai e valida o `pedido_id` dos parâmetros de rota URL.
        - Valida a autenticação JWT a partir da query string.
        - Verifica as permissões de acesso ao pedido.
        - Junta o canal ao grupo exclusivo do pedido.
        """
        # Extrai o ID do pedido da rota URL
        raw_pedido_id = self.scope["url_route"]["kwargs"].get("pedido_id")
        try:
            self.pedido_id = str(uuid.UUID(str(raw_pedido_id)))
        except (ValueError, TypeError):
            logger.warning("Tentativa de conexão WebSocket com pedido_id inválido: %s", raw_pedido_id)
            await self.close(code=4000)  # Bad Request
            return

        self.room_group_name = f"delivery_tracking_{self.pedido_id}"

        # Autenticação via Token JWT na Query String (?token=...)
        token = self._extrair_token_query_string()
        if not token:
            logger.warning("Conexão WebSocket rejeitada: Ausência de token JWT para o pedido %s.", self.pedido_id)
            await self.close(code=4001)  # Unauthorized
            return

        self.user = await self._autenticar_jwt(token)
        if not self.user:
            logger.warning("Conexão WebSocket rejeitada: Token JWT inválido ou expirado para pedido %s.", self.pedido_id)
            await self.close(code=4001)  # Unauthorized
            return

        # Autorização: Valida se o utilizador tem direitos sobre este pedido
        tem_permissao, self.is_estafeta_do_pedido, self.estafeta_obj = await self._verificar_permissao_pedido(
            user=self.user,
            pedido_id=self.pedido_id,
        )
        if not tem_permissao:
            logger.warning(
                "Conexão WebSocket rejeitada: Utilizador %s não tem permissão para aceder ao pedido %s.",
                self.user.id,
                self.pedido_id,
            )
            await self.close(code=4003)  # Forbidden
            return

        # Junta o canal de comunicação ao grupo do pedido
        await self.channel_layer.group_add(
            self.room_group_name,
            self.channel_name,
        )

        await self.accept()

        logger.info(
            "WebSocket conectado com sucesso: Pedido %s | User %s | Papel Estafeta: %s | Canal %s",
            self.pedido_id,
            self.user.id,
            self.is_estafeta_do_pedido,
            self.channel_name,
        )

        # Envia estado inicial da entrega ao subscritor
        estado_inicial = await self._obter_estado_inicial_entrega(self.pedido_id)
        if estado_inicial:
            await self.send(
                text_data=json.dumps(
                    {
                        "event": "connection_established",
                        "pedido_id": self.pedido_id,
                        "usuario": str(self.user.id),
                        "papel": "estafeta" if self.is_estafeta_do_pedido else "observador",
                        "dados_iniciais": estado_inicial,
                        "timestamp": timezone.now().isoformat(),
                    }
                )
            )

    # ==========================================================================
    # 2. DESCONEXÃO (DISCONNECT)
    # ==========================================================================

    async def disconnect(self, close_code: int) -> None:
        """
        Ao desconectar:
        - Remove o canal do grupo exclusivo no channel layer.
        """
        if self.room_group_name:
            await self.channel_layer.group_discard(
                self.room_group_name,
                self.channel_name,
            )

        logger.info(
            "WebSocket desconectado: Pedido %s | User %s | Código de fecho: %s",
            self.pedido_id,
            getattr(self.user, "id", "Anon"),
            close_code,
        )

    # ==========================================================================
    # 3. RECEÇÃO DE MENSAGENS (RECEIVE) - TRANSMISSÃO GPS RN-094
    # ==========================================================================

    async def receive(self, text_data: Optional[str] = None, bytes_data: Optional[bytes] = None) -> None:
        """
        Recebe mensagens do cliente conectado.
        Se o ator for o Estafeta transmitindo coordenadas de GPS (RN-094):
        1. Valida latitude (-90 a 90) e longitude (-180 a 180).
        2. Atualiza a posição em PostGIS (`Point(lng, lat, srid=4326)`).
        3. Dispara o evento 'delivery.location_updated' (Secção 12.1) para o grupo Redis.
        """
        if not text_data:
            return

        try:
            payload = json.loads(text_data)
        except json.JSONDecodeError:
            await self.send(text_data=json.dumps({"error": "Formato JSON inválido."}))
            return

        tipo_acao = payload.get("action") or payload.get("event")

        # Heartbeat ping/pong
        if tipo_acao == "ping":
            await self.send(text_data=json.dumps({"event": "pong", "timestamp": timezone.now().isoformat()}))
            return

        # Processamento de atualização de localização (RN-094)
        if tipo_acao in ("update_location", "delivery.location_updated", None):
            # Apenas o estafeta oficialmente atribuído a esta corrida pode emitir coordenadas
            if not self.is_estafeta_do_pedido or not self.estafeta_obj:
                await self.send(
                    text_data=json.dumps(
                        {
                            "error": "Apenas o estafeta atribuído a este pedido tem autorização para emitir coordenadas GPS.",
                            "codigo": "PERMISSION_DENIED",
                        }
                    )
                )
                return

            lat = payload.get("latitude") or payload.get("lat")
            lng = payload.get("longitude") or payload.get("lng")
            heading = payload.get("heading") or payload.get("bearing", 0.0)
            velocidade_kmh = payload.get("velocidade_kmh") or payload.get("speed", 0.0)
            precisao_metros = payload.get("precisao_metros") or payload.get("accuracy", 5.0)

            if lat is None or lng is None:
                await self.send(
                    text_data=json.dumps(
                        {"error": "Campos 'latitude' e 'longitude' são obrigatórios.", "codigo": "MISSING_COORDINATES"}
                    )
                )
                return

            try:
                lat_float = float(lat)
                lng_float = float(lng)
            except (ValueError, TypeError):
                await self.send(text_data=json.dumps({"error": "Coordenadas numéricas inválidas."}))
                return

            # Validação dos limites geográficos padrão
            if not (-90.0 <= lat_float <= 90.0 and -180.0 <= lng_float <= 180.0):
                await self.send(text_data=json.dumps({"error": "Coordenadas fora dos limites do globo terrestre."}))
                return

            # Atualiza no banco de dados espacial PostGIS (RN-094)
            await self._persistir_geolocalizacao_estafeta(
                estafeta_id=self.estafeta_obj.id,
                lat=lat_float,
                lng=lng_float,
            )

            # Prepara o payload do evento canónico da Secção 12.1
            agora_iso = timezone.now().isoformat()
            evento_dados = {
                "event": "delivery.location_updated",
                "pedido_id": self.pedido_id,
                "estafeta_id": str(self.estafeta_obj.id),
                "estafeta_nome": self.user.nome if hasattr(self.user, "nome") else "Estafeta",
                "geolocalizacao": {
                    "latitude": lat_float,
                    "longitude": lng_float,
                },
                "heading": float(heading) if heading is not None else 0.0,
                "velocidade_kmh": float(velocidade_kmh) if velocidade_kmh is not None else 0.0,
                "precisao_metros": float(precisao_metros) if precisao_metros is not None else 5.0,
                "timestamp": agora_iso,
            }

            # Reencaminha instantaneamente para todos os membros do grupo (App Cliente e Portal Loja)
            await self.channel_layer.group_send(
                self.room_group_name,
                {
                    "type": "delivery_location_updated",
                    "data": evento_dados,
                },
            )

    # ==========================================================================
    # 4. HANDLERS DE DISPARO DO CHANNEL LAYER
    # ==========================================================================

    async def delivery_location_updated(self, event: dict[str, Any]) -> None:
        """
        Recebe o evento 'delivery.location_updated' do Channel Layer (Redis)
        e envia-o em formato JSON para o cliente WebSocket subscrito.
        """
        await self.send(text_data=json.dumps(event["data"]))

    async def delivery_status_changed(self, event: dict[str, Any]) -> None:
        """
        Handler opcional para notificações de avanço de estado da entrega (ex.: RECOLHIDO, EM_TRANSITO, ENTREGUE).
        """
        await self.send(text_data=json.dumps(event["data"]))

    # ==========================================================================
    # 5. MÉTODOS DE SUPORTE E BASE DE DADOS (SYNC TO ASYNC)
    # ==========================================================================

    def _extrair_token_query_string(self) -> Optional[str]:
        """Extrai o parâmetro 'token' da query string HTTP/WS da conexão."""
        query_string = self.scope.get("query_string", b"").decode("utf-8")
        query_params = urllib.parse.parse_qs(query_string)
        tokens = query_params.get("token", [])
        return tokens[0] if tokens else None

    @database_sync_to_async
    def _autenticar_jwt(self, raw_token: str) -> Optional[User]:
        """Valida o token JWT SimpleJWT e retorna o modelo de utilizador autenticado."""
        try:
            token = AccessToken(raw_token)
            user_id = token["user_id"]
            return User.objects.filter(id=user_id, is_active=True).first()
        except (InvalidToken, TokenError, KeyError, Exception) as exc:
            logger.debug("Falha na validação do token JWT no WebSocket: %s", exc)
            return None

    @database_sync_to_async
    def _verificar_permissao_pedido(
        self,
        user: User,
        pedido_id: str,
    ) -> tuple[bool, bool, Optional[Estafeta]]:
        """
        Valida se o utilizador autenticado tem autorização de acesso ao canal do pedido:
        - Cliente autor do pedido.
        - Dono/proprietário da loja comercial responsável.
        - Estafeta atribuído à entrega.
        - Administrador / Staff de suporte.
        Retorna: (tem_permissao, is_estafeta_do_pedido, estafeta_obj)
        """
        try:
            pedido = (
                Pedido.objects.select_related("loja", "loja__proprietario", "cliente")
                .get(pk=pedido_id)
            )
        except Pedido.DoesNotExist:
            return False, False, None

        # 1. Staff ou Administrador da Plataforma
        if user.is_staff or user.is_superuser:
            return True, False, None

        # 2. Cliente titular do pedido
        if str(pedido.cliente_id) == str(user.id):
            return True, False, None

        # 3. Parceiro comercial / Proprietário da loja
        if pedido.loja and pedido.loja.proprietario_id and str(pedido.loja.proprietario_id) == str(user.id):
            return True, False, None

        # 4. Estafeta atribuído à entrega deste pedido
        try:
            entrega = Entrega.objects.select_related("estafeta").get(pedido=pedido)
            if entrega.estafeta and str(entrega.estafeta.utilizador_id) == str(user.id):
                return True, True, entrega.estafeta
        except Entrega.DoesNotExist:
            pass

        return False, False, None

    @database_sync_to_async
    def _persistir_geolocalizacao_estafeta(
        self,
        estafeta_id: uuid.UUID,
        lat: float,
        lng: float,
    ) -> None:
        """
        RN-094: Atualiza a coordenada geográfica no campo `ultima_geolocalizacao`
        do modelo Estafeta usando PostGIS PointField (SRID 4326).
        Nota PostGIS: Point(x=longitude, y=latitude, srid=4326).
        """
        ponto_gps = Point(lng, lat, srid=4326)
        Estafeta.objects.filter(pk=estafeta_id).update(
            ultima_geolocalizacao=ponto_gps,
        )

        # RN-133: Auditoria contínua de telemetria e deteção de GPS Falso / Velocidade Impossível
        from apps.orders.fraud_engine import FraudRiskAssessmentEngine
        FraudRiskAssessmentEngine.analisar_velocidade_gps_estafeta(
            estafeta_id=estafeta_id,
            nova_latitude=lat,
            nova_longitude=lng,
        )

    @database_sync_to_async
    def _obter_estado_inicial_entrega(self, pedido_id: str) -> Optional[dict[str, Any]]:
        """Retorna os dados iniciais da entrega para envio ao subscritor que se conecta."""
        try:
            entrega = (
                Entrega.objects.select_related("estafeta", "estafeta__utilizador")
                .get(pedido_id=pedido_id)
            )
            ultima_pos = None
            if entrega.estafeta and entrega.estafeta.ultima_geolocalizacao:
                ponto = entrega.estafeta.ultima_geolocalizacao
                ultima_pos = {"latitude": ponto.y, "longitude": ponto.x}

            return {
                "entrega_id": str(entrega.id),
                "estado_entrega": entrega.estado_entrega,
                "distancia_metros": entrega.distancia_metros,
                "eta_timestamp": entrega.eta_timestamp.isoformat() if entrega.eta_timestamp else None,
                "estafeta": {
                    "id": str(entrega.estafeta.id) if entrega.estafeta else None,
                    "nome": entrega.estafeta.utilizador.nome if entrega.estafeta else None,
                    "tipo_veiculo": entrega.estafeta.tipo_veiculo if entrega.estafeta else None,
                    "ultima_geolocalizacao": ultima_pos,
                }
                if entrega.estafeta
                else None,
            }
        except Entrega.DoesNotExist:
            return None


class TrackingEntregaConsumer(AsyncJsonWebsocketConsumer):
    """
    Consumer WebSockets leve e em tempo real para rastreamento de entregas.
    Rota: ws/entrega/<str:pedido_id>/
    Transmite posições GPS do estafeta instantaneamente para o cliente na mesma sala.
    """

    async def connect(self):
        self.pedido_id = str(self.scope["url_route"]["kwargs"].get("pedido_id", "default"))
        self.room_group_name = f"entrega_{self.pedido_id}"

        # Entrar no grupo da entrega
        await self.channel_layer.group_add(self.room_group_name, self.channel_name)
        await self.accept()

        # Envia confirmação de conexão
        await self.send_json({
            "tipo": "conexao_estabelecida",
            "mensagem": f"Conectado à sala de rastreamento do pedido {self.pedido_id}",
            "sala": self.room_group_name,
        })

    async def disconnect(self, close_code):
        if hasattr(self, "room_group_name"):
            await self.channel_layer.group_discard(self.room_group_name, self.channel_name)

    async def receive_json(self, content):
        """
        Recebe pacote GPS enviado pelo app do estafeta:
        {"lat": -14.917, "lon": 13.492, "heading": 90.0, "velocidade": 30.5}
        """
        lat = content.get("lat") if content.get("lat") is not None else content.get("latitude")
        lon = (
            content.get("lon")
            if content.get("lon") is not None
            else (content.get("lng") or content.get("longitude"))
        )

        if lat is None or lon is None:
            await self.send_json({"erro": "Latitude ('lat') e longitude ('lon') são obrigatórias."})
            return

        try:
            lat = float(lat)
            lon = float(lon)
        except (ValueError, TypeError):
            await self.send_json({"erro": "Coordenadas com formato numérico inválido."})
            return

        heading = float(content.get("heading") or 0.0)
        velocidade = float(content.get("velocidade") or 0.0)

        # Transmite imediatamente para todos os clientes conectados na sala da entrega
        await self.channel_layer.group_send(
            self.room_group_name,
            {
                "type": "broadcast_posicao_estafeta",
                "lat": lat,
                "lon": lon,
                "heading": heading,
                "velocidade": velocidade,
                "timestamp": content.get("timestamp") or timezone.now().isoformat(),
            },
        )

    async def broadcast_posicao_estafeta(self, event):
        """
        Handler que entrega os dados atualizados aos WebSockets dos clientes e lojas na sala.
        """
        await self.send_json({
            "tipo": "posicao_atualizada",
            "lat": event["lat"],
            "lon": event["lon"],
            "heading": event.get("heading", 0.0),
            "velocidade": event.get("velocidade", 0.0),
            "timestamp": event.get("timestamp"),
        })

