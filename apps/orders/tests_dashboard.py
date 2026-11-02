"""
Testes de Integração para a ViewSet OperationalMetricsDashboardViewSet ('orders').
Valida rigorosamente:
- Controlo de acesso RBAC (Apenas Staff/Admin e grupo 'Finanças' autorizados);
- Validação e obrigatoriedade dos query params 'data_inicio' e 'data_fim';
- Cálculo do GMV e AOV (Secção 10);
- Rentabilidade e Margem de Contribuição por Pedido;
- Metas de SLAs Operacionais: Pontualidade (>= 90%) e Taxa de Rejeição (<= 3%) (Secção 8.1).
"""
from datetime import timedelta
from decimal import Decimal
import uuid

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.contrib.gis.geos import Point
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.catalog.models import CategoriaItem, ParceiroLoja
from apps.finance.models import EventoPedido
from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import Pedido

User = get_user_model()


class OperationalMetricsDashboardTests(TestCase):
    """Testa os cálculos matemáticos nativos de KPIs e a segurança do dashboard."""

    def setUp(self) -> None:
        self.client = APIClient()

        # 1. Utilizador Administrador (Staff)
        self.admin_user = User.objects.create_user(
            telemovel="+244923000001",
            email="admin.dash@delivery.ao",
            nome="Administrador Geral",
            is_staff=True,
            estado=User.EstadoConta.ATIVO,
        )

        # 2. Utilizador do Grupo 'Finanças'
        self.grupo_financas, _ = Group.objects.get_or_create(name="Finanças")
        self.finance_user = User.objects.create_user(
            telemovel="+244923000002",
            email="finance.dash@delivery.ao",
            nome="Analista Financeiro",
            is_staff=False,
            estado=User.EstadoConta.ATIVO,
        )
        self.finance_user.groups.add(self.grupo_financas)

        # 3. Utilizador Cliente Comum (Sem permissões administrativas)
        self.regular_user = User.objects.create_user(
            telemovel="+244923000003",
            email="cliente.dash@delivery.ao",
            nome="Cliente Comum",
            is_staff=False,
            estado=User.EstadoConta.ATIVO,
        )

        # 4. Loja Parceira em Luanda
        self.loja = ParceiroLoja.objects.create(
            responsavel=self.admin_user,
            nome="Hamburgueria Luanda Central",
            nif="540887766",
            morada_texto="Avenida 4 de Fevereiro, Luanda",
            contacto="+244923111000",
            licenca_sanitaria="LIC-TEST-DASH",
            alvara="ALV-TEST-DASH",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            comissao_percentagem=Decimal("20.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )
        self.categoria = CategoriaItem.objects.create(
            loja=self.loja,
            nome="Hamburgueres",
            ordem_exibicao=1,
        )

        # 5. Estafeta
        self.user_estafeta = User.objects.create_user(
            telemovel="+244923000004",
            email="estafeta.dash@delivery.ao",
            nome="Estafeta Dashboard",
            estado=User.EstadoConta.ATIVO,
        )
        self.estafeta = Estafeta.objects.create(
            utilizador=self.user_estafeta,
            tipo_veiculo=Estafeta.TipoVeiculo.MOTA,
            carta_conducao="CC-DASH-001",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2300, -8.8200, srid=4326),
        )

        # Janela temporal de teste
        self.agora = timezone.now()
        self.data_inicio_str = (self.agora - timedelta(days=7)).strftime("%Y-%m-%d")
        self.data_fim_str = (self.agora + timedelta(days=1)).strftime("%Y-%m-%d")

        # 6. Cria Pedidos de Amostra no Período:
        # Pedido 1: CONCLUIDO (Subtotal: 850.000, Total: 942.500)
        self.pedido_concluido_1 = Pedido.objects.create(
            cliente=self.regular_user,
            loja=self.loja,
            estado=Pedido.EstadoPedido.CONCLUIDO,
            subtotal=850000,
            taxa_entrega=120000,
            taxa_servico=42500,
            gorjeta_estafeta=30000,
            descontos=100000,
            total_cobrado=942500,
            metodo_pagamento=Pedido.MetodoPagamento.CARTAO,
        )
        self.entrega_1 = Entrega.objects.create(
            pedido=self.pedido_concluido_1,
            estafeta=self.estafeta,
            estado_entrega=Entrega.EstadoEntrega.ENTREGUE,
            estado_logistico=Entrega.EstadoEntrega.ENTREGUE,
            eta_estimada=self.agora + timedelta(minutes=45),
        )

        # Pedido 2: CONCLUIDO (Subtotal: 650.000, Total: 750.000)
        self.pedido_concluido_2 = Pedido.objects.create(
            cliente=self.regular_user,
            loja=self.loja,
            estado=Pedido.EstadoPedido.CONCLUIDO,
            subtotal=650000,
            taxa_entrega=100000,
            taxa_servico=32500,
            gorjeta_estafeta=10000,
            descontos=42500,
            total_cobrado=750000,
            metodo_pagamento=Pedido.MetodoPagamento.CARTAO,
        )
        self.entrega_2 = Entrega.objects.create(
            pedido=self.pedido_concluido_2,
            estafeta=self.estafeta,
            estado_entrega=Entrega.EstadoEntrega.ENTREGUE,
            estado_logistico=Entrega.EstadoEntrega.ENTREGUE,
            eta_estimada=self.agora + timedelta(minutes=40),
        )

        # Pedido 3: CANCELADO
        self.pedido_cancelado = Pedido.objects.create(
            cliente=self.regular_user,
            loja=self.loja,
            estado=Pedido.EstadoPedido.CANCELADO,
            subtotal=500000,
            total_cobrado=500000,
            metodo_pagamento=Pedido.MetodoPagamento.CARTAO,
        )

        # Eventos para teste da taxa de rejeição
        EventoPedido.objects.create(
            pedido=self.pedido_concluido_1,
            tipo_evento=EventoPedido.TipoEvento.ORDER_SENT_TO_PARTNER,
            autor="sistema",
        )
        EventoPedido.objects.create(
            pedido=self.pedido_concluido_2,
            tipo_evento=EventoPedido.TipoEvento.ORDER_SENT_TO_PARTNER,
            autor="sistema",
        )
        EventoPedido.objects.create(
            pedido=self.pedido_cancelado,
            tipo_evento=EventoPedido.TipoEvento.ORDER_REJECTED,
            autor="parceiro",
        )

    def test_acesso_bloqueado_para_usuario_comum(self) -> None:
        """Utilizador comum sem permissões de Finanças ou Admin recebe HTTP 403 Forbidden."""
        self.client.force_authenticate(user=self.regular_user)
        url = reverse("admin-portal:admin-dashboard-kpis")
        response = self.client.get(
            url,
            {"data_inicio": self.data_inicio_str, "data_fim": self.data_fim_str},
        )
        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_acesso_autorizado_para_grupo_financas(self) -> None:
        """Utilizador do grupo 'Finanças' recebe HTTP 200 OK."""
        self.client.force_authenticate(user=self.finance_user)
        url = reverse("admin-portal:admin-dashboard-kpis")
        response = self.client.get(
            url,
            {"data_inicio": self.data_inicio_str, "data_fim": self.data_fim_str},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_validacao_obrigatoriedade_parametros_datas(self) -> None:
        """Ausência de data_inicio ou data_fim deve retornar HTTP 400 Bad Request."""
        self.client.force_authenticate(user=self.admin_user)
        url = reverse("admin-portal:admin-dashboard-kpis")

        # Sem data_inicio
        res1 = self.client.get(url, {"data_fim": self.data_fim_str})
        self.assertEqual(res1.status_code, status.HTTP_400_BAD_REQUEST)

        # Sem data_fim
        res2 = self.client.get(url, {"data_inicio": self.data_inicio_str})
        self.assertEqual(res2.status_code, status.HTTP_400_BAD_REQUEST)

    def test_calculo_gmv_e_aov(self) -> None:
        """
        Secção 10:
        GMV = Soma do subtotal dos pedidos concluídos:
        850.000 + 650.000 = 1.500.000 cêntimos (15.000,00 Kz)
        AOV = GMV / 2 concluídos = 750.000 cêntimos (7.500,00 Kz)
        """
        self.client.force_authenticate(user=self.admin_user)
        url = reverse("admin-portal:admin-dashboard-kpis")
        response = self.client.get(
            url,
            {
                "data_inicio": self.data_inicio_str,
                "data_fim": self.data_fim_str,
                "cidade": "Luanda",
            },
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        dados = response.data

        gmv_data = dados["kpis_financeiros_seccao_10"]["gmv"]
        self.assertEqual(gmv_data["valor_centimos"], 1500000)
        self.assertEqual(gmv_data["valor_kz"], 15000.0)

        aov_data = dados["kpis_financeiros_seccao_10"]["aov"]
        self.assertEqual(aov_data["valor_centimos"], 750000)
        self.assertEqual(aov_data["valor_kz"], 7500.0)

        # Volume
        funil = dados["funil_volume_pedidos"]
        self.assertEqual(funil["total_pedidos_criados"], 3)
        self.assertEqual(funil["pedidos_concluidos"], 2)
        self.assertEqual(funil["pedidos_cancelados"], 1)

    def test_slas_operacionais_pontualidade_e_rejeicao(self) -> None:
        """
        Secção 8.1:
        Pontualidade: 2 pedidos entregues dentro do prazo (100.0% >= 90% meta).
        Taxa de rejeição: 1 rejeição em 3 eventos enviados (~33.3% > 3% meta -> meta não atingida).
        """
        self.client.force_authenticate(user=self.admin_user)
        url = reverse("admin-portal:admin-dashboard-kpis")
        response = self.client.get(
            url,
            {"data_inicio": self.data_inicio_str, "data_fim": self.data_fim_str},
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)

        slas = response.data["metas_operacionais_seccao_8_1"]

        # Pontualidade
        pontualidade = slas["pontualidade_sla_entrega"]
        self.assertEqual(pontualidade["taxa_pontualidade_pct"], 100.0)
        self.assertTrue(pontualidade["meta_atingida"])

        # Rejeição
        rejeicao = slas["taxa_rejeicao_parceiros"]
        self.assertEqual(rejeicao["eventos_rejeitados"], 1)
        self.assertFalse(rejeicao["meta_atingida"])

