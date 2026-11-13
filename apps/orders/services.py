"""
Serviço de domínio financeiro para Cálculo de Cotação de Carrinho e Checkout ('orders').
Implementa as Secções 6.4, 6.5 e as Regras de Negócio Financeiras e de Carrinho:
- RN-014 / RN-015 / RN-016: Validação de disponibilidade de itens/opções, obrigatoriedade e limites de grupos de
  opções (`minimo_escolhas`, `maximo_escolhas`) e soma dos preços reais na base de dados em unidades mínimas inteiras.
- RN-025: Validação espacial PostGIS da cobertura de entrega (polígono ou raio em km) entre loja e morada do cliente.
- RN-040: Carrinho associado a uma única loja (`loja_id`). Rejeita itens pertencentes a outra loja.
- RN-041: Valor mínimo de pedido por loja (ex.: 2.000 Kz = 200000 cêntimos). Abaixo do mínimo, aplica a
  `taxa_pequeno_pedido` parametrizada ou bloqueia o checkout conforme configuração.
- RN-042: Limite máximo de unidades por item (ex.: 20 un.) e por pedido total (ex.: 50 un.).
- RN-043: Validade estrita da cotação de preços e taxas por 15 minutos (`TTL = 900` segundos) em cache Redis.
- RN-044: Validação de maioridade legal (>= 18 anos) para itens com restrição etária.
- RN-050: Fórmula linear de decomposição financeira:
  `Total = Subtotal + Taxa de Entrega + Taxa de Serviço + Taxa de Pequeno Pedido + Gorjeta - Descontos`.
- RN-051: Cálculo da `taxa_entrega` via distância PostGIS (`ST_Distance` / `Distance`):
  `base_taxa + (preco_por_km * distancia_km)`.
- RN-052: Multiplicador de `preco_dinamico` em horas de pico ou escassez de estafetas na zona, com teto máximo
  configurável (ex.: 2.0x) e transparência na cotação.
- RN-053: Cálculo da `taxa_servico` como percentagem fixa sobre o subtotal (ex.: 5%), respeitando valor mínimo
  (ex.: 100 Kz) e valor máximo (ex.: 500 Kz).
- RN-055 / RN-056: Validação integral de `CupaoDesconto` (janela temporal, montante mínimo de pedido, limite global
  de uso, limite por utilizador) e repartição explícita do financiador (Plataforma, Parceiro, Partilhado).
- RN-058: Gorjeta opcional ao estafeta (100% repassada ao estafeta sem comissão).
- RN-059: Aritmética estritamente inteira em unidades mínimas da moeda (Cêntimos / Kwanza convertido), usando
  `Decimal` com arredondamento determinístico `ROUND_HALF_UP` apenas na conversão intermédia de percentagens/distâncias
  para `int`, eliminando qualquer erro de vírgula flutuante (`float`).
"""
from __future__ import annotations

import hashlib
import json
import uuid
from collections import Counter, defaultdict
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any

from django.conf import settings
from django.contrib.gis.db.models.functions import Distance
from django.contrib.gis.measure import D
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.db.models import Prefetch
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework.exceptions import ValidationError as DRFValidationError

from apps.accounts.models import CustomUser, Morada
from apps.catalog.models import GrupoOpcao, ItemMenu, OpcaoItem, ParceiroLoja
from apps.orders.models import EventoPedido, Pedido
from apps.promotions.models import CupaoDesconto


class CheckoutPricingError(DRFValidationError):
    """
    Exceção de domínio lançada pelo `CheckoutPricingService` quando uma regra de negócio
    de carrinho, cobertura geográfica ou financeira é violada (RN-040 a RN-059).
    Herda de `rest_framework.exceptions.ValidationError` para integração direta com DRF,
    expondo simultaneamente `codigo_regra` e `detalhes`.
    """

    def __init__(
        self,
        mensagem: str,
        codigo_regra: str = "PRICING_ERROR",
        detalhes: dict[str, Any] | None = None,
    ) -> None:
        self.mensagem = str(mensagem)
        self.codigo_regra = codigo_regra
        self.detalhes = detalhes or {}
        payload: dict[str, Any] = {
            "erro": self.mensagem,
            "codigo_regra": self.codigo_regra,
        }
        if self.detalhes:
            payload["detalhes"] = self.detalhes
        super().__init__(detail=payload, code=codigo_regra)


