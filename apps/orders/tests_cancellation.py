"""
Testes unitários exaustivos para o OrderCancellationProcessor ('orders').
Cobre com precisão matemática a Tabela da Secção 6.10 e as regras RN-102 a RN-109:
- Cenário 1: Cancelamento em AGUARDA_PARCEIRO pelo cliente (100% reembolso - RN-102);
- Cenário 2: Cancelamento em ACEITE pelo cliente (< 60s vs > 60s com retenção da taxa de serviço);
- Cenário 3: Cancelamento em EM_PREPARACAO pelo cliente (Reembolso parcial, subtotal retido);
- Cenário 4: Cancelamento em PRONTO pelo cliente (Reembolso 0%, corrida integral ao estafeta);
- Cenário 5: Cancelamento pelo Parceiro (Penalização fixa, perda de reputação e alerta > 5% - RN-104);
- Cenário 6: Cancelamento por Timeout do Sistema (Reembolso integral + Cupão de compensação - RN-106);
- Auditoria Contábil de Dupla Entrada no Livro Razão Ledger (RN-108, RN-150).
"""
import uuid
from decimal import Decimal

from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from apps.accounts.models import CustomUser
from apps.catalog.models import ParceiroLoja
from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.logistics.models import Entrega, Estafeta
from apps.orders.cancellation_service import OrderCancellationProcessor
from apps.orders.models import Pedido
from apps.promotions.models import CupaoDesconto


