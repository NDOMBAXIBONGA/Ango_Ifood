"""
Testes unitários e de integração para a máquina de estados OrderStateMachineManager ('orders').
Implementa validações estritas da Secção 5, 5.1 e 5.2.
"""
from decimal import Decimal
import uuid
from django.contrib.gis.geos import Point
from django.test import TestCase, override_settings
from django.utils import timezone

from apps.accounts.models import CustomUser
from apps.catalog.models import ParceiroLoja
from apps.orders.models import EventoPedido, Pedido
from apps.orders.state_machine import (
    InvalidStateTransition,
    OrderNotFoundError,
    OrderStateMachineManager,
)


class OrderStateMachineManagerTests(TestCase):
    """
    Testes de cobertura total da máquina de estados do OMS (Secção 5, 5.1 e 5.2).
    """

    def setUp(self) -> None:
        # Cria Cliente
        self.cliente = CustomUser.objects.create_user(
            telemovel="+244923111000",
            email="cliente.teste@delivery.local",
            nome="Cliente de Teste",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # Cria Loja Parceira
        self.loja = ParceiroLoja.objects.create(
            nome="Restaurante Teste OMS",
            nif="500888999",
            morada_texto="Rua das Flores, Luanda",
            contacto="+244923111222",
            licenca_sanitaria="LIC-TEST-001",
            alvara="ALV-TEST-001",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            raio_entrega_km=Decimal("5.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # Cria Pedido inicial em CRIADO
        self.pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            estado=Pedido.EstadoPedido.CRIADO,
            subtotal=5000,
            taxa_entrega=500,
            taxa_servico=250,
            total_cobrado=5750,
        )

    def test_valid_sequential_transition_lifecycle(self) -> None:
        """Valida a jornada sequencial completa de 10 estados da Secção 5.1."""
        pedido_id = self.pedido.id

        # 1. CRIADO -> 2. PAGAMENTO
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.PAGAMENTO,
            ator="sistema:checkout",
            dados_adicionais={"gateway": "multicaixa"},
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.PAGAMENTO)
        self.assertTrue(res.transitou)
        self.assertEqual(EventoPedido.objects.filter(pedido_id=pedido_id).count(), 1)

        # 2. PAGAMENTO -> 3. AGUARDA_PARCEIRO
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.AGUARDA_PARCEIRO,
            ator="sistema:payment_hook",
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.AGUARDA_PARCEIRO)

        # 3. AGUARDA_PARCEIRO -> 4. ACEITE
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.ACEITE,
            ator="parceiro:gerente_loja",
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.ACEITE)

        # 4. ACEITE -> 5. EM_PREPARACAO
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.EM_PREPARACAO,
            ator="parceiro:cozinha",
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.EM_PREPARACAO)

        # 5. EM_PREPARACAO -> 6. PRONTO
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.PRONTO,
            ator="parceiro:cozinha",
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.PRONTO)

        # 6. PRONTO -> 7. RECOLHIDO
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.RECOLHIDO,
            ator="estafeta:estafeta_1",
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.RECOLHIDO)

        # 7. RECOLHIDO -> 8. EM_TRANSITO
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.EM_TRANSITO,
            ator="estafeta:estafeta_1",
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.EM_TRANSITO)

        # 8. EM_TRANSITO -> 9. ENTREGUE
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.ENTREGUE,
            ator="estafeta:estafeta_1",
            dados_adicionais={"pin_validado": True},
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.ENTREGUE)

        # 9. ENTREGUE -> 10. CONCLUIDO
        res = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.CONCLUIDO,
            ator="sistema:fecho_contabil",
        )
        self.assertEqual(res.estado, Pedido.EstadoPedido.CONCLUIDO)

        # Verifica total de 9 transições registadas imutavelmente
        self.assertEqual(EventoPedido.objects.filter(pedido_id=pedido_id).count(), 9)

    def test_invalid_state_transition_raises_exception(self) -> None:
        """Secção 5.1: Transição ilegal direta levanta InvalidStateTransition."""
        pedido_id = self.pedido.id

        # Tenta saltar de CRIADO diretamente para CONCLUIDO ou ENTREGUE
        with self.assertRaises(InvalidStateTransition) as ctx:
            OrderStateMachineManager.transitar_estado(
                pedido_id=pedido_id,
                novo_estado=Pedido.EstadoPedido.CONCLUIDO,
                ator="hacker:tentativa",
            )
        self.assertIn("Secção 5.1", str(ctx.exception))
        self.assertEqual(ctx.exception.codigo, "INVALID_STATE_TRANSITION")

        # Verifica que o pedido permaneceu inalterado em CRIADO
        self.pedido.refresh_from_db()
        self.assertEqual(self.pedido.estado, Pedido.EstadoPedido.CRIADO)
        self.assertEqual(EventoPedido.objects.filter(pedido_id=pedido_id).count(), 0)

    def test_absolute_idempotency_same_state(self) -> None:
        """Secção 5.2: Se o pedido já estiver no novo estado, não duplica eventos nem efeitos."""
        pedido_id = self.pedido.id

        # Transita para PAGAMENTO
        res1 = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.PAGAMENTO,
            ator="sistema:checkout",
        )
        self.assertTrue(res1.transitou)
        self.assertEqual(EventoPedido.objects.filter(pedido_id=pedido_id).count(), 1)

        # Re-submete a mesma transição para PAGAMENTO
        res2 = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.PAGAMENTO,
            ator="sistema:retry_checkout",
        )
        self.assertFalse(res2.transitou)
        self.assertEqual(res2.estado, Pedido.EstadoPedido.PAGAMENTO)

        # Continua a ter rigorosamente 1 único evento de auditoria
        self.assertEqual(EventoPedido.objects.filter(pedido_id=pedido_id).count(), 1)

    def test_exceptional_exit_cancelado_and_reembolsado(self) -> None:
        """Secção 5.1: Saída excecional CANCELADO -> REEMBOLSADO."""
        pedido_id = self.pedido.id

        # CRIADO -> CANCELADO
        res_cancel = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.CANCELADO,
            ator="cliente:desistencia",
            dados_adicionais={"motivo": "Engano na morada"},
        )
        self.assertEqual(res_cancel.estado, Pedido.EstadoPedido.CANCELADO)

        # CANCELADO -> REEMBOLSADO
        res_reembolso = OrderStateMachineManager.transitar_estado(
            pedido_id=pedido_id,
            novo_estado=Pedido.EstadoPedido.REEMBOLSADO,
            ator="sistema:gateway_refund",
        )
        self.assertEqual(res_reembolso.estado, Pedido.EstadoPedido.REEMBOLSADO)

        # Estado terminal REEMBOLSADO não permite mais nenhuma transição
        with self.assertRaises(InvalidStateTransition):
            OrderStateMachineManager.transitar_estado(
                pedido_id=pedido_id,
                novo_estado=Pedido.EstadoPedido.CRIADO,
                ator="sistema:tentativa",
            )

    def test_missing_order_raises_order_not_found(self) -> None:
        """Valida que ID inexistente levanta OrderNotFoundError."""
        uuid_inexistente = uuid.uuid4()
        with self.assertRaises(OrderNotFoundError):
            OrderStateMachineManager.transitar_estado(
                pedido_id=uuid_inexistente,
                novo_estado=Pedido.EstadoPedido.PAGAMENTO,
                ator="sistema:teste",
            )


