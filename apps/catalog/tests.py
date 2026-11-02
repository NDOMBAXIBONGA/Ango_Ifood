"""
Testes unitários e de integração para a API do Portal do Parceiro (RN-011 a RN-020).
"""
from datetime import time, timedelta
from decimal import Decimal

from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.test import TestCase
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient

from apps.accounts.models import CustomUser
from apps.catalog.models import CategoriaItem, HorarioFuncionamento, ItemMenu, ParceiroLoja


class PartnerPortalApiTests(TestCase):
    def setUp(self) -> None:
        self.client = APIClient()

        # Cria Utilizador Parceiro
        self.user_parceiro = CustomUser.objects.create_user(
            telemovel="+244923777888",
            email="parceiro@test.com",
            nome="Gerente Restaurante",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # Cria Loja Ativa associada ao Parceiro (RN-010, RN-011)
        self.loja = ParceiroLoja.objects.create(
            nome="Hamburgueria Central Luanda",
            proprietario=self.user_parceiro,
            nif="5000999888",
            morada_texto="Avenida 4 de Fevereiro, Luanda",
            contacto="+244923777888",
            licenca_sanitaria="LIC-2026-999",
            alvara="ALV-2026-888",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            raio_entrega_km=Decimal("7.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # Cria Categoria no Menu
        self.categoria = CategoriaItem.objects.create(
            loja=self.loja,
            nome="Hambúrgueres",
            ordem_exibicao=1,
        )

        # URLs dos endpoints
        self.url_status = reverse("partner-store:store-status")
        self.url_hours = reverse("partner-store:store-hours")
        self.url_items = reverse("partner-catalog:partner-catalog-items-list")

        # Autentica o cliente com o utilizador parceiro
        self.client.force_authenticate(user=self.user_parceiro)

    def test_permission_denied_for_unauthenticated_or_non_partner(self) -> None:
        """RN-011: Utilizadores sem loja ativa recebem 403 Forbidden."""
        self.client.force_authenticate(user=None)
        res = self.client.patch(self.url_status, {"is_pausa_temporaria": True}, format="json")
        self.assertEqual(res.status_code, status.HTTP_401_UNAUTHORIZED)

        user_sem_loja = CustomUser.objects.create_user(
            telemovel="+244923000111",
            email="semloja@test.com",
            nome="Sem Loja",
            estado=CustomUser.EstadoConta.ATIVO,
        )
        self.client.force_authenticate(user=user_sem_loja)
        res_sem_loja = self.client.patch(self.url_status, {"is_pausa_temporaria": True}, format="json")
        self.assertEqual(res_sem_loja.status_code, status.HTTP_403_FORBIDDEN)

    def test_patch_store_status_pausa_temporaria_rn013(self) -> None:
        """RN-013: Ativação de pausa temporária calcula timestamp de reativação e atualiza BD/Redis."""
        payload = {
            "is_pausa_temporaria": True,
            "duracao_minutos": 45,
        }
        response = self.client.patch(self.url_status, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["estado"], ParceiroLoja.EstadoLoja.PAUSADO)
        self.assertTrue(response.data["is_pausa_temporaria"])
        self.assertIsNotNone(response.data["reativacao_automatica_em"])

        # Verifica na base de dados
        self.loja.refresh_from_db()
        self.assertEqual(self.loja.estado, ParceiroLoja.EstadoLoja.PAUSADO)

        # Verifica na cache Redis
        cached = cache.get(f"catalog:store:{self.loja.id}:pause_status")
        self.assertIsNotNone(cached)
        self.assertTrue(cached["is_pausa_temporaria"])

    def test_patch_store_status_cancelar_pausa_rn013(self) -> None:
        """RN-013: Cancelar pausa retorna estado para ATIVO e limpa a cache."""
        self.loja.estado = ParceiroLoja.EstadoLoja.PAUSADO
        self.loja.save()

        payload = {"is_pausa_temporaria": False}
        response = self.client.patch(self.url_status, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["estado"], ParceiroLoja.EstadoLoja.ATIVO)

        self.loja.refresh_from_db()
        self.assertEqual(self.loja.estado, ParceiroLoja.EstadoLoja.ATIVO)

    def test_crud_item_menu_e_invalidacao_indisponivel_rn014_rn015_rn016(self) -> None:
        """RN-014, RN-015, RN-016: Cria item e no update is_disponivel=False invalida cache imediatamente."""
        # Cria Item
        payload_create = {
            "categoria": str(self.categoria.id),
            "nome": "Hambúrguer Gourmet",
            "descricao": "Carne bovina 200g, queijo cheddar, bacon e molho especial.",
            "preco": 4500,  # Unidade inteira mínima (4500 Kz)
            "imagem_url": "https://cdn.delivery.local/burger.jpg",
            "alergenos": ["gluten", "lactose"],
            "is_disponivel": True,
        }
        res_create = self.client.post(self.url_items, payload_create, format="json")
        self.assertEqual(res_create.status_code, status.HTTP_201_CREATED)
        item_id = res_create.data["id"]

        # Atualiza para indisponível
        url_detail = f"{self.url_items}{item_id}/"
        res_update = self.client.patch(url_detail, {"is_disponivel": False}, format="json")
        self.assertEqual(res_update.status_code, status.HTTP_200_OK)
        self.assertFalse(res_update.data["is_disponivel"])

        # Verifica se o marcador de invalidação de cache foi criado no Redis
        last_invalidation = cache.get(f"catalog:store:{self.loja.id}:last_invalidation")
        self.assertIsNotNone(last_invalidation)
        self.assertEqual(last_invalidation["item_id"], item_id)
        self.assertFalse(last_invalidation["is_disponivel"])

    def test_store_hours_post_and_overlap_validation_rn012(self) -> None:
        """RN-012: Valida sobreposição de horários no mesmo dia da semana."""
        # Cria primeiro turno: 09:00 às 14:00 (Segunda-feira = 0)
        payload_1 = {
            "dia_semana": 0,
            "hora_abertura": "09:00:00",
            "hora_fecho": "14:00:00",
        }
        res_1 = self.client.post(self.url_hours, payload_1, format="json")
        self.assertEqual(res_1.status_code, status.HTTP_201_CREATED)

        # Tenta criar turno com sobreposição: 12:00 às 16:00 na Segunda-feira (colide das 12:00 às 14:00)
        payload_overlap = {
            "dia_semana": 0,
            "hora_abertura": "12:00:00",
            "hora_fecho": "16:00:00",
        }
        res_overlap = self.client.post(self.url_hours, payload_overlap, format="json")
        self.assertEqual(res_overlap.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("RN-012", str(res_overlap.data))

        # Turno válido sem colisão: 18:00 às 23:00 na Segunda-feira
        payload_valido = {
            "dia_semana": 0,
            "hora_abertura": "18:00:00",
            "hora_fecho": "23:00:00",
        }
        res_valido = self.client.post(self.url_hours, payload_valido, format="json")
        self.assertEqual(res_valido.status_code, status.HTTP_201_CREATED)


class StoreDiscoveryViewSetTests(TestCase):
    """
    Testes de integração para a ViewSet de Descoberta Geoespacial de Lojas (RN-025 a RN-030).
    Valida:
    - RN-025: Geofencing espacial PostGIS e validação de parâmetros lat/lng (HTTP 400 se ausentes).
    - RN-026: Disponibilidade operacional dinâmica e parâmetro `show_closed`.
    - RN-027: Algoritmo de ranking unificado (patrocinados, distância, reputação).
    - RN-028 / RN-029: Filtros de categoria, avaliação mínima, entrega grátis e max_eta.
    """

    def setUp(self) -> None:
        self.client = APIClient()
        self.url_discovery = reverse("catalog:store-discovery-list")

        # Ponto central de Luanda (Mutamba / Baixa): Longitude 13.2345, Latitude -8.8123
        self.ponto_centro_luanda = Point(13.2345, -8.8123, srid=4326)

        # Loja 1: Próxima (a ~500m do centro), aberta, com entrega grátis e score 4.90
        self.loja_proxima = ParceiroLoja.objects.create(
            nome="Pizzaria Bella Luanda",
            nif="500111222",
            morada_texto="Rua Rainha Ginga, Luanda",
            contacto="+244923111222",
            licenca_sanitaria="LIC-2026-001",
            alvara="ALV-2026-001",
            geolocalizacao=Point(13.2360, -8.8130, srid=4326),  # ~200 metros
            raio_entrega_km=Decimal("5.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
            score_reputacao=Decimal("4.90"),
            is_patrocinado=False,
            is_entrega_gratis=True,
        )
        self.cat_pizza = CategoriaItem.objects.create(
            loja=self.loja_proxima,
            nome="Pizzas Tradicionais",
            ordem_exibicao=1,
        )

        # Horário 24/7 para a loja próxima estar sempre aberta
        for dia in range(7):
            HorarioFuncionamento.objects.create(
                loja=self.loja_proxima,
                dia_semana=dia,
                hora_abertura=time(0, 0),
                hora_fecho=time(23, 59, 59),
            )

        # Loja 2: Média distância (~2.5km), aberta, patrocinada (is_patrocinado=True), score 4.50
        self.loja_patrocinada = ParceiroLoja.objects.create(
            nome="Sushi Luanda Premium",
            nif="500222333",
            morada_texto="Ilha de Luanda",
            contacto="+244923222333",
            licenca_sanitaria="LIC-2026-002",
            alvara="ALV-2026-002",
            geolocalizacao=Point(13.2180, -8.7950, srid=4326),  # ~2.5 km
            raio_entrega_km=Decimal("6.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
            score_reputacao=Decimal("4.50"),
            is_patrocinado=True,
            is_entrega_gratis=False,
        )
        self.cat_sushi = CategoriaItem.objects.create(
            loja=self.loja_patrocinada,
            nome="Sushi & Sashimi",
            ordem_exibicao=1,
        )
        for dia in range(7):
            HorarioFuncionamento.objects.create(
                loja=self.loja_patrocinada,
                dia_semana=dia,
                hora_abertura=time(0, 0),
                hora_fecho=time(23, 59, 59),
            )

        # Loja 3: Fechada (sem turnos de funcionamento), próxima (~800m), score 4.80
        self.loja_fechada = ParceiroLoja.objects.create(
            nome="Hamburgueria Noturna",
            nif="500333444",
            morada_texto="Kinaxixi, Luanda",
            contacto="+244923333444",
            licenca_sanitaria="LIC-2026-003",
            alvara="ALV-2026-003",
            geolocalizacao=Point(13.2380, -8.8180, srid=4326),
            raio_entrega_km=Decimal("4.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
            score_reputacao=Decimal("4.80"),
            is_patrocinado=False,
            is_entrega_gratis=False,
        )
        # Não adiciona horários para que esteja sempre fechada

        # Loja 4: Muito distante (~35km em Viana), fora do raio de 5km
        self.loja_fora_do_raio = ParceiroLoja.objects.create(
            nome="Restaurante Viana Express",
            nif="500444555",
            morada_texto="Viana, Luanda",
            contacto="+244923444555",
            licenca_sanitaria="LIC-2026-004",
            alvara="ALV-2026-004",
            geolocalizacao=Point(13.3700, -8.9100, srid=4326),  # ~25 km
            raio_entrega_km=Decimal("5.00"),  # Não cobre o centro
            estado=ParceiroLoja.EstadoLoja.ATIVO,
            score_reputacao=Decimal("5.00"),
            is_patrocinado=True,
            is_entrega_gratis=True,
        )
        for dia in range(7):
            HorarioFuncionamento.objects.create(
                loja=self.loja_fora_do_raio,
                dia_semana=dia,
                hora_abertura=time(0, 0),
                hora_fecho=time(23, 59, 59),
            )

    def test_missing_coordinates_returns_http_400_rn025(self) -> None:
        """RN-025: A ausência de lat ou lng deve retornar HTTP 400 Bad Request."""
        # Sem parâmetros
        res_sem_params = self.client.get(self.url_discovery)
        self.assertEqual(res_sem_params.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("lat", res_sem_params.data)
        self.assertIn("lng", res_sem_params.data)

        # Apenas com latitude
        res_sem_lng = self.client.get(self.url_discovery, {"lat": -8.8123})
        self.assertEqual(res_sem_lng.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("lng", res_sem_lng.data)

        # Coordenadas fora dos limites
        res_invalido = self.client.get(self.url_discovery, {"lat": 150.0, "lng": 13.2345})
        self.assertEqual(res_invalido.status_code, status.HTTP_400_BAD_REQUEST)

    def test_geofencing_excludes_out_of_radius_store_rn025(self) -> None:
        """RN-025: Lojas fora do raio de entrega configurado são estritamente excluídas."""
        params = {"lat": -8.8123, "lng": 13.2345}
        res = self.client.get(self.url_discovery, params)

        self.assertEqual(res.status_code, status.HTTP_200_OK)
        ids_retornados = [item["id"] for item in res.data["results"]]

        self.assertIn(str(self.loja_proxima.id), ids_retornados)
        self.assertIn(str(self.loja_patrocinada.id), ids_retornados)
        # A loja de Viana está a ~25km e tem raio de 5km -> deve ser excluída
        self.assertNotIn(str(self.loja_fora_do_raio.id), ids_retornados)

    def test_operational_availability_show_closed_rn026(self) -> None:
        """RN-026: Por padrão, lojas fechadas são omitidas. Com show_closed=True surgem no fim."""
        params_abertas = {"lat": -8.8123, "lng": 13.2345, "show_closed": False}
        res_abertas = self.client.get(self.url_discovery, params_abertas)

        self.assertEqual(res_abertas.status_code, status.HTTP_200_OK)
        ids_abertas = [item["id"] for item in res_abertas.data["results"]]
        self.assertNotIn(str(self.loja_fechada.id), ids_abertas)

        # Agora solicitando com show_closed=True
        params_com_fechadas = {"lat": -8.8123, "lng": 13.2345, "show_closed": True}
        res_com_fechadas = self.client.get(self.url_discovery, params_com_fechadas)

        self.assertEqual(res_com_fechadas.status_code, status.HTTP_200_OK)
        resultados = res_com_fechadas.data["results"]
        ids_com_fechadas = [item["id"] for item in resultados]
        self.assertIn(str(self.loja_fechada.id), ids_com_fechadas)

        # Verifica se as abertas vêm primeiro que a fechada
        pos_aberta = next(i for i, item in enumerate(resultados) if item["id"] == str(self.loja_proxima.id))
        pos_fechada = next(i for i, item in enumerate(resultados) if item["id"] == str(self.loja_fechada.id))
        self.assertLess(pos_aberta, pos_fechada)

    def test_unified_ranking_algorithm_rn027(self) -> None:
        """
        RN-027: O ranking unificado prioriza lojas abertas, depois patrocinadas (-is_patrocinado),
        depois distância linear e reputação.
        """
        params = {"lat": -8.8123, "lng": 13.2345}
        res = self.client.get(self.url_discovery, params)

        self.assertEqual(res.status_code, status.HTTP_200_OK)
        resultados = res.data["results"]

        # A loja patrocinada deve vir em 1.º lugar entre as abertas, mesmo estando a 2.5km
        # enquanto a pizzaria não patrocinada está a apenas ~200m
        self.assertEqual(resultados[0]["id"], str(self.loja_patrocinada.id))
        self.assertTrue(resultados[0]["is_patrocinado"])
        self.assertEqual(resultados[0]["etiqueta_patrocinado"], "Patrocinado")

        self.assertEqual(resultados[1]["id"], str(self.loja_proxima.id))
        self.assertFalse(resultados[1]["is_patrocinado"])

    def test_additional_filters_rn028(self) -> None:
        """RN-028: Validação dos filtros de tipo_cozinha, entrega_gratis e avaliacao_min."""
        # 1. Filtro por tipo_cozinha / categoria
        res_pizza = self.client.get(self.url_discovery, {
            "lat": -8.8123,
            "lng": 13.2345,
            "tipo_cozinha": "Pizza",
        })
        ids_pizza = [item["id"] for item in res_pizza.data["results"]]
        self.assertIn(str(self.loja_proxima.id), ids_pizza)
        self.assertNotIn(str(self.loja_patrocinada.id), ids_pizza)

        # 2. Filtro por entrega_gratis
        res_gratis = self.client.get(self.url_discovery, {
            "lat": -8.8123,
            "lng": 13.2345,
            "entrega_gratis": True,
        })
        ids_gratis = [item["id"] for item in res_gratis.data["results"]]
        self.assertIn(str(self.loja_proxima.id), ids_gratis)
        self.assertNotIn(str(self.loja_patrocinada.id), ids_gratis)

        # 3. Filtro por avaliacao_min
        res_reputacao = self.client.get(self.url_discovery, {
            "lat": -8.8123,
            "lng": 13.2345,
            "avaliacao_min": "4.80",
        })
        ids_reputacao = [item["id"] for item in res_reputacao.data["results"]]
        self.assertIn(str(self.loja_proxima.id), ids_reputacao)
        self.assertNotIn(str(self.loja_patrocinada.id), ids_reputacao)

