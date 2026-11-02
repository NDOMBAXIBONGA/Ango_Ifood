"""
Testes unitários exaustivos para o motor financeiro OrderPricingEngineService ('orders').
Valida rigorosamente:
- RN-041: Pedido mínimo por loja e taxa de pequeno pedido;
- RN-043: Congelamento da cotação em cache Redis por 15 minutos (TTL = 900s);
- RN-050: Decomposição financeira e cálculo do total;
- RN-051: Taxa de entrega geográfica calculada via PostGIS;
- RN-052: Multiplicador dinâmico em sobrecarga (Surge Pricing) até 2.0x;
- RN-053: Taxa de serviço (5%) com limites de teto mínimo e máximo;
- RN-055 / RN-056: Descontos de cupão e repartição do financiamento;
- RN-059: Aritmética estritamente inteira em unidades monetárias mínimas.
"""
from decimal import Decimal
import uuid

from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from apps.accounts.models import CustomUser, Morada
from apps.catalog.models import CategoriaItem, GrupoOpcao, ItemMenu, OpcaoItem, ParceiroLoja
from apps.orders.pricing_engine import OrderPricingEngineError, OrderPricingEngineService
from apps.promotions.models import CupaoDesconto


class OrderPricingEngineServiceTests(TestCase):
    """Bateria de testes de precisão e conformidade financeira para o OrderPricingEngineService."""

    def setUp(self) -> None:
        cache.clear()

        # 1. Utilizador Cliente
        self.cliente = CustomUser.objects.create_user(
            telemovel="+244923888777",
            email="cliente.pricing@delivery.local",
            nome="Cliente Pricing Engine",
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # 2. Morada PostGIS do Cliente (aproximadamente 3 km da loja)
        # 1 grau de latitude ~ 111.32 km -> 0.027 graus ~ 3.0 km
        self.ponto_cliente = Point(13.2345, -8.8393, srid=4326)
        self.morada = Morada.objects.create(
            utilizador=self.cliente,
            texto_endereco="Rua dos Coqueiros 15, Luanda",
            geolocalizacao=self.ponto_cliente,
        )

        # 3. Loja Parceira com geolocalização PostGIS e pedido mínimo de 2.000 Kz (200_000 un. mínimas)
        self.ponto_loja = Point(13.2345, -8.8123, srid=4326)
        self.loja = ParceiroLoja.objects.create(
            nome="Restaurante Financeiro",
            nif="500777111",
            morada_texto="Avenida Central 1, Luanda",
            contacto="+244923000777",
            licenca_sanitaria="LIC-FIN-001",
            alvara="ALV-FIN-001",
            geolocalizacao=self.ponto_loja,
            raio_entrega_km=Decimal("7.00"),
            estado=ParceiroLoja.EstadoLoja.ATIVO,
        )

        # 4. Catálogo: Categoria, Itens e Grupos de Opções
        self.categoria = CategoriaItem.objects.create(
            loja=self.loja,
            nome="Pratos Principais",
            ordem_exibicao=1,
        )
        self.item_arroz = ItemMenu.objects.create(
            loja=self.loja,
            categoria=self.categoria,
            nome="Arroz de Pato",
            preco=150_000,  # 1.500 Kz em unidades mínimas inteiras
            is_disponivel=True,
        )
        self.item_sobremesa = ItemMenu.objects.create(
            loja=self.loja,
            categoria=self.categoria,
            nome="Mousse de Chocolate",
            preco=50_000,  # 500 Kz em unidades mínimas
            is_disponivel=True,
        )

        # Opção adicional
        self.grupo_opcoes = GrupoOpcao.objects.create(
            item=self.item_arroz,
            nome="Extras",
            is_obrigatorio=False,
            minimo_escolhas=0,
            maximo_escolhas=2,
        )
        self.opcao_queijo = OpcaoItem.objects.create(
            item=self.item_arroz,
            grupo=self.grupo_opcoes,
            nome="Queijo Gratinado",
            preco_adicional=20_000,  # 200 Kz
        )

    def test_calculo_subtotal_real_da_base_de_dados(self) -> None:
        """RN-050 / RN-059: Soma com exatidão inteira itens e opções da BD."""
        dados_carrinho = {
            "loja_id": str(self.loja.id),
            "itens": [
                {
                    "item_id": str(self.item_arroz.id),
                    "quantidade": 2,  # (150_000 + 20_000) * 2 = 340_000
                    "opcoes": [str(self.opcao_queijo.id)],
                },
                {
                    "item_id": str(self.item_sobremesa.id),
                    "quantidade": 1,  # 50_000 * 1 = 50_000
                    "opcoes": [],
                },
            ],
            "morada_id": str(self.morada.id),
        }

        cotacao = OrderPricingEngineService.gerar_cotacao_checkout(self.cliente, dados_carrinho)
        financeiro = cotacao["discriminacao_financeira"]

        # Subtotal esperado: 340_000 + 50_000 = 390_000
        self.assertEqual(financeiro["subtotal"], 390_000)
        self.assertIsInstance(financeiro["subtotal"], int)

    def test_rn041_taxa_pequeno_pedido_quando_abaixo_do_minimo(self) -> None:
        """
        RN-041: Se o subtotal (50_000) for inferior ao pedido mínimo da loja (200_000),
        adiciona taxa de pequeno pedido correspondente à diferença (150_000).
        """
        dados_carrinho = {
            "loja_id": str(self.loja.id),
            "itens": [
                {
                    "item_id": str(self.item_sobremesa.id),
                    "quantidade": 1,  # 50_000 (abaixo de 200_000)
                    "opcoes": [],
                }
            ],
            "morada_id": str(self.morada.id),
        }

        cotacao = OrderPricingEngineService.gerar_cotacao_checkout(self.cliente, dados_carrinho)
        financeiro = cotacao["discriminacao_financeira"]

        self.assertEqual(financeiro["subtotal"], 50_000)
        self.assertEqual(financeiro["taxa_pequeno_pedido"], 150_000)

    def test_rn041_sem_taxa_pequeno_pedido_quando_atinge_minimo(self) -> None:
        """RN-041: Quando subtotal >= 200_000, taxa_pequeno_pedido é 0."""
        dados_carrinho = {
            "loja_id": str(self.loja.id),
            "itens": [
                {
                    "item_id": str(self.item_arroz.id),
                    "quantidade": 2,  # 300_000 >= 200_000
                    "opcoes": [],
                }
            ],
            "morada_id": str(self.morada.id),
        }

        cotacao = OrderPricingEngineService.gerar_cotacao_checkout(self.cliente, dados_carrinho)
        financeiro = cotacao["discriminacao_financeira"]

        self.assertEqual(financeiro["subtotal"], 300_000)
        self.assertEqual(financeiro["taxa_pequeno_pedido"], 0)

    def test_rn051_e_rn052_taxa_entrega_dinamica_com_surge(self) -> None:
        """
        RN-051 e RN-052: Calcula a distância PostGIS e aplica o multiplicador dinâmico
        (ex.: 1.50x) com teto máximo de 2.00x.
        """
        dados_carrinho = {
            "loja_id": str(self.loja.id),
            "itens": [{"item_id": str(self.item_arroz.id), "quantidade": 2, "opcoes": []}],
            "morada_id": str(self.morada.id),
            "fator_preco_dinamico": "1.50",
        }

        cotacao = OrderPricingEngineService.gerar_cotacao_checkout(self.cliente, dados_carrinho)
        detalhes_entrega = cotacao["detalhes_taxa_entrega"]

        # Base 50_000 + (15_000 * ~3km) = ~95_000
        taxa_base = detalhes_entrega["taxa_base_calculada"]
        self.assertGreater(taxa_base, 50_000)

        # Taxa final com 1.50x
        taxa_final = cotacao["discriminacao_financeira"]["taxa_entrega"]
        self.assertEqual(taxa_final, int(Decimal(taxa_base) * Decimal("1.50")))
        self.assertEqual(detalhes_entrega["fator_dinamico"], "1.50")
        self.assertGreater(detalhes_entrega["acrescimo_dinamico"], 0)

    def test_rn053_taxa_servico_com_tetos_minimo_e_maximo(self) -> None:
        """
        RN-053: Taxa de serviço a 5% sobre subtotal respeitando teto mínimo (10_000)
        e máximo (50_000).
        """
        # Caso A: Subtotal baixo (50_000) -> 5% = 2_500, logo assume o teto mínimo de 10_000
        cotacao_a = OrderPricingEngineService.gerar_cotacao_checkout(
            self.cliente,
            {
                "loja_id": str(self.loja.id),
                "itens": [{"item_id": str(self.item_sobremesa.id), "quantidade": 1, "opcoes": []}],
                "morada_id": str(self.morada.id),
            },
        )
        self.assertEqual(cotacao_a["discriminacao_financeira"]["taxa_servico"], 10_000)

        # Caso B: Subtotal muito alto (2_000_000) -> 5% = 100_000, assume o teto máximo de 50_000
        cotacao_b = OrderPricingEngineService.gerar_cotacao_checkout(
            self.cliente,
            {
                "loja_id": str(self.loja.id),
                "itens": [{"item_id": str(self.item_arroz.id), "quantidade": 14, "opcoes": []}],
                "morada_id": str(self.morada.id),
            },
        )
        self.assertEqual(cotacao_b["discriminacao_financeira"]["taxa_servico"], 50_000)

    def test_rn055_e_rn056_desconto_cupao_e_reparticao_financiador(self) -> None:
        """
        RN-055 e RN-056: Aplica cupão válido e divide o financiamento conforme regra.
        """
        agora = timezone.now()
        cupao = CupaoDesconto.objects.create(
            codigo="DESCONTO50",
            tipo_desconto=CupaoDesconto.TipoDesconto.PERCENTAGEM,
            valor=10,  # 10% de desconto
            validade_inicio=agora - timezone.timedelta(days=1),
            validade_fim=agora + timezone.timedelta(days=10),
            montante_minimo_pedido=100_000,
            financiador=CupaoDesconto.FinanciadorCupao.PARTILHADO,
        )

        dados_carrinho = {
            "loja_id": str(self.loja.id),
            "itens": [{"item_id": str(self.item_arroz.id), "quantidade": 2, "opcoes": []}],  # 300_000
            "morada_id": str(self.morada.id),
            "cupao_codigo": "desconto50",  # testa case-insensitive
        }

        cotacao = OrderPricingEngineService.gerar_cotacao_checkout(self.cliente, dados_carrinho)
        financeiro = cotacao["discriminacao_financeira"]
        detalhes_cupao = cotacao["detalhes_cupao"]

        # Subtotal: 300_000, Desconto 10% = 30_000
        self.assertEqual(financeiro["descontos"], 30_000)
        self.assertEqual(detalhes_cupao["desconto_aplicado"], 30_000)
        self.assertEqual(detalhes_cupao["financiador"], "PARTILHADO")

        # Repartição 50% / 50%
        reparticao = detalhes_cupao["reparticao_financiamento"]
        self.assertEqual(reparticao["suportado_pela_plataforma"], 15_000)
        self.assertEqual(reparticao["suportado_pelo_parceiro"], 15_000)

    def test_rn050_formula_total_final(self) -> None:
        """
        RN-050: Valida com exatidão a equação:
        Total = Subtotal + Taxa Entrega + Taxa Serviço + Taxa Pequeno Pedido + Gorjeta - Descontos
        """
        gorjeta = 25_000  # 250 Kz de gorjeta
        dados_carrinho = {
            "loja_id": str(self.loja.id),
            "itens": [{"item_id": str(self.item_arroz.id), "quantidade": 2, "opcoes": []}],
            "morada_id": str(self.morada.id),
            "gorjeta_estafeta": gorjeta,
        }

        cotacao = OrderPricingEngineService.gerar_cotacao_checkout(self.cliente, dados_carrinho)
        f = cotacao["discriminacao_financeira"]

        total_esperado = (
            f["subtotal"]
            + f["taxa_entrega"]
            + f["taxa_servico"]
            + f["taxa_pequeno_pedido"]
            + f["gorjeta_estafeta"]
            - f["descontos"]
        )

        self.assertEqual(f["total_cobrado"], total_esperado)
        self.assertEqual(f["gorjeta_estafeta"], gorjeta)

    def test_rn043_congelamento_cotacao_em_redis_com_ttl_15_minutos(self) -> None:
        """
        RN-043: Verifica persistência em Redis com TTL de 900s e recuperação
        bem-sucedida via `obter_cotacao_valida`.
        """
        dados_carrinho = {
            "loja_id": str(self.loja.id),
            "itens": [{"item_id": str(self.item_arroz.id), "quantidade": 1, "opcoes": []}],
            "morada_id": str(self.morada.id),
        }

        cotacao = OrderPricingEngineService.gerar_cotacao_checkout(self.cliente, dados_carrinho)
        cotacao_id = cotacao["cotacao_id"]

        # Verifica na cache Redis
        chave_redis = f"checkout:cotacao:{cotacao_id}"
        em_cache = cache.get(chave_redis)
        self.assertIsNotNone(em_cache)
        self.assertEqual(em_cache["cotacao_id"], cotacao_id)
        self.assertEqual(em_cache["ttl_segundos"], 900)

        # Recuperação através do serviço
        recuperada = OrderPricingEngineService.obter_cotacao_valida(cotacao_id, self.cliente)
        self.assertEqual(recuperada["cotacao_id"], cotacao_id)

    def test_rn043_rejeita_cotacao_expirada_ou_inexistente(self) -> None:
        """RN-043: Lança exceção quando a cotação expirou do Redis."""
        with self.assertRaises(OrderPricingEngineError) as ctx:
            OrderPricingEngineService.obter_cotacao_valida(str(uuid.uuid4()), self.cliente)

        self.assertEqual(ctx.exception.codigo_regra, "RN-043")