class OperationalTimeoutsTasksTests(TestCase):
    """
    Testes unitários e de integração para as tarefas Celery de Timeouts Operacionais
    (RN-075, RN-086 e Parâmetros da Secção 8).
    """

    def setUp(self) -> None:
        from django.core.cache import cache
        cache.clear()

        # Cria Cliente
        self.cliente = CustomUser.objects.create_user(
            telemovel="+244923222111",
            email="cliente.timeout@delivery.local",
            nome="Cliente Timeout",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # Cria Loja Parceira
        self.loja = ParceiroLoja.objects.create(
            nome="Hamburgueria Central Luanda",
            nif="500777666",
            morada_texto="Avenida 4 de Fevereiro, Luanda",
            contacto="+244923222333",
            licenca_sanitaria="LIC-2026-001",
            alvara="ALV-2026-001",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            raio_entrega_km=Decimal("5.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # Cria Pedido inicial
        self.pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            estado=Pedido.EstadoPedido.AGUARDA_PARCEIRO,
            subtotal=6000,
            taxa_entrega=800,
            taxa_servico=300,
            total_cobrado=7100,
        )

        # Cria Utilizador e Estafeta
        self.user_estafeta = CustomUser.objects.create_user(
            telemovel="+244923999888",
            email="estafeta.timeout@delivery.local",
            nome="Estafeta Rápido",
            estado=CustomUser.EstadoConta.ATIVO,
        )
        from apps.logistics.models import Estafeta, Entrega
        self.estafeta = Estafeta.objects.create(
            utilizador=self.user_estafeta,
            tipo_veiculo=Estafeta.TipoVeiculo.MOTA,
            carta_conducao="CC-2026-777",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2350, -8.8125, srid=4326),
            score_reputacao=Decimal("4.90"),
        )

        # Cria Entrega associada ao Pedido
        self.entrega = Entrega.objects.create(
            pedido=self.pedido,
            estado_entrega=Entrega.EstadoEntrega.PENDENTE,
            distancia_metros=1200,
        )

    def test_partner_timeout_alert_at_90_seconds_rn075(self) -> None:
        """RN-075: Aos 90 segundos dispara lembrete reforçado se ainda em AGUARDA_PARCEIRO."""
        from apps.orders.tasks import task_monitorizar_timeout_aceitacao_parceiro

        res = task_monitorizar_timeout_aceitacao_parceiro(
            pedido_id=str(self.pedido.id),
            estagio="alerta_90s",
        )

        self.assertEqual(res["status"], "alerta_90s_disparado")
        self.assertEqual(res["tempo_restante_segundos"], 90)

        # O estado do pedido permanece AGUARDA_PARCEIRO
        self.pedido.refresh_from_db()
        self.assertEqual(self.pedido.estado, Pedido.EstadoPedido.AGUARDA_PARCEIRO)

    def test_partner_timeout_final_at_180_seconds_rejects_and_refunds_rn075(self) -> None:
        """RN-075: Aos 180s (3 min) transita para REJEITADO por SISTEMA e processa reembolso."""
        from apps.orders.tasks import task_monitorizar_timeout_aceitacao_parceiro

        res = task_monitorizar_timeout_aceitacao_parceiro(
            pedido_id=str(self.pedido.id),
            estagio="timeout_final",
            timeout_segundos=180,
        )

        self.assertEqual(res["status"], "rejeitado_por_timeout")
        self.assertEqual(res["novo_estado"], Pedido.EstadoPedido.REJEITADO)

        # Valida que o pedido na BD foi alterado para REJEITADO
        self.pedido.refresh_from_db()
        self.assertEqual(self.pedido.estado, Pedido.EstadoPedido.REJEITADO)

        # Valida que o reembolso foi registado
        self.assertEqual(res["reembolso"]["montante_reembolsado"], 7100)

        # Valida registo imutável de auditoria em EventoPedido
        eventos = EventoPedido.objects.filter(pedido=self.pedido, tipo_evento=EventoPedido.TipoEvento.ORDER_REJECTED)
        self.assertTrue(eventos.exists())
        self.assertEqual(eventos.first().autor, "SISTEMA")

    def test_courier_offer_timeout_at_30_seconds_rn086(self) -> None:
        """RN-086: Timeout de 30 segundos expira a oferta e invoca redespacho para próximo estafeta."""
        from apps.orders.tasks import task_timeout_oferta_estafeta
        from django.core.cache import cache

        # Simula oferta em curso no Redis
        chave_oferta = f"logistics:offer:{self.entrega.id}:{self.estafeta.id}"
        cache.set(chave_oferta, "OFERECIDA", timeout=35)

        res = task_timeout_oferta_estafeta(
            entrega_id=str(self.entrega.id),
            estafeta_id=str(self.estafeta.id),
        )

        self.assertEqual(res["status"], "oferta_expirada_e_redespachada")

        # Verifica que no Redis a oferta ficou EXPIRADA
        self.assertEqual(cache.get(chave_oferta), "EXPIRADA")

        # Verifica que o estafeta foi adicionado à lista de excluídos desta corrida
        chave_excluidos = f"logistics:excluded_couriers:{self.entrega.id}"
        excluidos = cache.get(chave_excluidos)
        self.assertIn(str(self.estafeta.id), excluidos)

        # Valida registo imutável de auditoria da expiração da oferta
        eventos = EventoPedido.objects.filter(pedido=self.pedido, tipo_evento=EventoPedido.TipoEvento.DELIVERY_FAILED)
        self.assertTrue(eventos.exists())


