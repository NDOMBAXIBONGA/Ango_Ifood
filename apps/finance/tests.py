"""
Testes unitários para o serviço PaymentGatewayIntegrationService ('finance').
Cobre as regras:
- RN-065: Meios de pagamento homologados;
- RN-066: Ciclo transacional (Pré-autorização, Captura definitiva e Cancelamento);
- RN-067: Bloqueio temporário após 3 tentativas falhadas consecutivas;
- RN-068: Tokenização opaca e conformidade estrita com PCI DSS;
- RN-070: Estorno e cancelamento de pré-autorização;
- RN-073: Reconciliação financeira diária e auditoria imutável.
"""
import uuid
from decimal import Decimal

from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from apps.accounts.models import CustomUser
from apps.catalog.models import ParceiroLoja
from apps.finance.models import EventoPedido
from apps.finance.payment_service import (
    PaymentDeclinedException,
    PaymentGatewayIntegrationService,
    PaymentMethodBlockedException,
    PaymentPreAuthorizationNotFoundException,
    PaymentTokenizationException,
)
from apps.orders.models import Pedido


class PaymentGatewayIntegrationServiceTests(TestCase):
    """Testes de conformidade PCI DSS e ciclo de vida de transações."""

    def setUp(self) -> None:
        cache.clear()

        # 1. Utilizador Cliente
        self.cliente = CustomUser.objects.create_user(
            telemovel="+244923999111",
            email="cliente.pci@delivery.local",
            nome="Cliente PCI DSS",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # 2. Loja Parceira
        self.loja = ParceiroLoja.objects.create(
            nome="Loja Pagamentos Teste",
            nif="500999888",
            morada_texto="Rua da Moeda 10, Luanda",
            contacto="+244923000888",
            licenca_sanitaria="LIC-PAG-001",
            alvara="ALV-PAG-001",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # 3. Pedido em Estado CRIADO
        self.pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            estado=Pedido.EstadoPedido.CRIADO,
            subtotal=100000,
            taxa_entrega=15000,
            taxa_servico=5000,
            total_cobrado=120000,  # 1.200 Kz em unidades mínimas inteiras
            metodo_pagamento=Pedido.MetodoPagamento.CARTAO,
        )

        # Dados válidos de cartão de teste (Visa fictício válido no algoritmo de Luhn)
        self.dados_cartao_valido = {
            "numero_cartao": "4000001234567899",  # passa em Luhn
            "nome_titular": "CLIENTE TESTE PCI",
            "mes_expiracao": 12,
            "ano_expiracao": timezone.now().year + 2,
            "cvv": "123",
        }

    # =========================================================================
    # 1. TESTES DE TOKENIZAÇÃO E CONFORMIDADE PCI DSS (RN-068)
    # =========================================================================

    def test_tokenizacao_sucesso_sem_persistir_dados_sensiveis(self) -> None:
        """RN-068: Tokeniza o cartão e retorna token opaco com máscara segura."""
        resultado = PaymentGatewayIntegrationService.criar_token_cartao(self.dados_cartao_valido)

        self.assertIn("payment_token", resultado)
        self.assertTrue(resultado["payment_token"].startswith("tok_visa_"))
        self.assertEqual(resultado["ultimos_4"], "7899")
        self.assertEqual(resultado["mascara"], "**** **** **** 7899")
        self.assertEqual(resultado["bandeira"], "VISA")
        self.assertEqual(resultado["status"], "TOKENIZED")

    def test_tokenizacao_falha_com_numero_invalido_luhn(self) -> None:
        """RN-068: Rejeita cartão com número inválido no algoritmo de Luhn."""
        dados = dict(self.dados_cartao_valido)
        dados["numero_cartao"] = "4000001234567890"  # Dígito de controlo inválido

        with self.assertRaises(PaymentTokenizationException) as ctx:
            PaymentGatewayIntegrationService.criar_token_cartao(dados)

        self.assertIn("Luhn", str(ctx.exception))

    def test_tokenizacao_falha_com_cartao_expirado(self) -> None:
        """RN-068: Rejeita cartão expirado."""
        dados = dict(self.dados_cartao_valido)
        dados["ano_expiracao"] = timezone.now().year - 1

        with self.assertRaises(PaymentTokenizationException) as ctx:
            PaymentGatewayIntegrationService.criar_token_cartao(dados)

        self.assertIn("expirado", str(ctx.exception))

    # =========================================================================
    # 2. TESTES DE PRÉ-AUTORIZAÇÃO (RN-066)
    # =========================================================================

    def test_executar_pre_autorizacao_sucesso(self) -> None:
        """
        RN-066: Executa pré-autorização com sucesso, transita pedido para 'PAGAMENTO',
        salva metadados em Redis e emite evento imutável 'payment.authorized'.
        """
        token_info = PaymentGatewayIntegrationService.criar_token_cartao(self.dados_cartao_valido)
        token = token_info["payment_token"]

        resultado = PaymentGatewayIntegrationService.executar_pre_autorizacao(
            pedido_id=self.pedido.id,
            payment_token=token,
        )

        self.assertEqual(resultado["status"], "AUTHORIZED")
        self.assertEqual(resultado["valor_autorizado"], 120000)
        self.assertTrue(resultado["gateway_transaction_id"].startswith("gtw_auth_"))

        # Verifica transição na máquina de estados OMS
        self.pedido.refresh_from_db()
        self.assertEqual(self.pedido.estado, Pedido.EstadoPedido.PAGAMENTO)

        # Verifica registo em cache Redis
        pre_auth_cache = cache.get(f"payment:pre_auth:{self.pedido.id}")
        self.assertIsNotNone(pre_auth_cache)
        self.assertEqual(pre_auth_cache["status"], "AUTHORIZED")
        self.assertEqual(pre_auth_cache["valor_centimos"], 120000)

        # Verifica emissão do evento imutável de auditoria
        evento = EventoPedido.objects.filter(
            pedido=self.pedido,
            tipo_evento=EventoPedido.TipoEvento.PAYMENT_AUTHORIZED,
        ).first()
        self.assertIsNotNone(evento)
        self.assertEqual(evento.autor, "GATEWAY:SISTEMA_PAGAMENTOS")
        self.assertEqual(evento.dados_adicionais["status"], "AUTHORIZED")

    # =========================================================================
    # 3. TESTES DE BLOQUEIO POR TENTATIVAS (RN-067)
    # =========================================================================

    def test_rn067_bloqueio_apos_3_falhas_consecutivas(self) -> None:
        """
        RN-067: Após 3 recusas consecutivas, bloqueia temporariamente o método
        e lança PaymentMethodBlockedException.
        """
        token_recusado = "tok_visa_declined_12345"

        # 1.ª Falha
        with self.assertRaises(PaymentDeclinedException):
            PaymentGatewayIntegrationService.executar_pre_autorizacao(
                pedido_id=self.pedido.id,
                payment_token=token_recusado,
            )

        # 2.ª Falha
        with self.assertRaises(PaymentDeclinedException):
            PaymentGatewayIntegrationService.executar_pre_autorizacao(
                pedido_id=self.pedido.id,
                payment_token=token_recusado,
            )

        # 3.ª Falha -> Dispara Bloqueio Temporário
        with self.assertRaises(PaymentMethodBlockedException) as ctx:
            PaymentGatewayIntegrationService.executar_pre_autorizacao(
                pedido_id=self.pedido.id,
                payment_token=token_recusado,
            )

        self.assertEqual(ctx.exception.codigo, "RN-067_PAYMENT_METHOD_BLOCKED")

        # 4.ª Tentativa com método bloqueado -> Barra imediatamente sem contactar gateway
        with self.assertRaises(PaymentMethodBlockedException) as ctx2:
            PaymentGatewayIntegrationService.executar_pre_autorizacao(
                pedido_id=self.pedido.id,
                payment_token=token_recusado,
            )
        self.assertIn("temporariamente bloqueado", str(ctx2.exception))

    # =========================================================================
    # 4. TESTES DE CAPTURA DEFINITIVA (RN-066, RN-073)
    # =========================================================================

    def test_captura_definitiva_apos_pre_autorizacao(self) -> None:
        """
        RN-066: Efetua captura final, atualiza Redis para 'CAPTURED' e emite
        evento imutável 'payment.captured'.
        """
        token_info = PaymentGatewayIntegrationService.criar_token_cartao(self.dados_cartao_valido)
        PaymentGatewayIntegrationService.executar_pre_autorizacao(
            pedido_id=self.pedido.id,
            payment_token=token_info["payment_token"],
        )

        res_captura = PaymentGatewayIntegrationService.capturar_pagamento_final(
            pedido_id=self.pedido.id,
        )

        self.assertEqual(res_captura["status"], "CAPTURED")
        self.assertEqual(res_captura["valor_capturado"], 120000)

        # Verifica cache Redis atualizada
        pre_auth_cache = cache.get(f"payment:pre_auth:{self.pedido.id}")
        self.assertEqual(pre_auth_cache["status"], "CAPTURED")

        # Verifica emissão do evento imutável
        evento_cap = EventoPedido.objects.filter(
            pedido=self.pedido,
            tipo_evento=EventoPedido.TipoEvento.PAYMENT_CAPTURED,
        ).first()
        self.assertIsNotNone(evento_cap)
        self.assertEqual(evento_cap.dados_adicionais["status"], "CAPTURED")

    def test_captura_sem_pre_autorizacao_lanca_excecao(self) -> None:
        """RN-066: Tentativa de captura sem autorização prévia falha."""
        outro_pedido_id = uuid.uuid4()
        with self.assertRaises(PaymentPreAuthorizationNotFoundException):
            PaymentGatewayIntegrationService.capturar_pagamento_final(
                pedido_id=outro_pedido_id,
            )

    # =========================================================================
    # 5. TESTES DE CANCELAMENTO / LIBERTAÇÃO DE FUNDOS (RN-066, RN-070)
    # =========================================================================

    def test_cancelar_pre_autorizacao_sucesso(self) -> None:
        """
        RN-066 e RN-070: Desfaz bloqueio no cartão, atualiza Redis para 'VOIDED'
        e emite evento de auditoria 'payment.refunded'.
        """
        token_info = PaymentGatewayIntegrationService.criar_token_cartao(self.dados_cartao_valido)
        PaymentGatewayIntegrationService.executar_pre_autorizacao(
            pedido_id=self.pedido.id,
            payment_token=token_info["payment_token"],
        )

        res_cancel = PaymentGatewayIntegrationService.cancelar_pre_autorizacao(
            pedido_id=self.pedido.id,
            motivo="Cancelamento pelo cliente antes da confeção",
        )

        self.assertEqual(res_cancel["status"], "VOIDED")
        self.assertEqual(res_cancel["valor_libertado"], 120000)

        # Verifica em cache Redis
        pre_auth_cache = cache.get(f"payment:pre_auth:{self.pedido.id}")
        self.assertEqual(pre_auth_cache["status"], "VOIDED")

        # Verifica evento imutável
        evento_void = EventoPedido.objects.filter(
            pedido=self.pedido,
            tipo_evento=EventoPedido.TipoEvento.PAYMENT_REFUNDED,
        ).first()
        self.assertIsNotNone(evento_void)
        self.assertEqual(evento_void.dados_adicionais["status"], "VOIDED")
