"""
Testes unitários para o Algoritmo Core de Despacho Logístico ('logistics').
Cobre as Regras de Negócio:
- RN-083: Disponibilidade de estafetas (online, onboarding aprovado, localização PostGIS).
- RN-084: Limite de capacidade simultânea e conformidade legal (bebidas alcoólicas >= 18 anos).
- RN-085: Pontuação ponderada de despacho (ScoreDespacho) e ordenação ótima.
- RN-086: Expansão incremental de raio (3 km -> 5 km -> 7 km) e timeout de 30 segundos.
"""
import uuid
from decimal import Decimal
from unittest.mock import MagicMock, patch

from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from apps.accounts.models import CustomUser, Morada
from apps.catalog.models import CategoriaItem, ItemMenu, ParceiroLoja
from apps.logistics.models import Entrega, Estafeta
from apps.logistics.tasks import (
    RAIOS_BUSCA_EXPANSAO_METROS,
    executar_algoritmo_despacho_logistico,
)
from apps.orders.models import EventoPedido, LinhaPedido, Pedido


class DespachoLogisticoAlgorithmTests(TestCase):
    """
    Testes de validação matemática, geoespacial e comportamental do algoritmo de despacho.
    """

    def setUp(self) -> None:
        cache.clear()

        # 1. Utilizador Cliente e Morada PostGIS
        self.cliente = CustomUser.objects.create_user(
            telemovel="+244923000001",
            email="cliente@delivery.local",
            nome="Cliente Despacho",
            estado=CustomUser.EstadoConta.ATIVO,
            data_nascimento=timezone.now().date() - timezone.timedelta(days=25 * 365),
        )
        self.morada_cliente = Morada.objects.create(
            utilizador=self.cliente,
            texto_endereco="Rua Direita, Luanda",
            geolocalizacao=Point(13.2350, -8.8150, srid=4326),
        )

        # 2. Loja Parceira no centro (0, 0) em coordenadas relativas para teste
        # Luanda centro: Longitude 13.2345, Latitude -8.8123
        self.ponto_loja = Point(13.2345, -8.8123, srid=4326)
        self.loja = ParceiroLoja.objects.create(
            nome="Pizzaria Central",
            nif="500123999",
            morada_texto="Avenida Central 100, Luanda",
            contacto="+244923000002",
            licenca_sanitaria="LIC-TEST-001",
            alvara="ALV-TEST-001",
            geolocalizacao=self.ponto_loja,
            raio_entrega_km=Decimal("7.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # 3. Categorias e Itens
        self.cat_comida = CategoriaItem.objects.create(
            loja=self.loja,
            nome="Comida",
            ordem_exibicao=1,
        )
        self.item_pizza = ItemMenu.objects.create(
            loja=self.loja,
            categoria=self.cat_comida,
            nome="Pizza Margherita",
            preco=4500,
            is_disponivel=True,
        )

        # 4. Pedido Normal
        self.pedido = Pedido.objects.create(
            cliente=self.cliente,
            loja=self.loja,
            estado=Pedido.EstadoPedido.PRONTO,
            subtotal=4500,
            taxa_entrega=500,
            taxa_servico=200,
            total_cobrado=5200,
        )
        self.linha = LinhaPedido.objects.create(
            pedido=self.pedido,
            item=self.item_pizza,
            quantidade=1,
            preco_unitario=4500,
            subtotal=4500,
        )

        # 5. Criação de estafetas em distâncias estratégicas
        # Estafeta A: Mota, muito próximo (~500m), alta reputação
        # 0.0045 graus lat ~ 500 metros
        self.user_estafeta_a = CustomUser.objects.create_user(
            telemovel="+244923000010",
            email="estafeta.a@delivery.local",
            nome="Estafeta Próximo",
            estado=CustomUser.EstadoConta.ATIVO,
            data_nascimento=timezone.now().date() - timezone.timedelta(days=22 * 365),
        )
        self.estafeta_a = Estafeta.objects.create(
            utilizador=self.user_estafeta_a,
            tipo_veiculo=Estafeta.TipoVeiculo.MOTA,
            carta_conducao="CC-MOTA-001",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2345, -8.8168, srid=4326),  # ~500m
            score_reputacao=Decimal("4.80"),
        )

        # Estafeta B: Carro, distância média (~4 km - fora de 3km, dentro de 5km)
        # 0.036 graus lat ~ 4000 metros
        self.user_estafeta_b = CustomUser.objects.create_user(
            telemovel="+244923000020",
            email="estafeta.b@delivery.local",
            nome="Estafeta Médio",
            estado=CustomUser.EstadoConta.ATIVO,
            data_nascimento=timezone.now().date() - timezone.timedelta(days=30 * 365),
        )
        self.estafeta_b = Estafeta.objects.create(
            utilizador=self.user_estafeta_b,
            tipo_veiculo=Estafeta.TipoVeiculo.CARRO,
            carta_conducao="CC-CAR-002",
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2345, -8.8483, srid=4326),  # ~4000m
            score_reputacao=Decimal("4.95"),
        )

        # Estafeta C: Bicicleta, no limite (~6 km - dentro de 7km)
        # 0.054 graus lat ~ 6000 metros
        self.user_estafeta_c = CustomUser.objects.create_user(
            telemovel="+244923000030",
            email="estafeta.c@delivery.local",
            nome="Estafeta Longe",
            estado=CustomUser.EstadoConta.ATIVO,
            data_nascimento=timezone.now().date() - timezone.timedelta(days=19 * 365),
        )
        self.estafeta_c = Estafeta.objects.create(
            utilizador=self.user_estafeta_c,
            tipo_veiculo=Estafeta.TipoVeiculo.BICICLETA,
            status_onboarding=Estafeta.StatusOnboarding.APROVADO,
            is_online=True,
            ultima_geolocalizacao=Point(13.2345, -8.8663, srid=4326),  # ~6000m
            score_reputacao=Decimal("4.50"),
        )

    @patch("apps.logistics.tasks.task_timeout_oferta_estafeta.apply_async")
    @patch("apps.logistics.tasks.get_channel_layer")
    def test_despacho_seleciona_candidato_no_raio_inicial_3km(
        self,
        mock_get_channel_layer,
        mock_apply_async,
    ) -> None:
        """
        RN-084 / RN-085 / RN-086:
        Verifica que o algoritmo localiza o Estafeta A no raio inicial de 3000 metros,
        calcula o ScoreDespacho, agenda o timeout de 30s e regista o evento de auditoria.
        """
        res = executar_algoritmo_despacho_logistico(pedido_id=str(self.pedido.id), tentativa_raio_index=0)

        self.assertEqual(res["status"], "oferta_enviada")
        self.assertEqual(res["estafeta_ofertado"]["id"], str(self.estafeta_a.id))
        self.assertEqual(res["raio_utilizado_metros"], 3000)

        # Verifica que o timeout de 30s foi agendado
        mock_apply_async.assert_called_once()
        args, kwargs = mock_apply_async.call_args
        self.assertEqual(kwargs.get("countdown"), 30)
        self.assertEqual(args[0][1], str(self.estafeta_a.id))

        # Verifica registo de auditoria imutável
        evento = EventoPedido.objects.filter(
            pedido=self.pedido,
            tipo_evento=EventoPedido.TipoEvento.DELIVERY_OFFERED,
        ).first()
        self.assertIsNotNone(evento)
        self.assertEqual(evento.autor, "SISTEMA:DESPACHO")
        self.assertEqual(evento.dados_adicionais["estafeta_id"], str(self.estafeta_a.id))

    @patch("apps.logistics.tasks.executar_algoritmo_despacho_logistico.apply_async")
    def test_despacho_expansao_quando_sem_candidatos_em_3km(
        self,
        mock_self_apply_async,
    ) -> None:
        """
        RN-086:
        Quando nenhum estafeta está no raio de 3000m, o algoritmo agenda a expansão
        para o próximo raio (5000m).
        """
        # Desliga o Estafeta A
        self.estafeta_a.is_online = False
        self.estafeta_a.save()

        res = executar_algoritmo_despacho_logistico(pedido_id=str(self.pedido.id), tentativa_raio_index=0)

        self.assertEqual(res["status"], "expansao_raio_agendada")
        self.assertEqual(res["proximo_raio_index"], 1)
        self.assertEqual(res["proximo_raio_m"], 5000)

        # Verifica que re-agendou com index 1
        mock_self_apply_async.assert_called_once_with(
            args=[str(self.pedido.id), 1],
            countdown=2,
        )

    @patch("apps.logistics.tasks.task_timeout_oferta_estafeta.apply_async")
    def test_despacho_encontra_no_raio_expandido_5km(
        self,
        mock_apply_async,
    ) -> None:
        """
        RN-086: No segundo degrau (5000m), deve selecionar o Estafeta B (~4000m).
        """
        # Desliga o Estafeta A
        self.estafeta_a.is_online = False
        self.estafeta_a.save()

        res = executar_algoritmo_despacho_logistico(pedido_id=str(self.pedido.id), tentativa_raio_index=1)

        self.assertEqual(res["status"], "oferta_enviada")
        self.assertEqual(res["estafeta_ofertado"]["id"], str(self.estafeta_b.id))
        self.assertEqual(res["raio_utilizado_metros"], 5000)

    def test_despacho_escassez_critica_quando_esgota_7km(self) -> None:
        """
        RN-086: Quando o teto máximo de 7000m é excedido, dispara o alerta de escassez crítica.
        """
        res = executar_algoritmo_despacho_logistico(
            pedido_id=str(self.pedido.id),
            tentativa_raio_index=len(RAIOS_BUSCA_EXPANSAO_METROS),
        )

        self.assertEqual(res["status"], "escassez_critica_sem_estafetas")
        self.assertTrue(cache.get(f"logistics:shortage_alert:{self.pedido.id}"))

    @patch("apps.logistics.tasks.task_timeout_oferta_estafeta.apply_async")
    def test_despacho_exclusao_estafetas_menores_em_pedidos_com_alcool(
        self,
        mock_apply_async,
    ) -> None:
        """
        RN-044 / RN-084:
        Se o pedido contiver bebidas alcoólicas, estafetas com menos de 18 anos
        devem ser rigorosamente excluídos da seleção.
        """
        # Cria item alcoólico
        item_cerveja = ItemMenu.objects.create(
            loja=self.loja,
            categoria=self.cat_comida,
            nome="Cerveja Artesanal",
            descricao="Bebida alcoólica fermentada",
            preco=1200,
            is_disponivel=True,
        )
        LinhaPedido.objects.create(
            pedido=self.pedido,
            item=item_cerveja,
            quantidade=2,
            preco_unitario=1200,
            subtotal=2400,
        )

        # Transforma o Estafeta A em menor de idade (17 anos)
        self.user_estafeta_a.data_nascimento = timezone.now().date() - timezone.timedelta(days=17 * 365)
        self.user_estafeta_a.save()

        # Executa no raio de 3000m: Estafeta A é excluído por idade, logo não há candidatos em 3km
        res = executar_algoritmo_despacho_logistico(pedido_id=str(self.pedido.id), tentativa_raio_index=0)
        self.assertEqual(res["status"], "expansao_raio_agendada")