class OrderCancellationProcessorTests(TestCase):
    """Testes de conformidade financeira e transacional da Tabela da Secção 6.10."""

    def setUp(self) -> None:
        cache.clear()

        # 1. Utilizador Cliente
        self.cliente = CustomUser.objects.create_user(
            telemovel="+244923777001",
            email="cliente.cancel@delivery.local",
            nome="Cliente Cancelamento",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # 2. Loja Parceira com comissão de 20%
        self.loja = ParceiroLoja.objects.create(
            nome="Pizzaria Cancelamentos",
            nif="500666555",
            morada_texto="Rua da Amizade 10, Luanda",
            contacto="+244923000666",
            licenca_sanitaria="LIC-CANC-001",
            alvara="ALV-CANC-001",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            comissao_percentagem=Decimal("20.00"),
            score_reputacao=Decimal("5.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # 3. Estafeta
        self.user_estafeta = CustomUser.objects.create_user(
            telemovel="+244923777002",
            email="estafeta.cancel@delivery.local",
            nome="Estafeta Cancelamento",
            estado=CustomUser.EstadoConta.ATIVO,
        )
        self.estafeta = Estafeta.objects.create(
            utilizador=self.user_estafeta,
            tipo_veiculo=Estafeta.TipoVeiculo.MOTA,
            carta_conducao="CC-CANC-001",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2345, -8.8150, srid=4326),
            saldo_carteira=0,
        )

    def _criar_pedido_com_entrega(self, estado_pedido: str, estado_entrega: str | None = None) -> Pedido:
        """Helper para instanciar pedido e entrega sincronizados."""
        pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            estado=estado_pedido,
            subtotal=100000,          # 1.000 Kz
            taxa_entrega=20000,       # 200 Kz
            taxa_servico=5000,        # 50 Kz
            taxa_pequeno_pedido=0,
            gorjeta_estafeta=5000,    # 50 Kz
            total_cobrado=130000,     # 1.300 Kz
        )

        if estado_entrega:
            Entrega.objects.create(
                pedido=pedido,
                estafeta=self.estafeta,
                estado_entrega=estado_entrega,
                estado_logistico=estado_entrega,
                distancia_metros=2500,
            )

        return pedido

    # =========================================================================
    # CENÁRIO 1: AGUARDA_PARCEIRO (RN-102)
    # =========================================================================

    def test_cenario_1_cancelamento_em_aguarda_parceiro_cliente(self) -> None:
        """RN-102: Em AGUARDA_PARCEIRO, cliente recebe 100% de reembolso sem custos."""
        pedido = self._criar_pedido_com_entrega(Pedido.EstadoPedido.AGUARDA_PARCEIRO)

        res = OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Cliente",
            motivo="Desistência antes da resposta da loja",
        )

        self.assertEqual(res["novo_estado"], Pedido.EstadoPedido.CANCELADO)
        self.assertEqual(res["reembolso_cliente"], 130000)
        self.assertEqual(res["pagamento_parceiro"], 0)
        self.assertEqual(res["pagamento_estafeta"], 0)
        self.assertEqual(res["retencao_taxa_servico"], 0)

        # Valida lançamento contábil no Ledger (PLATAFORMA -> CLIENTE)
        lancamentos = LivroRazaoLedger.objects.filter(referencia_pedido=pedido)
        self.assertEqual(lancamentos.count(), 1)
        l_cli = lancamentos.first()
        self.assertEqual(l_cli.conta_origem, LivroRazaoLedger.ContaContabil.PLATAFORMA)
        self.assertEqual(l_cli.conta_destino, LivroRazaoLedger.ContaContabil.CLIENTE)
        self.assertEqual(l_cli.debito, 130000)
        self.assertEqual(l_cli.credito, 130000)

    # =========================================================================
    # CENÁRIO 2: ACEITE (ANTES DE PREPARAR)
    # =========================================================================

    def test_cenario_2a_cancelamento_em_aceite_nos_primeiros_60s(self) -> None:
        """Secção 6.10: Em ACEITE nos primeiros 60s, cliente recebe 100% de reembolso."""
        pedido = self._criar_pedido_com_entrega(Pedido.EstadoPedido.ACEITE)

        res = OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Cliente",
            motivo="Cancelamento imediato após aceite",
        )

        self.assertEqual(res["dentro_janela_60s"], True)
        self.assertEqual(res["reembolso_cliente"], 130000)
        self.assertEqual(res["pagamento_parceiro"], 0)
        self.assertEqual(res["retencao_taxa_servico"], 0)

    def test_cenario_2b_cancelamento_em_aceite_apos_60s(self) -> None:
        """
        Secção 6.10: Em ACEITE após 60s, retém a taxa de serviço (5.000).
        Reembolso ao cliente = Total - taxa_servico = 125.000.
        Estafeta a caminho recebe compensação mínima.
        """
        pedido = self._criar_pedido_com_entrega(
            Pedido.EstadoPedido.ACEITE,
            estado_entrega=Entrega.EstadoEntrega.ATRIBUIDO,
        )

        # Simula criação há 120 segundos
        pedido.data_criacao = timezone.now() - timezone.timedelta(seconds=120)
        pedido.save(update_fields=["data_criacao"])

        res = OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Cliente",
            motivo="Mudança de planos após mais de 60s",
        )

        self.assertEqual(res["dentro_janela_60s"], False)
        self.assertEqual(res["retencao_taxa_servico"], 5000)
        self.assertEqual(res["reembolso_cliente"], 125000)
        self.assertEqual(res["pagamento_parceiro"], 0)
        self.assertGreater(res["pagamento_estafeta"], 0)

    # =========================================================================
    # CENÁRIO 3: EM_PREPARACAO (RN-103)
    # =========================================================================

    def test_cenario_3_cancelamento_em_preparacao_cliente(self) -> None:
        """
        RN-103: Em preparação, cliente recebe reembolso parcial (retém subtotal de 100.000).
        Reembolso = 130.000 - 100.000 = 30.000 (taxa entrega + gorjeta).
        Parceiro recebe Subtotal líquido de 20% de comissão = 80.000.
        Estafeta recebe compensação se atribuído.
        """
        pedido = self._criar_pedido_com_entrega(
            Pedido.EstadoPedido.EM_PREPARACAO,
            estado_entrega=Entrega.EstadoEntrega.ATRIBUIDO,
        )

        res = OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Cliente",
            motivo="Demora na cozinha",
        )

        self.assertEqual(res["reembolso_cliente"], 30000)
        self.assertEqual(res["pagamento_parceiro"], 80000)  # 100.000 - 20%
        self.assertEqual(res["comissao_plataforma"], 20000)
        self.assertGreater(res["pagamento_estafeta"], 0)

        # Verifica crédito no saldo de carteira do estafeta
        self.estafeta.refresh_from_db()
        self.assertEqual(self.estafeta.saldo_carteira, res["pagamento_estafeta"])

    # =========================================================================
    # CENÁRIO 4: PRONTO OU RECOLHIDO
    # =========================================================================

    def test_cenario_4_cancelamento_em_pronto_cliente(self) -> None:
        """
        Secção 6.10: Em PRONTO, cliente recebe 0% de reembolso.
        Parceiro recebe valor total dos produtos líquido (80.000).
        Estafeta recebe valor integral da corrida (taxa_entrega 20.000 + gorjeta 5.000 = 25.000).
        """
        pedido = self._criar_pedido_com_entrega(
            Pedido.EstadoPedido.PRONTO,
            estado_entrega=Entrega.EstadoEntrega.ATRIBUIDO,
        )

        res = OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Cliente",
            motivo="Cliente desistiu com a comida pronta",
        )

        self.assertEqual(res["reembolso_cliente"], 0)
        self.assertEqual(res["pagamento_parceiro"], 80000)
        self.assertEqual(res["pagamento_estafeta"], 25000)  # 20.000 + 5.000

    # =========================================================================
    # CENÁRIO 5: CANCELAMENTO PELO PARCEIRO (RN-104)
    # =========================================================================

    def test_cenario_5_cancelamento_pelo_parceiro(self) -> None:
        """
        RN-104: Quando o parceiro cancela:
        - Cliente recebe 100% de reembolso (130.000);
        - Parceiro sofre penalização fixa (150.000 = 1.500 Kz);
        - Score de reputação reduz em -0.25 (5.00 -> 4.75);
        - Estafeta recebe compensação se a caminho.
        """
        pedido = self._criar_pedido_com_entrega(
            Pedido.EstadoPedido.ACEITE,
            estado_entrega=Entrega.EstadoEntrega.ATRIBUIDO,
        )

        res = OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Parceiro",
            motivo="Falta de ingredientes essenciais",
        )

        self.assertEqual(res["reembolso_cliente"], 130000)
        self.assertEqual(res["pagamento_parceiro"], 0)
        self.assertEqual(res["penalizacao_parceiro"], 150000)
        self.assertEqual(Decimal(res["novo_score_parceiro"]), Decimal("4.75"))

        # Valida lançamento contábil de penalização (PARCEIRO -> RETENCOES)
        lanc_pen = LivroRazaoLedger.objects.filter(
            referencia_pedido=pedido,
            conta_origem=LivroRazaoLedger.ContaContabil.PARCEIRO,
            conta_destino=LivroRazaoLedger.ContaContabil.RETENCOES,
        ).first()
        self.assertIsNotNone(lanc_pen)
        self.assertEqual(lanc_pen.debito, 150000)
        self.assertEqual(lanc_pen.credito, 150000)

    # =========================================================================
    # CENÁRIO 6: CANCELAMENTO POR TIMEOUT DO SISTEMA (RN-106)
    # =========================================================================

    def test_cenario_6_cancelamento_timeout_sem_estafeta(self) -> None:
        """
        RN-106: Cancelamento por timeout do sistema (sem estafeta):
        - 100% de reembolso ao cliente (130.000);
        - Atribuição de cupão de compensação promocional financiado pela plataforma;
        - Parceiro recebe pelos produtos confecionados (80.000) absorvido pela plataforma;
        - Estafeta sem efeito (0).
        """
        pedido = self._criar_pedido_com_entrega(Pedido.EstadoPedido.PRONTO)

        res = OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Sistema",
            motivo="RN-106: Timeout por escassez de estafetas",
        )

        self.assertEqual(res["reembolso_cliente"], 130000)
        self.assertEqual(res["pagamento_parceiro"], 80000)
        self.assertEqual(res["pagamento_estafeta"], 0)
        self.assertIsNotNone(res["cupao_compensacao_codigo"])

        # Verifica se o cupão promocional foi criado no banco
        cupao = CupaoDesconto.objects.filter(codigo=res["cupao_compensacao_codigo"]).first()
        self.assertIsNotNone(cupao)
        self.assertEqual(cupao.financiador, CupaoDesconto.FinanciadorCupao.PLATAFORMA)

    # =========================================================================
    # AUDITORIA E EVENTO IMUTÁVEL (SECÇÃO 5.2, 12.1)
    # =========================================================================

    def test_evento_order_cancelled_gerado_com_metadados(self) -> None:
        """Verifica a geração do evento imutável order.cancelled."""
        pedido = self._criar_pedido_com_entrega(Pedido.EstadoPedido.AGUARDA_PARCEIRO)

        OrderCancellationProcessor.processar_cancelamento(
            pedido_id=pedido.id,
            quem_cancela="Cliente",
            motivo="Desistência voluntária",
        )

        evento = EventoPedido.objects.filter(
            pedido=pedido,
            tipo_evento=EventoPedido.TipoEvento.ORDER_CANCELLED,
        ).first()

        self.assertIsNotNone(evento)
        self.assertEqual(evento.dados_adicionais["quem_cancela"], "Cliente")
        self.assertEqual(evento.dados_adicionais["motivo"], "Desistência voluntária")
        self.assertIn("lancamentos_ledger_ids", evento.dados_adicionais)

