"""
Serializers da aplicação 'cart' para Gestão de Carrinho, Validações de Negócio e Checkout.
Implementa rigorosamente as regras de negócio:
- RN-040: Unicidade de Loja Parceira no Carrinho com erro estruturado HTTP 400;
- RN-042: Limites de Quantidade por Item (default 20 unidades, Secção 8);
- RN-044: Restrição de Idade para Produtos Regulados (Álcool/Tabaco) com HTTP 403 Forbidden;
- RN-063: Preferências Automáticas de Substituição (Remover, Substituir por Equivalente, Cancelar).
"""
from __future__ import annotations

import logging
import uuid
from typing import Any

from django.conf import settings
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied

from apps.cart.models import PreferenciaSubstituicao
from apps.cart.services import CartService
from apps.catalog.models import ItemMenu, OpcaoItem, ParceiroLoja

logger = logging.getLogger(__name__)

# Parâmetro configurável da Secção 8 / RN-042: Quantidade máxima de unidades por item
LIMITE_PADRAO_QUANTIDADE_ITEM: int = getattr(settings, "CART_MAX_QUANTIDADE_ITEM", 20)

# Conjunto alargado de termos para deteção de produtos com restrição etária (RN-044)
TERMOS_RESTRICAO_ETARIA: set[str] = {
    "alcool", "álcool", "cerveja", "vinho", "licor", "whisky", "whiskey",
    "vodka", "gin", "rum", "tequila", "espumante", "champagne", "sidra",
    "aguardente", "cocktail", "alcoólica", "alcoolica", "tabaco", "cigarro",
    "charuto", "cigarrilha", "vape", "shisha", "tabacaria",
}


class OpcaoCarrinhoInputSerializer(serializers.Serializer):
    """Valida a opção de personalização associada a um item de menu."""

    opcao_id = serializers.UUIDField(
        required=True,
        help_text=_("UUID da OpcaoItem selecionada."),
    )


class OpcaoCarrinhoOutputSerializer(serializers.Serializer):
    """Representação serializada de uma opção escolhida no item do carrinho."""

    opcao_id = serializers.UUIDField()
    nome = serializers.CharField()
    preco_adicional = serializers.IntegerField()


class ItemCarrinhoOutputSerializer(serializers.Serializer):
    """Representação detalhada de cada item presente no carrinho ativo."""

    item_id = serializers.UUIDField()
    nome = serializers.CharField()
    preco_unitario = serializers.IntegerField()
    quantidade = serializers.IntegerField()
    opcoes = OpcaoCarrinhoOutputSerializer(many=True, default=list)
    notas = serializers.CharField(allow_blank=True, default="")
    preferencia_substituicao = serializers.ChoiceField(
        choices=PreferenciaSubstituicao.choices,
        default=PreferenciaSubstituicao.SUBSTITUIR_EQUIVALENTE,
    )
    contem_artigos_restritos = serializers.BooleanField(default=False)
    subtotal_item = serializers.IntegerField()


class CarrinhoOutputSerializer(serializers.Serializer):
    """Representação do estado global do carrinho de compras do utilizador."""

    utilizador_id = serializers.UUIDField()
    loja_id = serializers.UUIDField(allow_null=True)
    loja_nome = serializers.CharField(allow_null=True)
    itens = ItemCarrinhoOutputSerializer(many=True)
    preferencia_substituicao_padrao = serializers.ChoiceField(
        choices=PreferenciaSubstituicao.choices,
        default=PreferenciaSubstituicao.SUBSTITUIR_EQUIVALENTE,
    )
    subtotal = serializers.IntegerField()
    total_itens = serializers.IntegerField()
    criado_em = serializers.CharField()
    atualizado_em = serializers.CharField()


