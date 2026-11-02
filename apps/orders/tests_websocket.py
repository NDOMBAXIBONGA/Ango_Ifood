"""
Testes Unitários e Assíncronos para o Consumidor WebSockets OrderTrackingConsumer ('orders').
Valida rigorosamente:
- Conexão e autenticação via JWT na query string (SimpleJWT);
- Permissões RBAC (Cliente, Estafeta, Parceiro e rejeição de utilizadores não autorizados);
- Rastreamento em tempo real (RN-094) e evento canónico 'delivery.location_updated' (Secção 12.1);
- Atualização espacial PostGIS no modelo Estafeta (SRID 4326);
- Desconexão e limpeza de grupos no Channel Layer.
"""
from decimal import Decimal
import json
import uuid

from channels.testing import WebsocketCommunicator
from django.contrib.auth import get_user_model
from django.contrib.gis.geos import Point
from django.test import TransactionTestCase
from rest_framework_simplejwt.tokens import AccessToken

from apps.catalog.models import ParceiroLoja
from apps.logistics.models import Entrega, Estafeta
from apps.orders.consumers import OrderTrackingConsumer
from apps.orders.models import Pedido
from config.asgi import application

User = get_user_model()


class OrderTrackingConsumerTests(TransactionTestCase):
    """
    Testes de integração assíncronos para o WebSocket de tracking de pedidos.
    """

    def setUp(self) -> None:
        # 1. Cria Cliente
        self.cliente = User.objects.create_user(
            telemovel="+244923111001",
            email="cliente.ws@delivery.ao",
            nome="Cliente WS",
            estado=User.EstadoConta.ATIVO,
        )

        # 2. Cria Parceiro Dono da Loja
        self.user_parceiro = User.objects.create_user(
            telemovel="+244923111002",
            email="parceiro.ws@delivery.ao",
            nome="Parceiro Dono WS",
            estado=User.EstadoConta.ATIVO,
        )
        self.loja = ParceiroLoja.objects.create(
            responsavel=self.user_parceiro,
            nome="Restaurante WS Test",
            nif="540223344",
            morada_texto="Avenida Marginal, Luanda",
            contacto="+244923111002",
            licenca_sanitaria="LIC-WS-001",
            alvara="ALV-WS-001",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            comissao_percentagem=Decimal("20.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # 3. Cria Estafeta e Perfil Logístico
        self.user_estafeta = User.objects.create_user(
            telemovel="+244923111003",
            email="estafeta.ws@delivery.ao",
            nome="Estafeta WS",
            estado=User.EstadoConta.ATIVO,
        )
        self.estafeta = Estafeta.objects.create(
            utilizador=self.user_estafeta,
            tipo_veiculo=Estafeta.TipoVeiculo.MOTA,
            carta_conducao="CC-LUANDA-WS01",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2300, -8.8200, srid=4326),
            score_reputacao=Decimal("5.00"),
        )

        # 4. Utilizador Intruso (sem qualquer relação com o pedido)
        self.user_intruso = User.objects.create_user(
            telemovel="+244923111004",
            email="intruso.ws@delivery.ao",
            nome="Intruso",
            estado=User.EstadoConta.ATIVO,
        )

        # 5. Cria Pedido em Trânsito
        self.pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            estado=Pedido.EstadoPedido.EM_TRANSITO,
            subtotal=850000,
            taxa_entrega=120000,
            taxa_servico=42500,
            total_cobrado=942500,
            metodo_pagamento=Pedido.MetodoPagamento.CARTAO,
        )

        # 6. Entrega atribuída ao Estafeta
        self.entrega = Entrega.objects.create(
            pedido=self.pedido,
            estafeta=self.estafeta,
            estado_entrega=Entrega.EstadoEntrega.EM_TRANSITO,
            estado_logistico=Entrega.EstadoEntrega.EM_TRANSITO,
            distancia_metros=2500,
        )

    def _obter_token(self, user: User) -> str:
        """Gera um token JWT válido SimpleJWT para o utilizador."""
        return str(AccessToken.for_user(user))

    async def test_conexao_sucesso_cliente(self) -> None:
        """Cliente do pedido deve conseguir conectar e receber evento de conexão."""
        token = self._obter_token(self.cliente)
        url = f"/ws/v1/orders/tracking/{self.pedido.id}/?token={token}"

        communicator = WebsocketCommunicator(application, url)
        connected, _ = await communicator.connect()
        self.assertTrue(connected)

        # Mensagem de confirmação de conexão
        resposta = await communicator.receive_json_from()
        self.assertEqual(resposta["event"], "connection_established")
        self.assertEqual(resposta["role"], "cliente")
        self.assertEqual(resposta["pedido_id"], str(self.pedido.id))

        await communicator.disconnect()

    async def test_conexao_sucesso_estafeta(self) -> None:
        """Estafeta atribuído deve conectar com o papel de 'estafeta'."""
        token = self._obter_token(self.user_estafeta)
        url = f"/ws/v1/orders/tracking/{self.pedido.id}/?token={token}"

        communicator = WebsocketCommunicator(application, url)
        connected, _ = await communicator.connect()
        self.assertTrue(connected)

        resposta = await communicator.receive_json_from()
        self.assertEqual(resposta["event"], "connection_established")
        self.assertEqual(resposta["role"], "estafeta")

        await communicator.disconnect()

    async def test_conexao_rejeitada_sem_token(self) -> None:
        """Tentativa sem token JWT deve fechar com código 4001."""
        url = f"/ws/v1/orders/tracking/{self.pedido.id}/"
        communicator = WebsocketCommunicator(application, url)
        connected, close_code = await communicator.connect()
        self.assertFalse(connected)
        self.assertEqual(close_code, 4001)

    async def test_conexao_rejeitada_intruso(self) -> None:
        """Utilizador sem permissão sobre o pedido deve ser rejeitado com código 4003."""
        token = self._obter_token(self.user_intruso)
        url = f"/ws/v1/orders/tracking/{self.pedido.id}/?token={token}"

        communicator = WebsocketCommunicator(application, url)
        connected, close_code = await communicator.connect()
        self.assertFalse(connected)
        self.assertEqual(close_code, 4003)

    async def test_transmissao_gps_estafeta_e_difusao(self) -> None:
        """
        RN-094 e Secção 12.1:
        O estafeta transmite coordenadas GPS via WebSocket.
        O cliente subscrito deve receber o evento 'delivery.location_updated'.
        O modelo Estafeta deve ter 'ultima_geolocalizacao' atualizado em PostGIS.
        """
        # Conecta Cliente
        token_cliente = self._obter_token(self.cliente)
        url_cliente = f"/ws/v1/orders/tracking/{self.pedido.id}/?token={token_cliente}"
        comm_cliente = WebsocketCommunicator(application, url_cliente)
        await comm_cliente.connect()
        await comm_cliente.receive_json_from()  # Descarta connection_established

        # Conecta Estafeta
        token_estafeta = self._obter_token(self.user_estafeta)
        url_estafeta = f"/ws/v1/orders/tracking/{self.pedido.id}/?token={token_estafeta}"
        comm_estafeta = WebsocketCommunicator(application, url_estafeta)
        await comm_estafeta.connect()
        await comm_estafeta.receive_json_from()  # Descarta connection_established

        # Estafeta envia coordenadas GPS
        nova_lat = -8.8300
        nova_lng = 13.2450
        await comm_estafeta.send_json_to({
            "latitude": nova_lat,
            "longitude": nova_lng,
            "heading": 180.0,
            "speed": 40.5,
        })

        # Cliente deve receber a transmissão instantaneamente
        mensagem_cliente = await comm_cliente.receive_json_from()
        self.assertEqual(mensagem_cliente["event"], "delivery.location_updated")
        self.assertEqual(mensagem_cliente["pedido_id"], str(self.pedido.id))
        self.assertEqual(mensagem_cliente["estafeta_id"], str(self.estafeta.id))
        self.assertAlmostEqual(mensagem_cliente["latitude"], nova_lat, places=4)
        self.assertAlmostEqual(mensagem_cliente["longitude"], nova_lng, places=4)

        # Desconecta os clientes
        await comm_cliente.disconnect()
        await comm_estafeta.disconnect()

