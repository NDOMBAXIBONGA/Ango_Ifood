"""
Views e ViewSets da API REST (Django REST Framework) para o Carrinho de Compras ('cart').
Implementa os endpoints:
- POST /api/v1/cart/items/ (Adição com validações RN-040, RN-042, RN-044);
- GET /api/v1/cart/items/ e GET /api/v1/cart/ (Consulta do estado do carrinho);
- PATCH /api/v1/cart/items/{item_id}/ (Atualização de quantidade - RN-042);
- DELETE /api/v1/cart/items/{item_id}/ (Remoção de item);
- POST /api/v1/cart/items/substitute-preference/ (Preferências de substituição - RN-063);
- DELETE /api/v1/cart/ (Limpeza completa do carrinho).
"""
from __future__ import annotations

import logging
from typing import Any

from django.utils.translation import gettext_lazy as _
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.request import Request
from rest_framework.response import Response

from apps.cart.serializers import (
    AdicionarItemCarrinhoSerializer,
    AtualizarQuantidadeItemSerializer,
    CarrinhoOutputSerializer,
    PreferenciaSubstituicaoSerializer,
)
from apps.cart.services import CartService

logger = logging.getLogger(__name__)


class CartViewSet(viewsets.ViewSet):
    """
    Controlador REST principal para gestão intermédia do carrinho de compras do cliente.
    Todas as ações exigem utilizador autenticado (`IsAuthenticated`).
    """

    permission_classes = [permissions.IsAuthenticated]

    # =========================================================================
    # 1. GET /api/v1/cart/ ou GET /api/v1/cart/items/
    # =========================================================================
    def list(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        Retorna a estrutura completa do carrinho ativo do utilizador autenticado
        na cache Redis.
        """
        carrinho = CartService.obter_carrinho(request.user.id)
        serializer = CarrinhoOutputSerializer(carrinho)
        return Response(serializer.data, status=status.HTTP_200_OK)

    # =========================================================================
    # 2. POST /api/v1/cart/items/ (RN-040, RN-042, RN-044)
    # =========================================================================
    @action(detail=False, methods=["post"], url_path="items", url_name="add-item")
    def add_item(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        RN-040, RN-042 e RN-044:
        Valida e adiciona um item ao carrinho:
        - Rejeita com HTTP 400 estruturado se o item pertencer a outra loja e não houver
          autorização explícita de substituição (RN-040);
        - Rejeita se ultrapassar o teto de 20 unidades por item (RN-042);
        - Rejeita com HTTP 403 Forbidden se o item tiver restrição etária (álcool/tabaco)
          e o utilizador for menor de 18 anos ou não possuir data de nascimento (RN-044).
        """
        serializer = AdicionarItemCarrinhoSerializer(
            data=request.data,
            context={"request": request},
        )
        serializer.is_valid(raise_exception=True)

        item = serializer.validated_data["_item_model"]
        loja = serializer.validated_data["_loja_model"]
        opcoes = serializer.validated_data["_opcoes_estruturadas"]
        is_restrito = serializer.validated_data["_is_restrito"]
        quantidade = serializer.validated_data.get("quantidade", 1)
        notas = serializer.validated_data.get("notas", "")
        preferencia_substituicao = serializer.validated_data.get("preferencia_substituicao")
        substituir_carrinho = serializer.validated_data.get("substituir_carrinho_existente", False)

        novo_item_payload = {
            "item_id": str(item.id),
            "nome": item.nome,
            "preco_unitario": item.preco,
            "quantidade": quantidade,
            "opcoes": opcoes,
            "notas": notas,
            "preferencia_substituicao": preferencia_substituicao,
            "contem_artigos_restritos": is_restrito,
        }

        carrinho_atualizado = CartService.adicionar_ou_atualizar_item(
            user_id=request.user.id,
            novo_item=novo_item_payload,
            loja_id=str(loja.id),
            loja_nome=loja.nome,
            substituir_carrinho=substituir_carrinho,
        )

        output_serializer = CarrinhoOutputSerializer(carrinho_atualizado)
        return Response(output_serializer.data, status=status.HTTP_201_CREATED)

    # =========================================================================
    # 3. PATCH /api/v1/cart/items/{item_id}/
    # =========================================================================
    @action(
        detail=False,
        methods=["patch"],
        url_path=r"items/(?P<item_id>[0-9a-fA-F-]+)",
        url_name="update-item-quantity",
    )
    def update_quantity(
        self,
        request: Request,
        item_id: str | None = None,
        *args: Any,
        **kwargs: Any,
    ) -> Response:
        """
        Atualiza a quantidade de um item no carrinho. Se quantidade for 0, remove o item.
        Valida o teto configurável de 20 unidades (RN-042).
        """
        serializer = AtualizarQuantidadeItemSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        nova_quantidade = serializer.validated_data["quantidade"]

        carrinho_atualizado = CartService.atualizar_quantidade_item(
            user_id=request.user.id,
            item_id=str(item_id),
            nova_quantidade=nova_quantidade,
        )

        output_serializer = CarrinhoOutputSerializer(carrinho_atualizado)
        return Response(output_serializer.data, status=status.HTTP_200_OK)

    # =========================================================================
    # 4. DELETE /api/v1/cart/items/{item_id}/
    # =========================================================================
    @action(
        detail=False,
        methods=["delete"],
        url_path=r"items/(?P<item_id>[0-9a-fA-F-]+)/remove",
        url_name="remove-item",
    )
    def remove_item(
        self,
        request: Request,
        item_id: str | None = None,
        *args: Any,
        **kwargs: Any,
    ) -> Response:
        """Remove completamente um item do carrinho ativo."""
        carrinho_atualizado = CartService.remover_item(
            user_id=request.user.id,
            item_id=str(item_id),
        )
        output_serializer = CarrinhoOutputSerializer(carrinho_atualizado)
        return Response(output_serializer.data, status=status.HTTP_200_OK)

    # =========================================================================
    # 5. POST /api/v1/cart/items/substitute-preference/ (RN-063)
    # =========================================================================
    @action(
        detail=False,
        methods=["post"],
        url_path="items/substitute-preference",
        url_name="substitute-preference",
    )
    def substitute_preference(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        RN-063:
        Regista a preferência de substituição do cliente para ser aplicada de forma
        automatizada caso o produto fique indisponível após a submissão do pedido:
        - REMOVER: Remove o item do pedido e recalcula o total financeiro;
        - SUBSTITUIR_EQUIVALENTE: Substitui o item por um equivalente sugerido pelo parceiro;
        - CANCELAR_ITEM: Cancela a linha do item ou notifica o cliente.

        Se `item_id` for fornecido, aplica especificamente a esse produto. Se omitido/null,
        define como a política padrão para todos os itens do carrinho ativo.
        """
        serializer = PreferenciaSubstituicaoSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        item_id = serializer.validated_data.get("item_id")
        preferencia = serializer.validated_data["preferencia"]

        try:
            carrinho_atualizado = CartService.definir_preferencia_substituicao(
                user_id=request.user.id,
                preferencia=preferencia,
                item_id=str(item_id) if item_id else None,
            )
        except ValueError as exc:
            return Response(
                {"erro": "ITEM_NOT_FOUND_IN_CART", "mensagem": str(exc)},
                status=status.HTTP_404_NOT_FOUND,
            )

        output_serializer = CarrinhoOutputSerializer(carrinho_atualizado)
        return Response(
            {
                "status": "preferencia_atualizada",
                "preferencia_definida": preferencia,
                "item_id": str(item_id) if item_id else None,
                "carrinho": output_serializer.data,
            },
            status=status.HTTP_200_OK,
        )

    # =========================================================================
    # 6. DELETE /api/v1/cart/ ou POST /api/v1/cart/clear/
    # =========================================================================
    @action(detail=False, methods=["delete", "post"], url_path="clear", url_name="clear-cart")
    def clear(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """Esvazia integralmente o carrinho ativo do utilizador autenticado."""
        CartService.limpar_carrinho(request.user.id)
        carrinho_vazio = CartService.obter_carrinho(request.user.id)
        output_serializer = CarrinhoOutputSerializer(carrinho_vazio)
        return Response(
            {
                "status": "carrinho_limpo",
                "mensagem": _("O carrinho foi esvaziado com sucesso."),
                "carrinho": output_serializer.data,
            },
            status=status.HTTP_200_OK,
        )