class AdicionarItemCarrinhoSerializer(serializers.Serializer):
    """
    Serializer de validação e adição de itens ao carrinho (`POST /api/v1/cart/items/`).
    Executa rigorosamente as validações de:
    1. RN-040: Unicidade de Loja;
    2. RN-042: Limites de Quantidade;
    3. RN-044: Restrição Legal de Idade (>= 18 anos civis com HTTP 403 Forbidden).
    """

    item_id = serializers.UUIDField(
        required=True,
        help_text=_("UUID do ItemMenu a adicionar ao carrinho."),
    )
    quantidade = serializers.IntegerField(
        required=False,
        default=1,
        min_value=1,
        help_text=_("RN-042: Quantidade de unidades a adicionar (mínimo 1)."),
    )
    opcoes = serializers.ListField(
        child=serializers.UUIDField(),
        required=False,
        default=list,
        help_text=_("RN-014: Lista de UUIDs de opções adicionais selecionadas."),
    )
    notas = serializers.CharField(
        required=False,
        allow_blank=True,
        default="",
        max_length=255,
        help_text=_("RN-045: Observações de preparação destinadas ao parceiro."),
    )
    preferencia_substituicao = serializers.ChoiceField(
        choices=PreferenciaSubstituicao.choices,
        default=PreferenciaSubstituicao.SUBSTITUIR_EQUIVALENTE,
        required=False,
        help_text=_("RN-063: Preferência de substituição se o item esgotar."),
    )
    substituir_carrinho_existente = serializers.BooleanField(
        required=False,
        default=False,
        help_text=_(
            "RN-040: Se True e o carrinho contiver itens de outra loja, limpa o carrinho anterior "
            "e substitui pelo novo item da nova loja."
        ),
    )

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        """
        Executa as validações combinadas de integridade, unicidade de loja, limites e maioridade.
        """
        item_id: uuid.UUID = attrs["item_id"]
        quantidade_solicitada: int = attrs.get("quantidade", 1)
        substituir_carrinho: bool = attrs.get("substituir_carrinho_existente", False)

        # ----------------------------------------------------------------------
        # A. Validação de Existência e Disponibilidade do Item (RN-014, RN-015)
        # ----------------------------------------------------------------------
        try:
            item = (
                ItemMenu.objects.select_related("loja", "categoria", "categoria__loja")
                .prefetch_related("grupos_opcoes__opcoes")
                .get(pk=item_id)
            )
        except ItemMenu.DoesNotExist:
            raise serializers.ValidationError(
                {"item_id": _("O produto selecionado não foi encontrado no catálogo.")}
            )

        if not item.is_disponivel:
            raise serializers.ValidationError(
                {"item_id": _("RN-015: Este produto encontra-se temporariamente indisponível.")}
            )

        # Determina a Loja do Item
        loja_do_item: ParceiroLoja | None = item.loja or (
            item.categoria.loja if item.categoria else None
        )
        if not loja_do_item:
            raise serializers.ValidationError(
                {"item_id": _("O estabelecimento parceiro associado a este produto é inválido.")}
            )

        # ----------------------------------------------------------------------
        # 1. Validação de Loja Única (RN-040)
        # ----------------------------------------------------------------------
        request = self.context.get("request")
        user = getattr(request, "user", None)
        if not user or not user.is_authenticated:
            raise serializers.ValidationError(
                {"erro": _("Utilizador não autenticado.")}
            )

        carrinho_atual = CartService.obter_carrinho(user.id)
        itens_no_carrinho = carrinho_atual.get("itens", [])
        loja_atual_id = carrinho_atual.get("loja_id")

        if itens_no_carrinho and loja_atual_id:
            if str(loja_atual_id) != str(loja_do_item.id):
                # Se não autorizou substituição explícita, rejeita com HTTP 400 estruturado (RN-040)
                if not substituir_carrinho:
                    raise serializers.ValidationError(
                        {
                            "erro": "RN-040_LOJA_DIFERENTE",
                            "codigo": "STORE_CONFLICT",
                            "mensagem": _(
                                "O carrinho já contém itens de outro estabelecimento. "
                                "Deseja limpar o carrinho anterior e iniciar um novo pedido nesta loja?"
                            ),
                            "loja_atual": {
                                "id": str(loja_atual_id),
                                "nome": carrinho_atual.get("loja_nome", ""),
                            },
                            "nova_loja": {
                                "id": str(loja_do_item.id),
                                "nome": loja_do_item.nome,
                            },
                            "acao_sugerida": "substituir_carrinho",
                            "detalhe": _(
                                "Para substituir o carrinho anterior, repita o pedido com "
                                "'substituir_carrinho_existente': true."
                            ),
                        }
                    )

        # ----------------------------------------------------------------------
        # 2. Limites de Quantidade (RN-042)
        # ----------------------------------------------------------------------
        limite_max_item: int = LIMITE_PADRAO_QUANTIDADE_ITEM

        # Contabiliza a quantidade que o utilizador já tem deste item no carrinho
        quantidade_existente_no_carrinho = 0
        if not substituir_carrinho and str(loja_atual_id) == str(loja_do_item.id):
            for it in itens_no_carrinho:
                if str(it.get("item_id")) == str(item.id):
                    quantidade_existente_no_carrinho += int(it.get("quantidade", 0))

        quantidade_acumulada_pretendida = quantidade_existente_no_carrinho + quantidade_solicitada
        if quantidade_acumulada_pretendida > limite_max_item:
            raise serializers.ValidationError(
                {
                    "quantidade": _(
                        f"RN-042: A quantidade total pretendida ({quantidade_acumulada_pretendida}) "
                        f"ultrapassa o limite máximo de {limite_max_item} unidades por item no pedido."
                    ),
                    "limite_maximo_permitido": limite_max_item,
                    "quantidade_atual_no_carrinho": quantidade_existente_no_carrinho,
                    "quantidade_solicitada": quantidade_solicitada,
                }
            )

        # ----------------------------------------------------------------------
        # 3. Itens Restritos por Idade (RN-044) -> HTTP 403 Forbidden
        # ----------------------------------------------------------------------
        nome_lower = (item.nome or "").lower()
        desc_lower = (item.descricao or "").lower()
        cat_lower = (item.categoria.nome if item.categoria else "").lower()

        is_item_restrito = any(
            termo in nome_lower or termo in desc_lower or termo in cat_lower
            for termo in TERMOS_RESTRICAO_ETARIA
        )

        if is_item_restrito:
            data_nascimento = getattr(user, "data_nascimento", None)
            if not data_nascimento:
                raise PermissionDenied(
                    {
                        "erro": "RN-044_DATA_NASCIMENTO_OBRIGATORIA",
                        "codigo": "BIRTHDATE_REQUIRED",
                        "mensagem": _(
                            "RN-044: Este artigo possui restrição legal de idade (Álcool/Tabaco). "
                            "Tem de registar a sua data de nascimento no perfil para comprovar a maioridade."
                        ),
                    }
                )

            hoje = timezone.now().date()
            idade_anos = (
                hoje.year
                - data_nascimento.year
                - ((hoje.month, hoje.day) < (data_nascimento.month, data_nascimento.day))
            )

            if idade_anos < 18:
                logger.warning(
                    "[RN-044] Tentativa de compra de produto restrito por menor de idade: user_id=%s, idade=%d",
                    user.id,
                    idade_anos,
                )
                raise PermissionDenied(
                    {
                        "erro": "RN-044_MENOR_DE_IDADE",
                        "codigo": "AGE_RESTRICTION_FORBIDDEN",
                        "mensagem": _(
                            "RN-044: Apenas utilizadores com idade legal igual ou superior a 18 anos civis "
                            "podem adicionar e adquirir artigos regulados (Álcool/Tabaco)."
                        ),
                        "idade_utilizador": idade_anos,
                        "idade_minima_legal": 18,
                    }
                )

        # ----------------------------------------------------------------------
        # B. Validação das Opções Selecionadas (RN-014)
        # ----------------------------------------------------------------------
        opcoes_uuids = attrs.get("opcoes", [])
        opcoes_estruturadas: list[dict[str, Any]] = []

        if opcoes_uuids:
            opcoes_qs = OpcaoItem.objects.filter(pk__in=opcoes_uuids, item=item)
            opcoes_encontradas = {str(op.id): op for op in opcoes_qs}

            for op_uuid in opcoes_uuids:
                op_str = str(op_uuid)
                if op_str not in opcoes_encontradas:
                    raise serializers.ValidationError(
                        {"opcoes": _(f"A opção '{op_str}' não pertence ao item selecionado (RN-014).")}
                    )
                op_inst = opcoes_encontradas[op_str]
                opcoes_estruturadas.append(
                    {
                        "opcao_id": str(op_inst.id),
                        "nome": op_inst.nome if hasattr(op_inst, "nome") else f"Opção {op_inst.id}",
                        "preco_adicional": getattr(op_inst, "preco_adicional", 0) or 0,
                    }
                )

        # Injeta objetos resolvidos no dicionário validado
        attrs["_item_model"] = item
        attrs["_loja_model"] = loja_do_item
        attrs["_opcoes_estruturadas"] = opcoes_estruturadas
        attrs["_is_restrito"] = is_item_restrito

        return attrs