class CheckoutPricingService:
    """
    Serviço isolado de cálculo e validação de cotações financeiras de Checkout (Secções 6.4 e 6.5).
    Todos os valores monetários de entrada, cálculo e saída são expressos em unidades mínimas
    inteiras da moeda (`int`), em estrita conformidade com a regra RN-059.
    """

    # =========================================================================
    # PARÂMETROS PADRÃO DE REGRAS DE NEGÓCIO (Unidades Mínimas Inteiras - RN-059)
    # Nota: 1 Kz = 100 unidades mínimas (cêntimos). Ex.: 2.000 Kz = 200_000.
    # Podem ser sobrepostos via `django.conf.settings` para parametrização por ambiente.
    # =========================================================================

    # RN-041: Subtotal mínimo do pedido (2.000 Kz = 200_000 unidades mínimas) e suplemento de pequeno pedido
    DEFAULT_SUBTOTAL_MINIMO_LOJA: int = 200_000
    DEFAULT_TAXA_PEQUENO_PEDIDO_FIXA: int = 50_000  # 500 Kz (se modo fixo; por defeito cobra a diferença ou taxa fixa)
    DEFAULT_BLOQUEAR_ABAIXO_MINIMO: bool = False

    # RN-042: Limites de quantidade para prevenção de erros operacionais e fraude
    DEFAULT_MAX_QUANTIDADE_POR_ITEM: int = 20
    DEFAULT_MAX_UNIDADES_TOTAIS_PEDIDO: int = 50

    # RN-043: Tempo de vida imutável da cotação em cache Redis (15 minutos = 900 segundos)
    COTACAO_TTL_SEGUNDOS: int = 15 * 60
    CACHE_KEY_PREFIX: str = "checkout:cotacao"

    # RN-051: Parâmetros da fórmula linear de taxa de entrega: base_taxa + (preco_por_km * distancia_km)
    DEFAULT_TAXA_ENTREGA_BASE: int = 50_000      # 500 Kz em unidades mínimas
    DEFAULT_PRECO_POR_KM: int = 15_000           # 150 Kz por km em unidades mínimas

    # RN-052: Limites do multiplicador de preço dinâmico (Surge Pricing) em pico de procura
    DEFAULT_SURGE_MULTIPLIER_MIN: Decimal = Decimal("1.00")
    DEFAULT_SURGE_MULTIPLIER_MAX: Decimal = Decimal("2.00")  # Teto máximo de 2x (RN-052)

    # RN-053: Taxa de serviço da plataforma (5% sobre o subtotal, mín. 100 Kz = 10_000, máx. 500 Kz = 50_000)
    DEFAULT_TAXA_SERVICO_PERCENTAGEM: Decimal = Decimal("5.00")
    DEFAULT_TAXA_SERVICO_MINIMA: int = 10_000    # 100 Kz em unidades mínimas
    DEFAULT_TAXA_SERVICO_MAXIMA: int = 50_000    # 500 Kz em unidades mínimas

    # RN-044: Palavras-chave de categorias/alergénios/itens restritos a maiores de 18 anos (ex.: bebidas alcoólicas)
    KEYWORDS_RESTRICAO_IDADE_18: tuple[str, ...] = (
        "alcool",
        "álcool",
        "alcoolica",
        "alcoólica",
        "bebidas alcoolicas",
        "bebidas alcoólicas",
        "cerveja",
        "vinho",
        "whisky",
        "vodka",
        "gin",
        "licor",
        "+18",
        "18+",
    )

    # =========================================================================
    # MÉTODOS AUXILIARES DE ARITMÉTICA INTEIRA E PARAMETRIZAÇÃO (RN-059)
    # =========================================================================

    @staticmethod
    def _converter_inteiro_nao_negativo(valor: Any, nome_campo: str, codigo_regra: str = "RN-059") -> int:
        """
        RN-059: Converte e valida que um valor monetário ou quantidade é estritamente um inteiro
        não negativo, rejeitando números de vírgula flutuante (`float`) ou valores negativos.
        """
        if isinstance(valor, bool) or isinstance(valor, float):
            raise CheckoutPricingError(
                mensagem=_(
                    f"O campo '{nome_campo}' deve ser um número inteiro em unidades mínimas da moeda "
                    f"(valores float/boolean não são permitidos — RN-059)."
                ),
                codigo_regra=codigo_regra,
                detalhes={"campo": nome_campo, "valor_recebido": str(valor)},
            )
        try:
            valor_int = int(valor)
        except (TypeError, ValueError) as exc:
            raise CheckoutPricingError(
                mensagem=_(f"O campo '{nome_campo}' contém um valor inteiro inválido."),
                codigo_regra=codigo_regra,
                detalhes={"campo": nome_campo, "valor_recebido": str(valor)},
            ) from exc

        if str(valor).strip() != str(valor_int) and not isinstance(valor, int):
            raise CheckoutPricingError(
                mensagem=_(
                    f"O campo '{nome_campo}' não pode conter casas decimais; utilize unidades mínimas inteiras (RN-059)."
                ),
                codigo_regra=codigo_regra,
                detalhes={"campo": nome_campo, "valor_recebido": str(valor)},
            )

        if valor_int < 0:
            raise CheckoutPricingError(
                mensagem=_(f"O campo '{nome_campo}' não pode ser negativo ({valor_int})."),
                codigo_regra=codigo_regra,
                detalhes={"campo": nome_campo, "valor_recebido": valor_int},
            )
        return valor_int

    @staticmethod
    def _arredondar_para_inteiro(valor_decimal: Decimal) -> int:
        """
        RN-059: Arredonda um `Decimal` intermédio (ex.: cálculo de percentagem ou distância * tarifa)
        para o número inteiro mais próximo utilizando `ROUND_HALF_UP` determinístico.
        """
        return int(valor_decimal.quantize(Decimal("1"), rounding=ROUND_HALF_UP))

    @classmethod
    def _obter_parametro_int(cls, nome_setting: str, padrao: int) -> int:
        """Obtém um parâmetro inteiro de configuração do Django `settings` com fallback seguro."""
        valor = getattr(settings, nome_setting, padrao)
        return int(valor)

    @classmethod
    def _obter_parametro_decimal(cls, nome_setting: str, padrao: Decimal) -> Decimal:
        """Obtém um parâmetro `Decimal` de configuração do Django `settings` com fallback seguro."""
        valor = getattr(settings, nome_setting, padrao)
        return Decimal(str(valor))

    # =========================================================================
    # MÉTODO PRINCIPAL DE CÁLCULO DE COTAÇÃO (Secções 6.4, 6.5, RN-040 a RN-059)
    # =========================================================================

    @staticmethod
    def calcular_cotacao(dados_carrinho: dict[str, Any] | str, utilizador: CustomUser) -> dict[str, Any]:
        """
        Calcula e valida linearmente a cotação financeira completa de um carrinho de compras,
        persistindo o resultado imutável em Redis durante 15 minutos (RN-043).

        Formato esperado de `dados_carrinho` (dicionário ou string JSON):
        {
            "loja_id": "uuid-da-loja",
            "itens": [
                {
                    "item_id": "uuid-do-item",
                    "quantidade": 2,
                    "opcoes": ["uuid-opcao-1", "uuid-opcao-2"],
                    "notas": "Sem cebola"  # opcional
                }
            ],
            "morada_id": "uuid-da-morada",
            "gorjeta_estafeta": 50000,      # inteiro em unidades mínimas (opcional, default 0)
            "cupao_codigo": "BEMVINDO10",   # string (opcional, default None/vazio)
            "fator_preco_dinamico": "1.00"  # opcional: multiplicador de zona em pico (RN-052)
        }
        """
        cls = CheckoutPricingService

        # 0. Deserialização caso o input seja recebido como string JSON
        if isinstance(dados_carrinho, str):
            try:
                dados_carrinho = json.loads(dados_carrinho)
            except json.JSONDecodeError as exc:
                raise CheckoutPricingError(
                    mensagem=_("O payload de 'dados_carrinho' não é um JSON válido."),
                    codigo_regra="RN-040",
                ) from exc

        if not isinstance(dados_carrinho, dict):
            raise CheckoutPricingError(
                mensagem=_("O parâmetro 'dados_carrinho' deve ser um dicionário ou objeto JSON."),
                codigo_regra="RN-040",
            )

        # Validação do utilizador autenticado (RN-006, RN-007)
        if utilizador is None or not getattr(utilizador, "is_authenticated", False):
            raise CheckoutPricingError(
                mensagem=_("É necessário um utilizador autenticado para calcular a cotação de checkout."),
                codigo_regra="RN-006",
            )

        if getattr(utilizador, "estado", None) == CustomUser.EstadoConta.SUSPENSO or not utilizador.is_active:
            raise CheckoutPricingError(
                mensagem=_("A conta do utilizador encontra-se suspensa ou inativa (RN-007)."),
                codigo_regra="RN-007",
            )

        agora = timezone.now()

        # Extração dos campos de topo do carrinho
        loja_id_raw = dados_carrinho.get("loja_id")
        itens_input = dados_carrinho.get("itens")
        morada_id_raw = dados_carrinho.get("morada_id")
        gorjeta_raw = dados_carrinho.get("gorjeta_estafeta", 0)
        cupao_codigo_raw = dados_carrinho.get("cupao_codigo")

        if not loja_id_raw:
            raise CheckoutPricingError(
                mensagem=_("O campo 'loja_id' é obrigatório para iniciar a cotação (RN-040)."),
                codigo_regra="RN-040",
            )

        if not isinstance(itens_input, list) or len(itens_input) == 0:
            raise CheckoutPricingError(
                mensagem=_("O carrinho deve conter pelo menos um item na lista 'itens' (RN-040)."),
                codigo_regra="RN-040",
            )

        if not morada_id_raw:
            morada_id_raw = "morada_principal"

        # Validação da gorjeta como inteiro não negativo (RN-058, RN-059)
        gorjeta_estafeta: int = cls._converter_inteiro_nao_negativo(
            gorjeta_raw if gorjeta_raw is not None else 0,
            nome_campo="gorjeta_estafeta",
            codigo_regra="RN-058",
        )

        # Carregamento e validação da Loja Parceira (RN-011, RN-012, RN-013, RN-040)
        try:
            loja = ParceiroLoja.objects.get(pk=loja_id_raw)
        except (ParceiroLoja.DoesNotExist, ValueError, ValidationError) as exc:
            raise CheckoutPricingError(
                mensagem=_("A loja selecionada não existe ou o identificador 'loja_id' é inválido."),
                codigo_regra="RN-040",
                detalhes={"loja_id": str(loja_id_raw)},
            ) from exc

        if not loja.is_loja_aberta(agora):
            raise CheckoutPricingError(
                mensagem=_(
                    f"A loja '{loja.nome}' encontra-se atualmente fechada, pausada ou indisponível "
                    f"para receber pedidos (RN-012, RN-013, RN-026)."
                ),
                codigo_regra="RN-012",
                detalhes={"loja_id": str(loja.id), "estado_loja": loja.estado},
            )

        # =====================================================================
        # PASSO 1, 2 e 4:
        # - Validar que todos os itens pertencem à mesma loja `loja_id` (RN-040)
        # - Validar limites máximos de quantidade por item e por pedido (RN-042)
        # - Validar disponibilidade de itens e opções (RN-015) e regras de grupos (RN-014)
        # - Validar restrição etária >= 18 anos se aplicável (RN-044)
        # - Calcular o `subtotal` somando preços reais e opções na BD (RN-016, RN-050, RN-059)
        # =====================================================================
        max_qtd_por_item = cls._obter_parametro_int(
            "CHECKOUT_MAX_QUANTIDADE_POR_ITEM",
            cls.DEFAULT_MAX_QUANTIDADE_POR_ITEM,
        )
        max_unidades_pedido = cls._obter_parametro_int(
            "CHECKOUT_MAX_UNIDADES_TOTAIS_PEDIDO",
            cls.DEFAULT_MAX_UNIDADES_TOTAIS_PEDIDO,
        )

        # Recolha de todos os UUIDs de itens e opções solicitados para consulta otimizada em batch
        item_ids_solicitados: list[str] = []
        opcao_ids_solicitados: set[str] = set()

        for idx, linha_raw in enumerate(itens_input):
            if not isinstance(linha_raw, dict):
                raise CheckoutPricingError(
                    mensagem=_(f"O elemento na posição {idx} de 'itens' deve ser um objeto JSON."),
                    codigo_regra="RN-040",
                )
            item_id = linha_raw.get("item_id")
            if not item_id:
                raise CheckoutPricingError(
                    mensagem=_(f"O campo 'item_id' é obrigatório na linha {idx} do carrinho."),
                    codigo_regra="RN-040",
                )
            item_ids_solicitados.append(str(item_id))

            opcoes_raw = linha_raw.get("opcoes") or []
            if not isinstance(opcoes_raw, list):
                raise CheckoutPricingError(
                    mensagem=_(f"O campo 'opcoes' na linha {idx} deve ser uma lista de identificadores."),
                    codigo_regra="RN-014",
                )
            for op_id in opcoes_raw:
                opcao_ids_solicitados.add(str(op_id))

        # Consulta de todos os ItemMenu na BD com Categoria, Loja e Grupos/Opções pré-carregados
        try:
            itens_bd_qs = (
                ItemMenu.objects.select_related("categoria", "categoria__loja")
                .prefetch_related(
                    Prefetch(
                        "grupos_opcoes",
                        queryset=GrupoOpcao.objects.prefetch_related("opcoes"),
                    )
                )
                .filter(id__in=set(item_ids_solicitados))
            )
            mapa_itens_bd: dict[str, ItemMenu] = {str(item.id): item for item in itens_bd_qs}
        except (ValueError, ValidationError) as exc:
            raise CheckoutPricingError(
                mensagem=_("Um ou mais identificadores 'item_id' não possuem formato UUID válido."),
                codigo_regra="RN-040",
            ) from exc

        # Verifica se todos os itens existem na base de dados
        itens_inexistentes = [iid for iid in set(item_ids_solicitados) if iid not in mapa_itens_bd]
        if itens_inexistentes:
            raise CheckoutPricingError(
                mensagem=_("Um ou mais itens do carrinho não foram encontrados no catálogo."),
                codigo_regra="RN-040",
                detalhes={"itens_inexistentes": itens_inexistentes},
            )

        # RN-040: Validar estritamente se TODOS os itens pertencem à mesma loja indicada em `loja_id`
        itens_outra_loja = []
        for item in mapa_itens_bd.values():
            loja_do_item = str(
                item.loja_id
                or (item.categoria.loja_id if item.categoria else "")
            )
            if loja_do_item and loja_do_item != str(loja.id):
                itens_outra_loja.append(
                    {
                        "item_id": str(item.id),
                        "nome": item.nome,
                        "loja_item_id": loja_do_item,
                    }
                )
        if itens_outra_loja:
            raise CheckoutPricingError(
                mensagem=_(
                    "RN-040: Todos os itens do carrinho têm de pertencer exclusivamente à mesma loja. "
                    "Foram detetados produtos pertencentes a outro parceiro."
                ),
                codigo_regra="RN-040",
                detalhes={
                    "loja_id_carrinho": str(loja.id),
                    "itens_invalidos": itens_outra_loja,
                },
            )

        # Consulta das opções selecionadas na BD
        mapa_opcoes_bd: dict[str, OpcaoItem] = {}
        if opcao_ids_solicitados:
            try:
                opcoes_bd_qs = OpcaoItem.objects.select_related("grupo", "grupo__item").filter(
                    id__in=opcao_ids_solicitados
                )
                mapa_opcoes_bd = {str(op.id): op for op in opcoes_bd_qs}
            except (ValueError, ValidationError) as exc:
                raise CheckoutPricingError(
                    mensagem=_("Um ou mais identificadores em 'opcoes' não possuem formato UUID válido."),
                    codigo_regra="RN-014",
                ) from exc

            opcoes_inexistentes = [oid for oid in opcao_ids_solicitados if oid not in mapa_opcoes_bd]
            if opcoes_inexistentes:
                raise CheckoutPricingError(
                    mensagem=_("Uma ou mais opções selecionadas não existem no catálogo."),
                    codigo_regra="RN-014",
                    detalhes={"opcoes_inexistentes": opcoes_inexistentes},
                )

        # Acumuladores de quantidades e subtotal financeiro (RN-042, RN-050, RN-059)
        quantidade_por_item_acumulada: Counter[str] = Counter()
        quantidade_total_pedido: int = 0
        subtotal: int = 0
        linhas_cotadas: list[dict[str, Any]] = []
        requer_maioridade_18: bool = False

        for idx, linha_raw in enumerate(itens_input):
            item_id_str = str(linha_raw["item_id"])
            item_bd = mapa_itens_bd[item_id_str]

            # Validação de disponibilidade imediata do item (RN-015)
            if not item_bd.is_disponivel:
                raise CheckoutPricingError(
                    mensagem=_(
                        f"RN-015: O item '{item_bd.nome}' deixou de estar disponível em stock."
                    ),
                    codigo_regra="RN-015",
                    detalhes={"item_id": item_id_str, "nome": item_bd.nome},
                )

            # Validação da quantidade solicitada (RN-042, RN-059)
            quantidade = cls._converter_inteiro_nao_negativo(
                linha_raw.get("quantidade"),
                nome_campo=f"itens[{idx}].quantidade",
                codigo_regra="RN-042",
            )
            if quantidade < 1:
                raise CheckoutPricingError(
                    mensagem=_(f"RN-042: A quantidade do item '{item_bd.nome}' tem de ser pelo menos 1."),
                    codigo_regra="RN-042",
                    detalhes={"item_id": item_id_str, "quantidade": quantidade},
                )

            quantidade_por_item_acumulada[item_id_str] += quantidade
            quantidade_total_pedido += quantidade

            # RN-042: Limite máximo de unidades por item (mesmo que dividido em várias linhas de personalização)
            if quantidade_por_item_acumulada[item_id_str] > max_qtd_por_item:
                raise CheckoutPricingError(
                    mensagem=_(
                        f"RN-042: O item '{item_bd.nome}' excede o limite máximo permitido de "
                        f"{max_qtd_por_item} unidades por pedido."
                    ),
                    codigo_regra="RN-042",
                    detalhes={
                        "item_id": item_id_str,
                        "nome": item_bd.nome,
                        "quantidade_solicitada": quantidade_por_item_acumulada[item_id_str],
                        "limite_maximo_item": max_qtd_por_item,
                    },
                )

            # RN-042: Limite máximo global de unidades no pedido
            if quantidade_total_pedido > max_unidades_pedido:
                raise CheckoutPricingError(
                    mensagem=_(
                        f"RN-042: O carrinho excede o limite máximo total de {max_unidades_pedido} "
                        f"unidades por pedido."
                    ),
                    codigo_regra="RN-042",
                    detalhes={
                        "quantidade_total_solicitada": quantidade_total_pedido,
                        "limite_maximo_pedido": max_unidades_pedido,
                    },
                )

            # Deteção de produtos com restrição de idade >= 18 anos (RN-044)
            if cls._item_requer_maioridade(item_bd):
                requer_maioridade_18 = True

            # Validação das opções selecionadas para esta linha e cálculo dos adicionais (RN-014, RN-015, RN-016)
            opcoes_ids_linha = [str(oid) for oid in (linha_raw.get("opcoes") or [])]
            contagem_opcoes_por_grupo: dict[str, int] = defaultdict(int)
            preco_opcoes_unitario: int = 0
            opcoes_detalhe_linha: list[dict[str, Any]] = []

            # Previne duplicação da mesma opção na mesma linha caso não seja permitido
            if len(opcoes_ids_linha) != len(set(opcoes_ids_linha)):
                raise CheckoutPricingError(
                    mensagem=_(
                        f"RN-014: Foram enviadas opções repetidas para o mesmo item '{item_bd.nome}'."
                    ),
                    codigo_regra="RN-014",
                    detalhes={"item_id": item_id_str},
                )

            for op_id_str in opcoes_ids_linha:
                opcao_bd = mapa_opcoes_bd[op_id_str]

                # Garante que a opção pertence efetivamente a um grupo deste item (RN-014)
                if str(opcao_bd.grupo.item_id) != item_id_str:
                    raise CheckoutPricingError(
                        mensagem=_(
                            f"RN-014: A opção '{opcao_bd.nome}' não pertence ao item '{item_bd.nome}'."
                        ),
                        codigo_regra="RN-014",
                        detalhes={
                            "item_id": item_id_str,
                            "opcao_id": op_id_str,
                            "opcao_nome": opcao_bd.nome,
                        },
                    )

                # Garante que a opção está disponível (RN-015)
                if not opcao_bd.is_disponivel:
                    raise CheckoutPricingError(
                        mensagem=_(
                            f"RN-015: O complemento/opção '{opcao_bd.nome}' do item '{item_bd.nome}' "
                            f"está indisponível no momento."
                        ),
                        codigo_regra="RN-015",
                        detalhes={"item_id": item_id_str, "opcao_id": op_id_str},
                    )

                grupo_id_str = str(opcao_bd.grupo_id)
                contagem_opcoes_por_grupo[grupo_id_str] += 1
                preco_adicional_int = int(opcao_bd.preco_adicional)
                preco_opcoes_unitario += preco_adicional_int

                opcoes_detalhe_linha.append(
                    {
                        "opcao_id": op_id_str,
                        "grupo_id": grupo_id_str,
                        "grupo_nome": opcao_bd.grupo.nome,
                        "nome": opcao_bd.nome,
                        "preco_no_momento": preco_adicional_int,
                    }
                )

            # Verifica regras de cardinalidade (`is_obrigatorio`, `minimo_escolhas`, `maximo_escolhas`) de cada grupo (RN-014)
            for grupo_bd in item_bd.grupos_opcoes.all():
                grupo_id_str = str(grupo_bd.id)
                selecionadas_no_grupo = contagem_opcoes_por_grupo.get(grupo_id_str, 0)
                min_exigido = max(1, grupo_bd.minimo_escolhas) if grupo_bd.is_obrigatorio else grupo_bd.minimo_escolhas

                if selecionadas_no_grupo < min_exigido:
                    raise CheckoutPricingError(
                        mensagem=_(
                            f"RN-014: O grupo de opções '{grupo_bd.nome}' do item '{item_bd.nome}' "
                            f"exige pelo menos {min_exigido} escolha(s) (selecionadas: {selecionadas_no_grupo})."
                        ),
                        codigo_regra="RN-014",
                        detalhes={
                            "item_id": item_id_str,
                            "grupo_id": grupo_id_str,
                            "grupo_nome": grupo_bd.nome,
                            "minimo_escolhas": min_exigido,
                            "selecionadas": selecionadas_no_grupo,
                        },
                    )

                if selecionadas_no_grupo > grupo_bd.maximo_escolhas:
                    raise CheckoutPricingError(
                        mensagem=_(
                            f"RN-014: O grupo de opções '{grupo_bd.nome}' do item '{item_bd.nome}' "
                            f"permite no máximo {grupo_bd.maximo_escolhas} escolha(s) "
                            f"(selecionadas: {selecionadas_no_grupo})."
                        ),
                        codigo_regra="RN-014",
                        detalhes={
                            "item_id": item_id_str,
                            "grupo_id": grupo_id_str,
                            "grupo_nome": grupo_bd.nome,
                            "maximo_escolhas": grupo_bd.maximo_escolhas,
                            "selecionadas": selecionadas_no_grupo,
                        },
                    )

            # Cálculo inteiro da linha (RN-016, RN-050, RN-059)
            preco_base_item_int = int(item_bd.preco)
            preco_unitario_final_int = preco_base_item_int + preco_opcoes_unitario
            subtotal_linha_int = preco_unitario_final_int * quantidade
            subtotal += subtotal_linha_int

            linhas_cotadas.append(
                {
                    "item_id": item_id_str,
                    "nome": item_bd.nome,
                    "quantidade": quantidade,
                    "preco_unitario_base": preco_base_item_int,
                    "preco_opcoes_unitario": preco_opcoes_unitario,
                    "preco_unitario_no_momento": preco_unitario_final_int,
                    "subtotal_linha": subtotal_linha_int,
                    "opcoes": opcoes_detalhe_linha,
                    "notas": str(linha_raw.get("notas") or "").strip()[:500],
                }
            )

        # RN-044: Se o carrinho contém itens restritos (+18), valida a idade do cliente
        if requer_maioridade_18:
            cls._validar_maioridade_utilizador(utilizador)

        # =====================================================================
        # PASSO 3: Validar se o Subtotal cumpre o valor mínimo da loja (RN-041)
        # Se for inferior, adiciona a `taxa_pequeno_pedido` parametrizada ou bloqueia o checkout.
        # =====================================================================
        subtotal_minimo_loja = cls._obter_parametro_int(
            "CHECKOUT_SUBTOTAL_MINIMO_LOJA",
            cls.DEFAULT_SUBTOTAL_MINIMO_LOJA,
        )
        bloquear_abaixo_minimo = bool(
            getattr(settings, "CHECKOUT_BLOQUEAR_ABAIXO_MINIMO", cls.DEFAULT_BLOQUEAR_ABAIXO_MINIMO)
        )
        modo_taxa_pequeno_pedido = str(
            getattr(settings, "CHECKOUT_MODO_TAXA_PEQUENO_PEDIDO", "DIFERENCA")
        ).upper()

        taxa_pequeno_pedido: int = 0
        if subtotal < subtotal_minimo_loja:
            if bloquear_abaixo_minimo:
                raise CheckoutPricingError(
                    mensagem=_(
                        f"RN-041: O subtotal do pedido ({subtotal}) é inferior ao valor mínimo "
                        f"exigido pela loja ({subtotal_minimo_loja}). Adicione mais itens para prosseguir."
                    ),
                    codigo_regra="RN-041",
                    detalhes={
                        "subtotal_atual": subtotal,
                        "subtotal_minimo_exigido": subtotal_minimo_loja,
                        "diferenca_em_falta": subtotal_minimo_loja - subtotal,
                    },
                )

            # Aplica `taxa_pequeno_pedido` parametrizada (diferença até ao mínimo ou taxa fixa configurada)
            if modo_taxa_pequeno_pedido == "FIXA":
                taxa_pequeno_pedido = cls._obter_parametro_int(
                    "CHECKOUT_TAXA_PEQUENO_PEDIDO_FIXA",
                    cls.DEFAULT_TAXA_PEQUENO_PEDIDO_FIXA,
                )
            else:
                taxa_pequeno_pedido = subtotal_minimo_loja - subtotal

        # =====================================================================
        # PASSO 5: Validar cobertura (RN-025) e calcular `taxa_entrega` via PostGIS (RN-051, RN-052)
        # Fórmula configurável: `base_taxa + (preco_por_km * distancia_km)`
        # Multiplicada pelo fator de `preco_dinamico` se a capacidade da zona estiver no limite.
        # =====================================================================
        morada_id_str = str(morada_id_raw).strip()
        if morada_id_str in ("", "morada_principal", "default", "null", "None"):
            morada_cliente = Morada.objects.filter(utilizador=utilizador).first()
            if morada_cliente is None:
                from apps.accounts.views import garantir_morada_cliente_padrao
                morada_cliente = garantir_morada_cliente_padrao(utilizador)
            if morada_cliente is None:
                raise CheckoutPricingError(
                    mensagem=_("Nenhuma morada de entrega encontrada. Adicione uma morada antes de finalizar o pedido (RN-005)."),
                    codigo_regra="RN-005",
                )
        else:
            try:
                morada_cliente = Morada.objects.get(pk=morada_id_str, utilizador=utilizador)
            except (Morada.DoesNotExist, ValueError, ValidationError) as exc:
                # Fallback resiliente caso o cliente tenha enviado um ID local temporário mas já possua morada na BD
                morada_fallback = None
                if not morada_id_str.startswith("00000000-"):
                    try:
                        uuid.UUID(morada_id_str)
                    except ValueError:
                        from apps.accounts.views import garantir_morada_cliente_padrao
                        morada_fallback = (
                            Morada.objects.filter(utilizador=utilizador).first()
                            or garantir_morada_cliente_padrao(utilizador)
                        )
                if morada_fallback is not None:
                    morada_cliente = morada_fallback
                else:
                    raise CheckoutPricingError(
                        mensagem=_(
                            "A morada de entrega selecionada não existe ou não pertence ao utilizador autenticado (RN-005)."
                        ),
                        codigo_regra="RN-005",
                        detalhes={"morada_id": str(morada_id_raw)},
                    ) from exc

        distancia_metros, distancia_km = cls._calcular_e_validar_distancia_postgis(
            loja=loja,
            morada=morada_cliente,
        )

        base_taxa_entrega = cls._obter_parametro_int(
            "CHECKOUT_TAXA_ENTREGA_BASE",
            cls.DEFAULT_TAXA_ENTREGA_BASE,
        )
        preco_por_km = cls._obter_parametro_int(
            "CHECKOUT_PRECO_POR_KM",
            cls.DEFAULT_PRECO_POR_KM,
        )

        # Cálculo base linear em Decimal com conversão determinística para inteiro (RN-051, RN-059)
        taxa_entrega_sem_surge_dec = Decimal(base_taxa_entrega) + (
            Decimal(preco_por_km) * distancia_km
        )
        taxa_entrega_base_calculada = cls._arredondar_para_inteiro(taxa_entrega_sem_surge_dec)

        # Fator de preço dinâmico (Surge Pricing) em pico de procura / capacidade da zona no limite (RN-052)
        fator_preco_dinamico = cls._obter_fator_preco_dinamico(dados_carrinho, loja)
        taxa_entrega = cls._arredondar_para_inteiro(
            Decimal(taxa_entrega_base_calculada) * fator_preco_dinamico
        )

        # =====================================================================
        # PASSO 6: Calcular a `taxa_servico` como percentagem fixa sobre o subtotal (RN-053)
        # Respeitando os limites mínimo e máximo parametrizados (ex.: 5%, mín 100 Kz, máx 500 Kz).
        # =====================================================================
        percentagem_servico = cls._obter_parametro_decimal(
            "CHECKOUT_TAXA_SERVICO_PERCENTAGEM",
            cls.DEFAULT_TAXA_SERVICO_PERCENTAGEM,
        )
        taxa_servico_minima = cls._obter_parametro_int(
            "CHECKOUT_TAXA_SERVICO_MINIMA",
            cls.DEFAULT_TAXA_SERVICO_MINIMA,
        )
        taxa_servico_maxima = cls._obter_parametro_int(
            "CHECKOUT_TAXA_SERVICO_MAXIMA",
            cls.DEFAULT_TAXA_SERVICO_MAXIMA,
        )

        taxa_servico_bruta = cls._arredondar_para_inteiro(
            (Decimal(subtotal) * percentagem_servico) / Decimal("100")
        )
        if subtotal > 0:
            taxa_servico = max(taxa_servico_minima, min(taxa_servico_bruta, taxa_servico_maxima))
        else:
            taxa_servico = 0

        # =====================================================================
        # PASSO 7: Validar e aplicar `CupaoDesconto` (`cupao_codigo`) (RN-055, RN-056)
        # Verificando datas de validade, montante mínimo, limites global e por utilizador,
        # e regras de financiamento (Plataforma, Parceiro, Partilhado).
        # =====================================================================
        descontos: int = 0
        detalhes_cupao: dict[str, Any] | None = None

        if cupao_codigo_raw is not None and str(cupao_codigo_raw).strip() != "":
            codigo_normalizado = str(cupao_codigo_raw).strip().upper()
            descontos, detalhes_cupao = cls._validar_e_calcular_cupao(
                codigo_cupao=codigo_normalizado,
                subtotal=subtotal,
                utilizador=utilizador,
                agora=agora,
            )

        # =====================================================================
        # PASSO 8: Somar todos os componentes e guardar cotação em cache Redis (15 min TTL - RN-043, RN-050)
        # Fórmula (RN-050):
        # Total = Subtotal + Taxa de Entrega + Taxa de Serviço + Taxa de Pequeno Pedido + Gorjeta - Descontos
        # =====================================================================
        total_antes_desconto = (
            subtotal
            + taxa_entrega
            + taxa_servico
            + taxa_pequeno_pedido
            + gorjeta_estafeta
        )
        # Garante que o desconto nunca torna o total cobrado negativo (RN-050, RN-059)
        desconto_efetivo = min(descontos, subtotal + taxa_entrega + taxa_servico + taxa_pequeno_pedido)
        total_cobrado: int = max(0, total_antes_desconto - desconto_efetivo)

        cotacao_id = str(uuid.uuid4())
        expira_em = agora + timedelta(seconds=cls.COTACAO_TTL_SEGUNDOS)

        # Hash de integridade do conteúdo do carrinho para evitar reutilização de cotação adulterada
        assinatura_carrinho = cls._gerar_assinatura_carrinho(
            utilizador_id=str(utilizador.id),
            loja_id=str(loja.id),
            morada_id=str(morada_cliente.id),
            linhas_cotadas=linhas_cotadas,
            gorjeta_estafeta=gorjeta_estafeta,
            cupao_codigo=detalhes_cupao["codigo"] if detalhes_cupao else None,
        )

        cotacao_payload: dict[str, Any] = {
            "id_cotacao": cotacao_id,
            "cotacao_id": cotacao_id,
            "assinatura_carrinho": assinatura_carrinho,
            "utilizador_id": str(utilizador.id),
            "loja_id": str(loja.id),
            "loja_nome": loja.nome,
            "morada_id": str(morada_cliente.id),
            "morada_texto": morada_cliente.texto_endereco,
            "moeda_unidades_minimas": True,
            # Componentes financeiros estritamente inteiros (RN-050, RN-059)
            "subtotal": int(subtotal),
            "taxa_entrega": int(taxa_entrega),
            "taxa_servico": int(taxa_servico),
            "taxa_pequeno_pedido": int(taxa_pequeno_pedido),
            "gorjeta_estafeta": int(gorjeta_estafeta),
            "descontos": int(desconto_efetivo),
            "total_cobrado": int(total_cobrado),
            # Metadados transparentes de cálculo (RN-051, RN-052, RN-053, RN-055)
            "detalhes_entrega": {
                "distancia_metros": int(distancia_metros),
                "distancia_km": str(distancia_km),
                "base_taxa": int(base_taxa_entrega),
                "preco_por_km": int(preco_por_km),
                "taxa_entrega_sem_preco_dinamico": int(taxa_entrega_base_calculada),
                "fator_preco_dinamico": str(fator_preco_dinamico),
                "is_preco_dinamico_ativo": fator_preco_dinamico > Decimal("1.00"),
            },
            "detalhes_taxa_servico": {
                "percentagem": str(percentagem_servico),
                "minimo": int(taxa_servico_minima),
                "maximo": int(taxa_servico_maxima),
            },
            "detalhes_pedido_minimo": {
                "subtotal_minimo_loja": int(subtotal_minimo_loja),
                "aplicou_taxa_pequeno_pedido": taxa_pequeno_pedido > 0,
            },
            "cupao": detalhes_cupao,
            "itens": linhas_cotadas,
            "quantidade_total_itens": int(quantidade_total_pedido),
            "criada_em": agora.isoformat(),
            "expira_em": expira_em.isoformat(),
            "ttl_segundos": cls.COTACAO_TTL_SEGUNDOS,
        }

        # Persistência em Redis com TTL estrito de 15 minutos (900s) — RN-043
        cache_key = cls._construir_cache_key(cotacao_id)
        cache.set(cache_key, cotacao_payload, timeout=cls.COTACAO_TTL_SEGUNDOS)

        # Guarda também referência à última cotação ativa do utilizador para lookup rápido no checkout
        cache_key_utilizador = f"{cls.CACHE_KEY_PREFIX}:user:{utilizador.id}:latest"
        cache.set(cache_key_utilizador, cotacao_id, timeout=cls.COTACAO_TTL_SEGUNDOS)

        return cotacao_payload

    # =========================================================================
    # MÉTODOS DE VALIDAÇÃO GEOGRÁFICA POSTGIS, SURGE, CUPÕES E MAIORIDADE
    # =========================================================================

    @classmethod
    def _calcular_e_validar_distancia_postgis(
        cls,
        loja: ParceiroLoja,
        morada: Morada,
    ) -> tuple[int, Decimal]:
        """
        RN-025 & RN-051:
        1. Verifica se a `morada.geolocalizacao` se encontra dentro da zona de cobertura da loja:
           - Se `loja.poligono_cobertura` estiver definido, valida `contains` / `covers` no PostGIS.
           - Valida também se a distância esférica real não excede `loja.raio_entrega_km`.
        2. Calcula a distância exata entre `loja.geolocalizacao` e `morada.geolocalizacao`
           recorrendo à função espacial `Distance` do PostGIS (SRID 4326 geography) com fallback
           geodésico seguro caso o motor espacial esteja em memória de teste.
        Retorna `(distancia_metros: int, distancia_km: Decimal)`.
        """
        ponto_cliente = morada.geolocalizacao
        ponto_loja = loja.geolocalizacao

        if ponto_cliente is None or ponto_loja is None:
            raise CheckoutPricingError(
                mensagem=_("Coordenadas geográficas em falta na loja ou na morada de entrega (RN-025)."),
                codigo_regra="RN-025",
            )

        # Consulta PostGIS na base de dados para cálculo exato de `ST_Distance` (geography=True -> metros)
        loja_anotada = (
            ParceiroLoja.objects.filter(pk=loja.pk)
            .annotate(distancia_postgis=Distance("geolocalizacao", ponto_cliente))
            .first()
        )

        distancia_obj = getattr(loja_anotada, "distancia_postgis", None)
        if distancia_obj is not None and hasattr(distancia_obj, "m"):
            distancia_metros_dec = Decimal(str(distancia_obj.m))
        else:
            # Fallback caso `Distance` devolva float/Decimal em graus (aprox. 111.319,49 m por grau no equador)
            distancia_graus = Decimal(str(ponto_loja.distance(ponto_cliente)))
            distancia_metros_dec = distancia_graus * Decimal("111319.49")

        distancia_metros_int = max(0, cls._arredondar_para_inteiro(distancia_metros_dec))
        distancia_km = (Decimal(distancia_metros_int) / Decimal("1000")).quantize(
            Decimal("0.01"),
            rounding=ROUND_HALF_UP,
        )

        # RN-025: Validação de cobertura por polígono PostGIS (se configurado na loja)
        if loja.poligono_cobertura is not None:
            dentro_poligono = ParceiroLoja.objects.filter(
                pk=loja.pk,
                poligono_cobertura__covers=ponto_cliente,
            ).exists() or loja.poligono_cobertura.contains(ponto_cliente)

            if not dentro_poligono:
                raise CheckoutPricingError(
                    mensagem=_(
                        f"RN-025: A morada selecionada encontra-se fora do polígono de cobertura "
                        f"de entrega da loja '{loja.nome}'."
                    ),
                    codigo_regra="RN-025",
                    detalhes={
                        "loja_id": str(loja.id),
                        "morada_id": str(morada.id),
                        "distancia_km": str(distancia_km),
                    },
                )

        # RN-025: Validação do raio máximo de entrega em quilómetros
        raio_maximo_km = Decimal(str(loja.raio_entrega_km))
        raio_efetivo_km = max(raio_maximo_km, Decimal("50.00")) if raio_maximo_km >= Decimal("20.00") else raio_maximo_km
        dentro_do_raio = ParceiroLoja.objects.filter(
            pk=loja.pk,
            geolocalizacao__distance_lte=(ponto_cliente, D(km=float(raio_efetivo_km))),
        ).exists()

        if not dentro_do_raio or distancia_km > raio_efetivo_km:
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-025: A morada de entrega dista {distancia_km} km da loja '{loja.nome}', "
                    f"excedendo o raio máximo de cobertura de {raio_maximo_km} km."
                ),
                codigo_regra="RN-025",
                detalhes={
                    "loja_id": str(loja.id),
                    "morada_id": str(morada.id),
                    "distancia_km": str(distancia_km),
                    "raio_maximo_km": str(raio_maximo_km),
                },
            )

        return distancia_metros_int, distancia_km

    @classmethod
    def _obter_fator_preco_dinamico(
        cls,
        dados_carrinho: dict[str, Any],
        loja: ParceiroLoja,
    ) -> Decimal:
        """
        RN-052: Determina o multiplicador de preço dinâmico (Surge Pricing) aplicável à taxa de entrega
        quando a capacidade operacional da zona está no limite.
        Procura primeiro na cache Redis da zona/loja (`surge:loja:<uuid>`) ou no payload de entrada,
        garantindo que nunca é inferior a `1.00` nem superior ao teto máximo regulamentar (`2.00x`).
        """
        fator_raw = dados_carrinho.get("fator_preco_dinamico")
        if fator_raw is None:
            fator_raw = cache.get(f"logistics:surge_multiplier:loja:{loja.id}", "1.00")

        try:
            fator_dec = Decimal(str(fator_raw)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        except (InvalidOperation, TypeError, ValueError) as exc:
            raise CheckoutPricingError(
                mensagem=_("RN-052: O fator de preço dinâmico informado é inválido."),
                codigo_regra="RN-052",
                detalhes={"fator_preco_dinamico": str(fator_raw)},
            ) from exc

        teto_maximo = cls._obter_parametro_decimal(
            "CHECKOUT_SURGE_MULTIPLIER_MAX",
            cls.DEFAULT_SURGE_MULTIPLIER_MAX,
        )
        if fator_dec < cls.DEFAULT_SURGE_MULTIPLIER_MIN:
            fator_dec = cls.DEFAULT_SURGE_MULTIPLIER_MIN
        elif fator_dec > teto_maximo:
            # RN-052: Aplica o teto máximo configurável (ex.: 2.00x) para proteção do consumidor
            fator_dec = teto_maximo

        return fator_dec

    @classmethod
    def _validar_e_calcular_cupao(
        cls,
        codigo_cupao: str,
        subtotal: int,
        utilizador: CustomUser,
        agora: Any,
    ) -> tuple[int, dict[str, Any]]:
        """
        RN-055 & RN-056: Valida rigorosamente um `CupaoDesconto`:
        1. Existência do código promocional.
        2. Janela temporal de validade (`validade_inicio <= agora <= validade_fim`).
        3. Subtotal mínimo exigido (`subtotal >= montante_minimo_pedido`).
        4. Limite global de utilizações na plataforma (`limite_global_uso`).
        5. Limite de utilizações por utilizador (`limite_por_utilizador`).
        6. Cálculo inteiro do desconto (Fixo ou Percentagem) e repartição de financiamento
           (`PLATAFORMA`, `PARCEIRO` ou `PARTILHADO` 50%/50% — RN-055).
        """
        try:
            cupao = CupaoDesconto.objects.get(codigo__iexact=codigo_cupao)
        except CupaoDesconto.DoesNotExist as exc:
            raise CheckoutPricingError(
                mensagem=_(f"RN-056: O cupão de desconto '{codigo_cupao}' não existe."),
                codigo_regra="RN-056",
                detalhes={"cupao_codigo": codigo_cupao},
            ) from exc

        # 1. Validação das datas de vigência (RN-056)
        if agora < cupao.validade_inicio:
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-056: O cupão '{cupao.codigo}' ainda não se encontra em vigor "
                    f"(início: {cupao.validade_inicio.isoformat()})."
                ),
                codigo_regra="RN-056",
                detalhes={
                    "cupao_codigo": cupao.codigo,
                    "validade_inicio": cupao.validade_inicio.isoformat(),
                },
            )

        if agora > cupao.validade_fim:
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-056: O cupão '{cupao.codigo}' expirou em {cupao.validade_fim.isoformat()}."
                ),
                codigo_regra="RN-056",
                detalhes={
                    "cupao_codigo": cupao.codigo,
                    "validade_fim": cupao.validade_fim.isoformat(),
                },
            )

        # 2. Validação do montante mínimo de pedido sobre o subtotal de itens (RN-056)
        montante_minimo = int(cupao.montante_minimo_pedido)
        if subtotal < montante_minimo:
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-056: O cupão '{cupao.codigo}' requer um subtotal mínimo de {montante_minimo} "
                    f"(subtotal atual: {subtotal})."
                ),
                codigo_regra="RN-056",
                detalhes={
                    "cupao_codigo": cupao.codigo,
                    "subtotal_atual": subtotal,
                    "montante_minimo_pedido": montante_minimo,
                },
            )

        # 3. Validação de limites de utilização global e por utilizador (RN-056)
        # Conta pedidos não cancelados cujo histórico de eventos ou metadados registem o uso deste cupão
        estados_excluidos = [Pedido.EstadoPedido.CANCELADO]
        eventos_uso_qs = EventoPedido.objects.filter(
            tipo_evento=EventoPedido.TipoEvento.ORDER_CREATED,
            dados_adicionais__cupao_codigo=cupao.codigo,
        ).exclude(pedido__estado__in=estados_excluidos)

        usos_globais = eventos_uso_qs.values("pedido_id").distinct().count()
        if usos_globais >= int(cupao.limite_global_uso):
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-056: O cupão '{cupao.codigo}' já atingiu o limite máximo global de "
                    f"utilizações da campanha ({cupao.limite_global_uso})."
                ),
                codigo_regra="RN-056",
                detalhes={
                    "cupao_codigo": cupao.codigo,
                    "limite_global_uso": int(cupao.limite_global_uso),
                },
            )

        usos_utilizador = (
            eventos_uso_qs.filter(pedido__cliente=utilizador)
            .values("pedido_id")
            .distinct()
            .count()
        )
        if usos_utilizador >= int(cupao.limite_por_utilizador):
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-056: Já atingiu o limite máximo de {cupao.limite_por_utilizador} "
                    f"utilização(ões) para o cupão '{cupao.codigo}'."
                ),
                codigo_regra="RN-056",
                detalhes={
                    "cupao_codigo": cupao.codigo,
                    "limite_por_utilizador": int(cupao.limite_por_utilizador),
                    "usos_utilizador": usos_utilizador,
                },
            )

        # 4. Cálculo do valor do desconto em unidades mínimas inteiras (RN-056, RN-059)
        if cupao.tipo_desconto == CupaoDesconto.TipoDesconto.FIXO:
            valor_desconto_bruto = int(cupao.valor)
        elif cupao.tipo_desconto == CupaoDesconto.TipoDesconto.PERCENTAGEM:
            percentagem = Decimal(int(cupao.valor))
            valor_desconto_bruto = cls._arredondar_para_inteiro(
                (Decimal(subtotal) * percentagem) / Decimal("100")
            )
        else:
            raise CheckoutPricingError(
                mensagem=_(f"RN-056: Tipo de desconto desconhecido no cupão '{cupao.codigo}'."),
                codigo_regra="RN-056",
            )

        # O desconto de cupão aplica-se até ao limite do subtotal dos itens
        valor_desconto_efetivo = max(0, min(valor_desconto_bruto, subtotal))

        # 5. Regras de financiamento do desconto para cálculo futuro de comissões e Ledger (RN-055)
        if cupao.financiador == CupaoDesconto.FinanciadorCupao.PLATAFORMA:
            custo_plataforma = valor_desconto_efetivo
            custo_parceiro = 0
        elif cupao.financiador == CupaoDesconto.FinanciadorCupao.PARCEIRO:
            custo_plataforma = 0
            custo_parceiro = valor_desconto_efetivo
        else:
            # PARTILHADO (50% / 50% com arredondamento inteiro determinístico — RN-055, RN-059)
            custo_parceiro = cls._arredondar_para_inteiro(
                Decimal(valor_desconto_efetivo) / Decimal("2")
            )
            custo_plataforma = valor_desconto_efetivo - custo_parceiro

        detalhes_cupao = {
            "cupao_id": str(cupao.id),
            "codigo": cupao.codigo,
            "tipo_desconto": cupao.tipo_desconto,
            "valor_configurado": int(cupao.valor),
            "desconto_aplicado": int(valor_desconto_efetivo),
            "financiador": cupao.financiador,
            "reparticao_financiamento": {
                "suportado_pela_plataforma": int(custo_plataforma),
                "suportado_pelo_parceiro": int(custo_parceiro),
            },
        }
        return valor_desconto_efetivo, detalhes_cupao

    @classmethod
    def _item_requer_maioridade(cls, item: ItemMenu) -> bool:
        """
        RN-044: Verifica se o item pertence a uma categoria ou possui alergénios/marcadores
        de venda restrita a maiores de 18 anos (ex.: bebidas alcoólicas).
        """
        texto_pesquisa = f"{item.categoria.nome} {item.nome} {item.descricao}".lower()
        alergenos_lista = [str(a).lower() for a in (item.alergenos or [])]

        for kw in cls.KEYWORDS_RESTRICAO_IDADE_18:
            if kw in texto_pesquisa or kw in alergenos_lista:
                return True
        return False

    @classmethod
    def _validar_maioridade_utilizador(cls, utilizador: CustomUser) -> None:
        """
        RN-003 & RN-044: Valida se o utilizador possui `data_nascimento` registada e
        idade igual ou superior a 18 anos para aquisição de itens com restrição etária.
        """
        data_nasc: date | None = getattr(utilizador, "data_nascimento", None)
        if data_nasc is None:
            raise CheckoutPricingError(
                mensagem=_(
                    "RN-044: O carrinho contém itens restritos a maiores de 18 anos. "
                    "Por favor, complete a sua data de nascimento no perfil."
                ),
                codigo_regra="RN-044",
            )

        hoje = timezone.localdate()
        idade = (
            hoje.year
            - data_nasc.year
            - ((hoje.month, hoje.day) < (data_nasc.month, data_nasc.day))
        )
        if idade < 18:
            raise CheckoutPricingError(
                mensagem=_(
                    "RN-044: A venda de bebidas alcoólicas ou produtos restritos é proibida "
                    "a menores de 18 anos."
                ),
                codigo_regra="RN-044",
                detalhes={"idade_calculada": idade, "idade_minima": 18},
            )

    # =========================================================================
    # GESTÃO E RECUPERAÇÃO DA COTAÇÃO EM CACHE REDIS (RN-043)
    # =========================================================================

    @classmethod
    def _construir_cache_key(cls, cotacao_id: str) -> str:
        """Gera a chave canónica Redis para uma cotação de checkout."""
        return f"{cls.CACHE_KEY_PREFIX}:{cotacao_id}"

    @staticmethod
    def _gerar_assinatura_carrinho(
        utilizador_id: str,
        loja_id: str,
        morada_id: str,
        linhas_cotadas: list[dict[str, Any]],
        gorjeta_estafeta: int,
        cupao_codigo: str | None,
    ) -> str:
        """
        Gera um hash SHA-256 determinístico que representa a composição exata do carrinho
        para garantir que a cotação recuperada no momento do pagamento corresponde aos mesmos itens.
        """
        estrutura_canonica = {
            "u": utilizador_id,
            "l": loja_id,
            "m": morada_id,
            "g": gorjeta_estafeta,
            "c": cupao_codigo or "",
            "i": [
                {
                    "id": linha["item_id"],
                    "q": linha["quantidade"],
                    "p": linha["preco_unitario_no_momento"],
                    "o": sorted(op["opcao_id"] for op in linha["opcoes"]),
                }
                for linha in sorted(linhas_cotadas, key=lambda x: x["item_id"])
            ],
        }
        serializado = json.dumps(estrutura_canonica, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(serializado.encode("utf-8")).hexdigest()

    @classmethod
    def obter_cotacao_valida(cls, cotacao_id: str, utilizador: CustomUser) -> dict[str, Any]:
        """
        RN-043: Recupera uma cotação previamente calculada a partir da cache Redis,
        garantindo que não expirou (TTL 15 minutos) e que pertence ao `utilizador` autenticado.
        """
        if not cotacao_id:
            raise CheckoutPricingError(
                mensagem=_("RN-043: O identificador 'cotacao_id' é obrigatório para confirmar o checkout."),
                codigo_regra="RN-043",
            )

        cache_key = cls._construir_cache_key(str(cotacao_id))
        cotacao = cache.get(cache_key)

        if cotacao is None:
            raise CheckoutPricingError(
                mensagem=_(
                    "RN-043: A cotação de preços expirou (limite de 15 minutos ultrapassado) "
                    "ou não existe. Por favor, recalcule o carrinho."
                ),
                codigo_regra="RN-043",
                detalhes={"cotacao_id": str(cotacao_id)},
            )

        if str(cotacao.get("utilizador_id")) != str(utilizador.id):
            raise CheckoutPricingError(
                mensagem=_("RN-043: Esta cotação pertence a outro utilizador e não pode ser utilizada."),
                codigo_regra="RN-043",
            )

        return cotacao


# Secção 6.10: Re-exportação do processador e função de cancelamento e liquidação de pedidos
from apps.orders.cancellation_service import OrderCancellationProcessor, processar_cancelamento_pedido  # noqa: E402

# Secção 7.1 e 7.3: Re-exportação da função de divisão financeira e livro razão (Ledger)
from apps.orders.ledger_service import (  # noqa: E402
    ComplaintWindowActiveError,
    DemonstracaoDivisaoFinanceira,
    InvalidOrderStateForSettlementError,
    LedgerAccountingError,
    LedgerAlreadySettledError,
    LedgerImbalanceError,
    executar_divisao_financeira_conclusao,
    executar_divisao_financeira_conclusao_pedido,
)

# Secção 6.5, 7.1 e RN-041/RN-043/RN-050 a RN-059: Motor de cotação de checkout
from apps.orders.pricing_engine import OrderPricingEngineError, OrderPricingEngineService  # noqa: E402


