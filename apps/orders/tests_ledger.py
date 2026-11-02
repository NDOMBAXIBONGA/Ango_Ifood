"""
Testes Unitários e de Integração Contábil para o Livro Razão Ledger ('orders').
Valida rigorosamente:
- Secção 7.1: Exemplo prático de um pedido (850000, 120000, 42500, -100000, 30000 = 942500);
- Secção 7.3: Princípios do Ledger de Dupla Entrada Contábil (partidas dobradas imutáveis);
- Regras RN-050, RN-051, RN-053, RN-054, RN-055, RN-058, RN-059, RN-146, RN-147 e RN-150.
"""
from datetime import timedelta
from decimal import Decimal
import uuid

from django.contrib.gis.geos import Point
from django.test import TestCase
from django.utils import timezone

from apps.accounts.models import CustomUser
from apps.catalog.models import ParceiroLoja
from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.logistics.models import Entrega, Estafeta
from apps.orders.ledger_service import (
    ComplaintWindowActiveError,
    InvalidOrderStateForSettlementError,
    LedgerAccountingError,
    executar_divisao_financeira_conclusao,
    executar_divisao_financeira_conclusao_pedido,
)
from apps.orders.models import Pedido


class OrderLedgerSettlementTests(TestCase):
    """
    Testes de cobertura contábil e transacional para o encerramento e liquidação de pedidos.
    """

    def setUp(self) -> None:
        # 1. Utilizador Cliente
        self.cliente = CustomUser.objects.create_user(
            telemovel="+244923000111",
            email="cliente.ledger@delivery.ao",
            nome="Cliente Contabilistico",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # 2. Utilizador Estafeta e Perfil Logístico
        self.user_estafeta = CustomUser.objects.create_user(
            telemovel="+244923000222",
            email="estafeta.ledger@delivery.ao",
            nome="Estafeta Rápido",
            estado=CustomUser.EstadoConta.ATIVO,
        )
        self.estafeta = Estafeta.objects.create(
            utilizador=self.user_estafeta,
            tipo_veiculo=Estafeta.TipoVeiculo.MOTA,
            carta_conducao="CC-LUANDA-998877",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2300, -8.8200, srid=4326),
            score_reputacao=Decimal("4.95"),
            saldo_carteira=0,
        )

        # 3. Loja Parceira com comissão contratual padrão de 20.00%
        self.loja = ParceiroLoja.objects.create(
            nome="Restaurante Luanda Gourmet",
            nif="540112233",
            morada_texto="Avenida 4 de Fevereiro, Luanda",
            contacto="+244923000333",
            licenca_sanitaria="LIC-SAN-2026-001",
            alvara="ALV-COM-2026-001",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            comissao_percentagem=Decimal("20.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # 4. Pedido configurado com os valores canónicos da Secção 7.1:
        # Subtotal: 850000 | Taxa Entrega: 120000 | Taxa Servico: 42500 | Cupao: 100000 | Gorjeta: 30000
        # Total cobrado = 850000 + 120000 + 42500 - 100000 + 30000 = 942500 cêntimos
        self.pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            estado=Pedido.EstadoPedido.CONCLUIDO,
            subtotal=850000,
            taxa_entrega=120000,
            taxa_servico=42500,
            taxa_pequeno_pedido=0,
            gorjeta_estafeta=30000,
            descontos=100000,
            total_cobrado=942500,
            metodo_pagamento=Pedido.MetodoPagamento.CARTAO,
        )

        # 5. Entrega associada ao pedido e ao estafeta
        self.entrega = Entrega.objects.create(
            pedido=self.pedido,
            estafeta=self.estafeta,
            estado_entrega=Entrega.EstadoEntrega.ENTREGUE,
            estado_logistico=Entrega.EstadoEntrega.ENTREGUE,
            distancia_metros=3500,
        )

    def test_divisao_financeira_exemplo_seccao_7_1(self) -> None:
        """
        Secção 7.1 e 7.3: Testa os valores exatos de liquidação em cêntimos:
        - Parceiro: 680000 (850000 - 170000 comissao)
        - Estafeta: 140000 (110000 base + 30000 gorjeta)
        - Plataforma Bruta: 122500 (942500 - 680000 - 140000)
        - Custo Gateway (2%): 18850
        - Plataforma Líquida: 103650
        - Carteira do estafeta incrementada para 140000
        """
        resultado = executar_divisao_financeira_conclusao_pedido(
            pedido_id=self.pedido.id,
            forcar_exemplo_seccao_7_1=True,
        )

        # Validações dos montantes calculados
        self.assertEqual(resultado["pago_liquido_parceiro"], 680000)
        self.assertEqual(resultado["comissao_parceiro_valor"], 170000)
        self.assertEqual(resultado["pago_liquido_estafeta"], 140000)
        self.assertEqual(resultado["repasse_entrega_base_estafeta"], 110000)
        self.assertEqual(resultado["margem_bruta_plataforma"], 122500)
        self.assertEqual(resultado["custo_gateway_valor"], 18850)
        self.assertEqual(resultado["margem_liquida_plataforma"], 103650)
        self.assertTrue(resultado["saldo_liquido_zero"])

        # Validação da atualização do saldo de carteira do estafeta (RN-146)
        self.estafeta.refresh_from_db()
        self.assertEqual(self.estafeta.saldo_carteira, 140000)

        # Validação dos lançamentos criados no LivroRazaoLedger
        lancamentos = LivroRazaoLedger.objects.filter(referencia_pedido=self.pedido)
        self.assertEqual(lancamentos.count(), 4)

        # Lançamento 1: Parceiro
        l_parceiro = lancamentos.get(conta_destino=LivroRazaoLedger.ContaContabil.PARCEIRO)
        self.assertEqual(l_parceiro.conta_origem, LivroRazaoLedger.ContaContabil.CLIENTE)
        self.assertEqual(l_parceiro.debito, 680000)
        self.assertEqual(l_parceiro.credito, 680000)

        # Lançamento 2: Estafeta
        l_estafeta = lancamentos.get(conta_destino=LivroRazaoLedger.ContaContabil.ESTAFETA)
        self.assertEqual(l_estafeta.conta_origem, LivroRazaoLedger.ContaContabil.CLIENTE)
        self.assertEqual(l_estafeta.debito, 140000)
        self.assertEqual(l_estafeta.credito, 140000)

        # Lançamento 3: Plataforma
        l_plataforma = lancamentos.get(
            conta_origem=LivroRazaoLedger.ContaContabil.CLIENTE,
            conta_destino=LivroRazaoLedger.ContaContabil.PLATAFORMA,
        )
        self.assertEqual(l_plataforma.debito, 122500)
        self.assertEqual(l_plataforma.credito, 122500)

        # Lançamento 4: Gateway
        l_gateway = lancamentos.get(conta_destino=LivroRazaoLedger.ContaContabil.GATEWAY)
        self.assertEqual(l_gateway.conta_origem, LivroRazaoLedger.ContaContabil.PLATAFORMA)
        self.assertEqual(l_gateway.debito, 18850)
        self.assertEqual(l_gateway.credito, 18850)

        # Validação do equilíbrio geral do Ledger (RN-150 / Secção 7.3)
        self.assertTrue(LivroRazaoLedger.validar_equilibrio_pedido(self.pedido.id, raise_exception=True))

        # Validação do balanço de saldos líquidos de todas as contas
        balanco = resultado["balanco_contabil_contas"]
        self.assertEqual(balanco["Cliente"], -942500)
        self.assertEqual(balanco["Parceiro"], 680000)
        self.assertEqual(balanco["Estafeta"], 140000)
        self.assertEqual(balanco["Plataforma"], 103650)
        self.assertEqual(balanco["Gateway"], 18850)
        self.assertEqual(sum(balanco.values()), 0)

        # Validação do registo imutável de auditoria no EventoPedido (Secção 5.2)
        evento = EventoPedido.objects.filter(
            pedido=self.pedido,
            tipo_evento=EventoPedido.TipoEvento.ORDER_COMPLETED,
        ).first()
        self.assertIsNotNone(evento)
        self.assertEqual(evento.autor, "sistema:ledger_accounting")

    def test_idempotencia_liquidacao_duplicada(self) -> None:
        """
        Secção 7.3: Invocar a função de liquidação mais de uma vez não deve
        duplicar lançamentos contábeis no Livro Razão.
        """
        resultado1 = executar_divisao_financeira_conclusao_pedido(self.pedido.id)
        self.assertTrue(resultado1["saldo_liquido_zero"])
        self.assertEqual(LivroRazaoLedger.objects.filter(referencia_pedido=self.pedido).count(), 4)

        # Segunda invocação (idempotente)
        resultado2 = executar_divisao_financeira_conclusao_pedido(self.pedido.id)
        self.assertEqual(resultado2["status"], "JA_LIQUIDADO")
        self.assertEqual(LivroRazaoLedger.objects.filter(referencia_pedido=self.pedido).count(), 4)

    def test_rn147_janela_reclamacao_ativa_bloqueia_liquidacao(self) -> None:
        """
        RN-147: Pedido em 'ENTREGUE' há menos de 48 horas deve levantar ComplaintWindowActiveError
        se ignorar_janela_48h=False.
        """
        self.pedido.estado = Pedido.EstadoPedido.ENTREGUE
        self.pedido.save(update_fields=["estado"])

        # Tenta liquidar antes das 48h sem forçar
        with self.assertRaises(ComplaintWindowActiveError):
            executar_divisao_financeira_conclusao_pedido(
                pedido_id=self.pedido.id,
                ignorar_janela_48h=False,
            )

    def test_rn147_liquidacao_apos_janela_48h_autorizada(self) -> None:
        """
        RN-147: Quando expirada a janela de 48h ou se ignorar_janela_48h=True, transita
        automaticamente para CONCLUIDO e liquida o pedido.
        """
        self.pedido.estado = Pedido.EstadoPedido.ENTREGUE
        self.pedido.save(update_fields=["estado"])

        resultado = executar_divisao_financeira_conclusao_pedido(
            pedido_id=self.pedido.id,
            ignorar_janela_48h=True,
        )

        self.pedido.refresh_from_db()
        self.assertEqual(self.pedido.estado, Pedido.EstadoPedido.CONCLUIDO)
        self.assertTrue(resultado["saldo_liquido_zero"])
        self.assertEqual(LivroRazaoLedger.objects.filter(referencia_pedido=self.pedido).count(), 4)

    def test_estado_invalido_rejeita_liquidacao(self) -> None:
        """
        Secção 5.1: Pedido em estado preparatório (ex.: EM_PREPARACAO) não pode ser liquidado.
        """
        self.pedido.estado = Pedido.EstadoPedido.EM_PREPARACAO
        self.pedido.save(update_fields=["estado"])

        with self.assertRaises(InvalidOrderStateForSettlementError):
            executar_divisao_financeira_conclusao_pedido(pedido_id=self.pedido.id)