class PreferenciaSubstituicaoSerializer(serializers.Serializer):
    """
    RN-063: Valida a submissão de preferência de substituição de itens
    (`/api/v1/cart/items/substitute-preference/`).
    """

    item_id = serializers.UUIDField(
        required=False,
        allow_null=True,
        default=None,
        help_text=_(
            "UUID do item específico no carrinho. Se omitido ou null, a preferência "
            "aplica-se a todos os itens do carrinho ativo."
        ),
    )
    preferencia = serializers.ChoiceField(
        choices=PreferenciaSubstituicao.choices,
        required=True,
        help_text=_("RN-063: Escolha automática (REMOVER, SUBSTITUIR_EQUIVALENTE, CANCELAR_ITEM)."),
    )

    def validate_preferencia(self, value: str) -> str:
        # Suporta mapeamento de aliases comuns
        valor_upper = value.upper().strip()
        mapeamento = {
            "REMOVER": PreferenciaSubstituicao.REMOVER,
            "SUBSTITUIR": PreferenciaSubstituicao.SUBSTITUIR_EQUIVALENTE,
            "SUBSTITUIR_EQUIVALENTE": PreferenciaSubstituicao.SUBSTITUIR_EQUIVALENTE,
            "CANCELAR": PreferenciaSubstituicao.CANCELAR_ITEM,
            "CANCELAR_ITEM": PreferenciaSubstituicao.CANCELAR_ITEM,
        }
        if valor_upper in mapeamento:
            return mapeamento[valor_upper]
        return value


class AtualizarQuantidadeItemSerializer(serializers.Serializer):
    """Valida a atualização direta de quantidade de uma linha do carrinho."""

    quantidade = serializers.IntegerField(
        required=True,
        min_value=0,
        max_value=LIMITE_PADRAO_QUANTIDADE_ITEM,
        help_text=_("RN-042: Nova quantidade (0 remove o item, máximo permitido 20)."),
    )

