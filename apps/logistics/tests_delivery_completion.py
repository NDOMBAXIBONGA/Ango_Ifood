"""
Testes Unitários e de Integração para Verificação de PIN e Ausência de Cliente ('logistics').
Valida as regras de negócio:
- RN-095: Verificação criptográfica do PIN de 4 dígitos e registo de prova GPS PostGIS;
- RN-096: Tolerância de espera de 7 minutos (420s) antes de permitir reporte de ausência;
- RN-097: Encerramento como FALHA_ENTREGA por culpa do cliente, retenção de valor e pagamento ao estafeta.
"""
from decimal import Decimal
import uuid

from django.contrib.auth import get_user_model
from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import ParceiroLoja
from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import EventoPedido, Pedido

User = get_user_model()


class DeliveryPinAndAbsenceTests(TestCase):
    """Testa os fluxos de sucesso e exceção no encerramento da última milha."""

    def setUp(self) -> None:
        self.client = APIClient()

        # 1. Utilizador Cliente
        self.cliente = User.objects.create_user(
            telemovel="+244923111001",
            email="cliente.entrega@delivery.ao",
            nome="Cliente Prova",
            estado=User.EstadoConta.ATIVO,
        )

        # 2. Utilizador e Perfil de Estafeta
        self.user_estafeta = User.objects.create_user(
            telemovel="+244923111002",
            email="estafeta.entrega@delivery.ao",
            nome="Estafeta Prova",
            estado=User.EstadoConta.ATIVO,
        )
        self.estafeta = Estafeta.objects.create(
            utilizador=self.user_estafeta,
            tipo_veiculo=Estafeta.TipoVeiculo.MOTA,
            carta_conducao="CC-LUANDA-TEST",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            saldo_carteira=0,
        )

        # 3. Loja Parceira
        self.loja = ParceiroLoja.objects.create(
            responsavel=self.cliente,
            nome="Restaurante Teste",
            nif="540998877",
            morada_texto="Rua Direita de Luanda",
            contacto="+244923111000",
            licenca_sanitaria="LIC-TEST",
            alvara="ALV-TEST",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            comissao_percentagem=Decimal("20.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # 4. Pedido em Trânsito
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

        # 5. Entrega associada
        self.entrega = Entrega.objects.create(
            pedido=self.pedido,
            estafeta=self.estafeta,
            estado_entrega=Entrega.EstadoEntrega.EM_TRANSITO,
            estado_logistico=Entrega.EstadoEntrega.EM_TRANSITO,
            pin_entrega="4819",
        )

        # Autentica cliente de testes como o estafeta condutor
        self.client.force_authenticate(user=self.user_estafeta)

    def test_verificar_pin_sucesso_rn095(self) -> None:
        """Cenário A: PIN correto encerra entrega com sucesso (RN-095)."""
        url = reverse("logistics:delivery-verify-pin")
        payload = {
            "pedido_id": str(self.pedido.id),
            "pin_introduzido": "4819",
            "latitude": -8.8150,
            "longitude": 13.2350,
        }

        response = self.client.post(url, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertTrue(response.data["sucesso"])
        self.assertTrue(response.data["pin_validado"])

        # Valida atualização do Pedido e Entrega
        self.pedido.refresh_from_db()
        self.entrega.refresh_from_db()

        self.assertEqual(self.pedido.estado, Pedido.EstadoPedido.ENTREGUE)
        self.assertEqual(self.entrega.estado_entrega, Entrega.EstadoEntrega.ENTREGUE)
        self.assertIsNotNone(self.entrega.prova_geolocalizacao)

        # Valida emissão de evento de auditoria
        evento = EventoPedido.objects.filter(
            pedido=self.pedido,
            tipo_evento=EventoPedido.TipoEvento.ORDER_DELIVERED,
        ).first()
        self.assertIsNotNone(evento)

    def test_verificar_pin_invalido_rejeita(self) -> None:
        """PIN incorreto retorna HTTP 400 com tentativas restantes."""
        url = reverse("logistics:delivery-verify-pin")
        payload = {
            "pedido_id": str(self.pedido.id),
            "pin_introduzido": "0000",
        }

        response = self.client.post(url, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["codigo"], "INVALID_PIN")
        self.assertEqual(response.data["tentativas_restantes"], 4)

    def test_reportar_ausencia_bloqueada_antes_dos_7_minutos_rn096(self) -> None:
        """Tentar reportar ausência antes de cumprir 7 minutos deve ser rejeitado (RN-096)."""
        # Estafeta marca chegada agora
        url_arrive = reverse("logistics:delivery-arrive")
        self.client.post(url_arrive, {"pedido_id": str(self.pedido.id)}, format="json")

        # Tenta imediatamente reportar ausência
        url_absence = reverse("logistics:delivery-report-absence")
        payload = {
            "pedido_id": str(self.pedido.id),
            "latitude": -8.8150,
            "longitude": 13.2350,
            "tentativas_contacto": 2,
        }
        response = self.client.post(url_absence, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["codigo"], "WAIT_TIME_NOT_MET")

    def test_reportar_ausencia_sucesso_apos_7_minutos_rn097(self) -> None:
        """Cenário B: Após 7 minutos de espera, permite FALHA_ENTREGA e credita estafeta (RN-097)."""
        # Simula chegada há mais de 430 segundos (7m10s)
        cache_key = f"delivery:arrived_at:{self.pedido.id}"
        passado_ts = int(timezone.now().timestamp()) - 430
        cache.set(cache_key, passado_ts, timeout=7200)

        url_absence = reverse("logistics:delivery-report-absence")
        payload = {
            "pedido_id": str(self.pedido.id),
            "latitude": -8.8150,
            "longitude": 13.2350,
            "tentativas_contacto": 2,
            "motivo": "Cliente não atendeu o interfone.",
        }

        response = self.client.post(url_absence, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status_encerramento"], "FALHA_ENTREGA_CLIENTE_AUSENTE")

        self.pedido.refresh_from_db()
        self.entrega.refresh_from_db()
        self.estafeta.refresh_from_db()

        self.assertEqual(self.pedido.estado, Pedido.EstadoPedido.FALHA_ENTREGA)
        self.assertEqual(self.entrega.estado_entrega, Entrega.EstadoEntrega.FALHOU)
        # Remuneração da entrega creditada na carteira do estafeta (120000 cêntimos)
        self.assertEqual(self.estafeta.saldo_carteira, 120000)

