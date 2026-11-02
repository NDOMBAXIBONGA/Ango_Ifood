"""
Testes unitários e de integração para a API do Carrinho de Compras ('cart').
Cobre exaustivamente as regras de negócio:
- RN-040: Unicidade de Loja Parceira no Carrinho com erro estruturado HTTP 400 e substituição;
- RN-042: Limites de Quantidade por Item (default=20 unidades);
- RN-044: Restrição Legal de Idade para Produtos Regulados (Álcool/Tabaco) com HTTP 403 Forbidden;
- RN-063: Preferências Automáticas de Substituição (Remover, Equivalente, Cancelar).
"""
import uuid
from decimal import Decimal

from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.urls import reverse
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from apps.accounts.models import CustomUser
from apps.cart.models import PreferenciaSubstituicao
from apps.cart.services import CartService
from apps.catalog.models import CategoriaItem, ItemMenu, ParceiroLoja


class CartAPITests(APITestCase):
    """
    Testes de cobertura das regras RN-040, RN-042, RN-044 e RN-063 no endpoint /api/v1/cart/.
    """

    def setUp(self) -> None:
        cache.clear()

        # 1. Utilizador Adulto (>= 18 anos)
        self.user_adulto = CustomUser.objects.create_user(
            telemovel="+244923111222",
            email="adulto@delivery.local",
            nome="Utilizador Adulto",
            estado=CustomUser.EstadoConta.ATIVO,
            data_nascimento=timezone.now().date() - timezone.timedelta(days=25 * 365),
        )

        # 2. Utilizador Menor de Idade (< 18 anos)
        self.user_menor = CustomUser.objects.create_user(
            telemovel="+244923111333",
            email="menor@delivery.local",
            nome="Utilizador Menor",
            estado=CustomUser.EstadoConta.ATIVO,
            data_nascimento=timezone.now().date() - timezone.timedelta(days=16 * 365),
        )

        # 3. Utilizador Sem Data de Nascimento
        self.user_sem_nascimento = CustomUser.objects.create_user(
            telemovel="+244923111444",
            email="semdata@delivery.local",
            nome="Utilizador Sem Data",
            estado=CustomUser.EstadoConta.ATIVO,
            data_nascimento=None,
        )

        # 4. Loja A (Pizzaria)
        self.loja_a = ParceiroLoja.objects.create(
            nome="Pizzaria da Baixa",
            nif="500111222",
            morada_texto="Rua da Prata 10, Luanda",
            contacto="+244923001001",
            licenca_sanitaria="LIC-001",
            alvara="ALV-001",
            geolocalizacao=Point(13.2345, -8.8123, srid=4326),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )
        self.cat_comida_a = CategoriaItem.objects.create(
            loja=self.loja_a,
            nome="Comida",
            ordem_exibicao=1,
        )
        self.item_pizza = ItemMenu.objects.create(
            loja=self.loja_a,
            categoria=self.cat_comida_a,
            nome="Pizza Quatro Queijos",
            descricao="Pizza tradicional italiana",
            preco=5000,
            is_disponivel=True,
        )
        self.item_cerveja = ItemMenu.objects.create(
            loja=self.loja_a,
            categoria=self.cat_comida_a,
            nome="Cerveja Nacional 33cl",
            descricao="Bebida alcoólica fresca",
            preco=800,
            is_disponivel=True,
        )

        # 5. Loja B (Hamburgueria)
        self.loja_b = ParceiroLoja.objects.create(
            nome="Hamburgueria Central",
            nif="500333444",
            morada_texto="Avenida Central 20, Luanda",
            contacto="+244923002002",
            licenca_sanitaria="LIC-002",
            alvara="ALV-002",
            geolocalizacao=Point(13.2355, -8.8133, srid=4326),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )
        self.cat_comida_b = CategoriaItem.objects.create(
            loja=self.loja_b,
            nome="Hambúrgueres",
            ordem_exibicao=1,
        )
        self.item_burger = ItemMenu.objects.create(
            loja=self.loja_b,
            categoria=self.cat_comida_b,
            nome="Hambúrguer Artesanal",
            descricao="Carne maturada com queijo",
            preco=4500,
            is_disponivel=True,
        )

        self.url_add_item = reverse("cart:cart-items")
        self.url_cart_root = reverse("cart:cart-root")
        self.url_substitute = reverse("cart:cart-substitute-preference")

    # =========================================================================
    # TESTES DA REGRA RN-040: UNICIDADE DE LOJA NO CARRINHO
    # =========================================================================

    def test_adicionar_item_primeira_loja_sucesso(self) -> None:
        """Adiciona item ao carrinho vazio com sucesso."""
        self.client.force_authenticate(user=self.user_adulto)

        payload = {
            "item_id": str(self.item_pizza.id),
            "quantidade": 2,
        }
        response = self.client.post(self.url_add_item, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        data = response.json()
        self.assertEqual(data["loja_id"], str(self.loja_a.id))
        self.assertEqual(data["total_itens"], 2)
        self.assertEqual(data["subtotal"], 10000)

    def test_rn040_bloqueia_item_de_outra_loja_com_payload_estruturado_400(self) -> None:
        """
        RN-040: Rejeita a adição de item de loja diferente com HTTP 400 Bad Request
        e payload estruturado com detalhe das duas lojas.
        """
        self.client.force_authenticate(user=self.user_adulto)

        # 1. Adiciona pizza da Loja A
        self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_pizza.id), "quantidade": 1},
            format="json",
        )

        # 2. Tenta adicionar hambúrguer da Loja B sem substituir
        payload = {
            "item_id": str(self.item_burger.id),
            "quantidade": 1,
            "substituir_carrinho_existente": False,
        }
        response = self.client.post(self.url_add_item, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        data = response.json()
        self.assertEqual(data.get("erro"), "RN-040_LOJA_DIFERENTE")
        self.assertEqual(data.get("codigo"), "STORE_CONFLICT")
        self.assertEqual(data["loja_atual"]["id"], str(self.loja_a.id))
        self.assertEqual(data["nova_loja"]["id"], str(self.loja_b.id))
        self.assertEqual(data.get("acao_sugerida"), "substituir_carrinho")

    def test_rn040_permite_substituicao_quando_flag_for_true(self) -> None:
        """
        RN-040: Quando o cliente confirma 'substituir_carrinho_existente=True',
        o carrinho anterior é limpo e assume a nova loja.
        """
        self.client.force_authenticate(user=self.user_adulto)

        # 1. Adiciona da Loja A
        self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_pizza.id), "quantidade": 1},
            format="json",
        )

        # 2. Substitui pela Loja B com flag ativada
        payload = {
            "item_id": str(self.item_burger.id),
            "quantidade": 3,
            "substituir_carrinho_existente": True,
        }
        response = self.client.post(self.url_add_item, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        data = response.json()
        self.assertEqual(data["loja_id"], str(self.loja_b.id))
        self.assertEqual(data["total_itens"], 3)
        self.assertEqual(data["subtotal"], 13500)
        self.assertEqual(len(data["itens"]), 1)
        self.assertEqual(data["itens"][0]["item_id"], str(self.item_burger.id))

    # =========================================================================
    # TESTES DA REGRA RN-042: LIMITES DE QUANTIDADE
    # =========================================================================

    def test_rn042_bloqueia_quantidade_acima_do_limite_20_unidades(self) -> None:
        """RN-042: Barra adição quando a quantidade de um item excede 20 unidades."""
        self.client.force_authenticate(user=self.user_adulto)

        payload = {
            "item_id": str(self.item_pizza.id),
            "quantidade": 21,
        }
        response = self.client.post(self.url_add_item, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        data = response.json()
        self.assertIn("quantidade", data)
        self.assertEqual(data.get("limite_maximo_permitido"), 20)

    def test_rn042_bloqueia_acumulacao_que_ultrapasse_limite(self) -> None:
        """RN-042: Barra se a soma com itens já no carrinho exceder 20 unidades."""
        self.client.force_authenticate(user=self.user_adulto)

        # Adiciona 15 unidades primeiro
        self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_pizza.id), "quantidade": 15},
            format="json",
        )

        # Tenta adicionar mais 6 unidades (total seria 21)
        response = self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_pizza.id), "quantidade": 6},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        data = response.json()
        self.assertIn("quantidade", data)
        self.assertEqual(data.get("quantidade_atual_no_carrinho"), 15)

    # =========================================================================
    # TESTES DA REGRA RN-044: RESTRIÇÃO DE IDADE (ÁLCOOL / TABACO) -> HTTP 403
    # =========================================================================

    def test_rn044_bloqueia_menor_de_idade_com_http_403_forbidden(self) -> None:
        """
        RN-044: Impede terminantemente a adição de bebida alcoólica a utilizadores
        com menos de 18 anos, retornando HTTP 403 Forbidden.
        """
        self.client.force_authenticate(user=self.user_menor)

        payload = {
            "item_id": str(self.item_cerveja.id),
            "quantidade": 1,
        }
        response = self.client.post(self.url_add_item, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        data = response.json()
        self.assertEqual(data.get("erro"), "RN-044_MENOR_DE_IDADE")
        self.assertEqual(data.get("codigo"), "AGE_RESTRICTION_FORBIDDEN")
        self.assertEqual(data.get("idade_minima_legal"), 18)

    def test_rn044_bloqueia_utilizador_sem_data_nascimento_com_http_403(self) -> None:
        """RN-044: Bloqueia utilizador sem data de nascimento comprovada com HTTP 403."""
        self.client.force_authenticate(user=self.user_sem_nascimento)

        payload = {
            "item_id": str(self.item_cerveja.id),
            "quantidade": 1,
        }
        response = self.client.post(self.url_add_item, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)
        data = response.json()
        self.assertEqual(data.get("codigo"), "BIRTHDATE_REQUIRED")

    def test_rn044_permite_adulto_adicionar_artigo_alcoolico(self) -> None:
        """RN-044: Utilizador adulto (>= 18 anos) adiciona com sucesso produto alcoólico."""
        self.client.force_authenticate(user=self.user_adulto)

        payload = {
            "item_id": str(self.item_cerveja.id),
            "quantidade": 2,
        }
        response = self.client.post(self.url_add_item, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        data = response.json()
        self.assertTrue(data["itens"][0]["contem_artigos_restritos"])
        self.assertEqual(data["itens"][0]["preco_unitario"], 800)

    # =========================================================================
    # TESTES DA REGRA RN-063: PREFERÊNCIAS DE SUBSTITUIÇÃO AUTOMÁTICA
    # =========================================================================

    def test_rn063_definir_preferencia_global_no_carrinho(self) -> None:
        """
        RN-063: Define a preferência de substituição padrão (REMOVER, SUBSTITUIR_EQUIVALENTE, CANCELAR_ITEM).
        """
        self.client.force_authenticate(user=self.user_adulto)

        # Adiciona item inicial
        self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_pizza.id), "quantidade": 1},
            format="json",
        )

        # Define preferência global para REMOVER
        payload = {
            "preferencia": "REMOVER",
        }
        response = self.client.post(self.url_substitute, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.json()
        self.assertEqual(data["preferencia_definida"], "REMOVER")
        self.assertEqual(data["carrinho"]["preferencia_substituicao_padrao"], "REMOVER")
        self.assertEqual(data["carrinho"]["itens"][0]["preferencia_substituicao"], "REMOVER")

    def test_rn063_definir_preferencia_especifica_por_item(self) -> None:
        """RN-063: Define preferência de substituição para um item específico."""
        self.client.force_authenticate(user=self.user_adulto)

        # Adiciona pizza e cerveja
        self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_pizza.id), "quantidade": 1},
            format="json",
        )
        self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_cerveja.id), "quantidade": 1},
            format="json",
        )

        # Define preferência específica para CANCELAR_ITEM na cerveja
        payload = {
            "item_id": str(self.item_cerveja.id),
            "preferencia": "CANCELAR_ITEM",
        }
        response = self.client.post(self.url_substitute, payload, format="json")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.json()
        carrinho = data["carrinho"]
        cerveja_item = next(it for it in carrinho["itens"] if it["item_id"] == str(self.item_cerveja.id))
        self.assertEqual(cerveja_item["preferencia_substituicao"], "CANCELAR_ITEM")

    # =========================================================================
    # TESTES DE GESTÃO E LIMPEZA DO CARRINHO
    # =========================================================================

    def test_limpar_carrinho_sucesso(self) -> None:
        """Verifica a limpeza integral do carrinho via DELETE /api/v1/cart/."""
        self.client.force_authenticate(user=self.user_adulto)

        self.client.post(
            self.url_add_item,
            {"item_id": str(self.item_pizza.id), "quantidade": 1},
            format="json",
        )

        response = self.client.delete(self.url_cart_root)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        data = response.json()
        self.assertEqual(data["status"], "carrinho_limpo")
        self.assertEqual(data["carrinho"]["total_itens"], 0)
        self.assertIsNone(data["carrinho"]["loja_id"])

