"""
Testes Unitários e de Integração para a aplicação 'support'.
Módulo: apps/support/tests_disputes.py

Cobre os cenários de:
- RN-106: Alçadas e limites de compensação por perfil (Agente <= 3.000 Kz, exigência de Supervisor se superior);
- RN-138 / RN-140: Incidentes e reações alérgicas graves;
- RN-139: Gatilho Celery do alerta de SLA emergencial (< 5 minutos) via post_save signal;
- RN-141: Resolução formal de disputas (Procedente_Cliente, Procedente_Parceiro, Improcedente);
- RN-142: Imutabilidade estrita e bloqueio de métodos PUT, PATCH, DELETE (HTTP 405).
"""
import uuid
from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth.models import Group
from django.core.exceptions import ValidationError
from django.test import TestCase
from django.urls import reverse
from rest_framework import status
from rest_framework.test import APIClient

from apps.accounts.models import CustomUser
from apps.catalog.models import CategoriaItem, ParceiroLoja
from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.orders.models import Pedido
from apps.support.models import TicketDisputa
from apps.support.services import (
    CompensationLimitExceededError,
    DisputeResolutionService,
    DisputeServiceError,
)


class DisputeResolutionTests(TestCase):
    """Bateria de testes para as regras de negócio de Suporte e Disputas."""

    def setUp(self):
        self.client = APIClient()

        # Cria grupos RBAC
        self.grupo_agente, _ = Group.objects.get_or_create(name="Agente")
        self.grupo_supervisor, _ = Group.objects.get_or_create(name="Supervisor")

        # Cria utilizadores
        self.cliente = CustomUser.objects.create_user(
            telemovel="+351910000001",
            email="cliente@exemplo.com",
            nome="Cliente Disputa",
        )
        self.parceiro_user = CustomUser.objects.create_user(
            telemovel="+351910000002",
            email="parceiro@exemplo.com",
            nome="Dono Restaurante",
        )
        self.agente = CustomUser.objects.create_user(
            telemovel="+351910000003",
            email="agente@suporte.com",
            nome="Agente Helpdesk",
        )
        self.agente.groups.add(self.grupo_agente)

        self.supervisor = CustomUser.objects.create_user(
            telemovel="+351910000004",
            email="supervisor@suporte.com",
            nome="Supervisor Geral",
            is_staff=True,
        )
        self.supervisor.groups.add(self.grupo_supervisor)

        self.outro_utilizador = CustomUser.objects.create_user(
            telemovel="+351910000005",
            email="outro@exemplo.com",
            nome="Outro Utilizador Regular",
        )

        # Cria categoria e loja
        self.categoria = Categoria.objects.create(
            nome="Pizzaria",
            slug="pizzaria",
            taxa_comissao_base_percentagem=Decimal("15.00"),
        )
        self.loja = Loja.objects.create(
            nome="Pizzaria Napoli",
            nif="500123456",
            proprietario=self.parceiro_user,
            categoria=self.categoria,
            comissao_negociada_percentagem=Decimal("15.00"),
        )

        # Cria pedido alvo da disputa
        self.pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            subtotal=850000,
            taxa_entrega=120000,
            taxa_servico=42500,
            desconto_cupao=0,
            gorjeta=0,
            total=1012500,
            estado=Pedido.EstadoPedido.ENTREGUE,
        )

        self.url_resolve = reverse("support:disputes-resolve")

    def test_agente_resolve_disputa_dentro_do_limite_3000kz(self):
        """
        RN-106 / RN-141: Agente pode autorizar compensação <= 3.000 Kz (300.000 cêntimos)
        sem exigir identificação de supervisor.
        """
        self.client.force_authenticate(user=self.agente)
        payload = {
            "pedido_id": str(self.pedido.id),
            "decisao": "Procedente_Cliente",
            "motivo_justificacao": "Item com embalagem danificada comprovado por foto e logs.",
            "compensacao_valor": 200000,  # 2.000 Kz (abaixo do teto de 3.000 Kz)
            "tipo_incidente": "DERRAME_DANOS",
            "prioridade": "MEDIA",
        }

        response = self.client.post(self.url_resolve, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        dados = response.json()
        self.assertEqual(dados["status"], "RESOLVIDO")
        self.assertEqual(dados["decisao"], "Procedente_Cliente")
        self.assertEqual(dados["compensacao_valor"], 200000)

        # Verifica auditoria imutável no banco
        ticket = TicketDisputa.objects.get(pk=dados["ticket_id"])
        self.assertEqual(ticket.estado, TicketDisputa.EstadoTicket.RESOLVIDO)
        self.assertEqual(ticket.autor_decisao, self.agente)
        self.assertIsNone(ticket.supervisor_aprovador)

        # Verifica lançamento no Livro Razão (Ledger)
        ledger_entry = LivroRazaoLedger.objects.filter(pedido=self.pedido).first()
        self.assertIsNotNone(ledger_entry)
        self.assertEqual(ledger_entry.montante, 200000)

    def test_agente_rejeitado_se_exceder_3000kz_sem_supervisor(self):
        """
        RN-106: Agente tentando compensação de 5.000 Kz (500.000 cêntimos)
        sem 'supervisor_aprovador_id' deve ser barrado com erro de validação.
        """
        self.client.force_authenticate(user=self.agente)
        payload = {
            "pedido_id": str(self.pedido.id),
            "decisao": "Procedente_Cliente",
            "motivo_justificacao": "Cliente reclama perda total do pedido.",
            "compensacao_valor": 500000,  # 5.000 Kz (excede 3.000 Kz)
        }

        response = self.client.post(self.url_resolve, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("supervisor_aprovador_id", response.json())

    def test_agente_rejeitado_se_supervisor_indicado_nao_for_supervisor(self):
        """
        RN-106: Se o ID de aprovador indicado pertencer a um utilizador comum sem perfil
        de Supervisor, o pedido deve ser barrado.
        """
        self.client.force_authenticate(user=self.agente)
        payload = {
            "pedido_id": str(self.pedido.id),
            "decisao": "Procedente_Cliente",
            "motivo_justificacao": "Cliente reclama perda total e pede compensação de 5.000 Kz.",
            "compensacao_valor": 500000,
            "supervisor_aprovador_id": str(self.outro_utilizador.id),
        }

        response = self.client.post(self.url_resolve, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("supervisor_aprovador_id", response.json())

    def test_agente_com_supervisor_valido_sucesso_acima_de_3000kz(self):
        """
        RN-106: Agente compensando 5.000 Kz com 'supervisor_aprovador_id' válido deve ter sucesso.
        """
        self.client.force_authenticate(user=self.agente)
        payload = {
            "pedido_id": str(self.pedido.id),
            "decisao": "Procedente_Cliente",
            "motivo_justificacao": "Compensação superior autorizada presencialmente pelo supervisor de turno.",
            "compensacao_valor": 500000,
            "supervisor_aprovador_id": str(self.supervisor.id),
        }

        response = self.client.post(self.url_resolve, data=payload, format="json")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        dados = response.json()
        self.assertEqual(dados["compensacao_valor"], 500000)

        ticket = TicketDisputa.objects.get(pk=dados["ticket_id"])
        self.assertEqual(ticket.autor_decisao, self.agente)
        self.assertEqual(ticket.supervisor_aprovador, self.supervisor)

    def test_bloqueio_imutavel_put_patch_delete_http_405(self):
        """
        RN-142: Garante que os métodos PUT, PATCH e DELETE na ViewSet retornam HTTP 405 Method Not Allowed.
        """
        ticket = TicketDisputa.objects.create(
            pedido=self.pedido,
            tipo_incidente=TicketDisputa.TipoIncidente.DISPUTA_COMERCIAL,
            prioridade=TicketDisputa.PrioridadeTicket.BAIXA,
            motivo="Disputa inicial para teste de imutabilidade.",
        )
        url_detalhe = reverse("support:disputes-detail", kwargs={"pk": ticket.id})

        self.client.force_authenticate(user=self.supervisor)

        # PUT proibido
        res_put = self.client.put(url_detalhe, data={"motivo": "Alterado"}, format="json")
        self.assertEqual(res_put.status_code, status.HTTP_405_METHOD_NOT_ALLOWED)

        # PATCH proibido
        res_patch = self.client.patch(url_detalhe, data={"motivo": "Alterado"}, format="json")
        self.assertEqual(res_patch.status_code, status.HTTP_405_METHOD_NOT_ALLOWED)

        # DELETE proibido
        res_del = self.client.delete(url_detalhe)
        self.assertEqual(res_del.status_code, status.HTTP_405_METHOD_NOT_ALLOWED)

    def test_bloqueio_imutavel_model_delete(self):
        """
        RN-142: Proíbe delete() direto no modelo ORM.
        """
        ticket = TicketDisputa.objects.create(
            pedido=self.pedido,
            tipo_incidente=TicketDisputa.TipoIncidente.DISPUTA_COMERCIAL,
            prioridade=TicketDisputa.PrioridadeTicket.BAIXA,
            motivo="Ticket para testar proteção delete ORM.",
        )
        with self.assertRaises(ValidationError):
            ticket.delete()

    @patch("apps.support.tasks.task_escalar_alerta_incidente_seguranca_5min.delay")
    def test_sla_alerta_incidente_seguranca_despacha_celery(self, mock_delay):
        """
        RN-139 / RN-140: Criação de ticket de segurança alimentar com prioridade Crítica
        despacha imediatamente tarefa Celery assíncrona.
        """
        ticket = TicketDisputa.objects.create(
            pedido=self.pedido,
            tipo_incidente=TicketDisputa.TipoIncidente.REACAO_ALERGICA,
            prioridade=TicketDisputa.PrioridadeTicket.CRITICA,
            motivo="Cliente sofreu choque anafilático devido a contaminação cruzada por amendoim.",
        )

        mock_delay.assert_called_once_with(ticket_id=str(ticket.id))

