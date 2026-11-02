"""
Serviço de Gestão Intermédia do Carrinho em Cache Redis ('cart').
Implementa a gestão de estado volátil do carrinho com suporte a:
- RN-040: Unicidade de Loja;
- RN-041: Cálculo de subtotal face ao pedido mínimo da loja;
- RN-042: Limites de quantidade de itens;
- RN-044: Auditoria de artigos restritos por idade;
- RN-063: Preferências automáticas de substituição.
"""
from __future__ import annotations

import logging
import uuid
from typing import Any

from django.conf import settings
from django.core.cache import cache
from django.utils import timezone

from apps.cart.models import PreferenciaSubstituicao

logger = logging.getLogger(__name__)


class CartService:
    """
    Serviço centralizado para persistência e manipulação intermédia do carrinho na cache Redis.
    """

    CACHE_KEY_PREFIX: str = "cart:user:{user_id}"
    CART_TTL_SECONDS: int = getattr(settings, "CART_CACHE_TTL_SECONDS", 60 * 60 * 24)  # 24 Horas

    @classmethod
    def _obter_chave_cache(cls, user_id: uuid.UUID | str) -> str:
        return cls.CACHE_KEY_PREFIX.format(user_id=str(user_id))

    @classmethod
    def obter_carrinho(cls, user_id: uuid.UUID | str) -> dict[str, Any]:
        """Recupera a estrutura do carrinho ativo do utilizador na cache Redis."""
        chave = cls._obter_chave_cache(user_id)
        carrinho = cache.get(chave)
        if not carrinho or not isinstance(carrinho, dict):
            return {
                "utilizador_id": str(user_id),
                "loja_id": None,
                "loja_nome": None,
                "itens": [],
                "preferencia_substituicao_padrao": PreferenciaSubstituicao.SUBSTITUIR_EQUIVALENTE,
                "subtotal": 0,
                "total_itens": 0,
                "criado_em": timezone.now().isoformat(),
                "atualizado_em": timezone.now().isoformat(),
            }
        return carrinho

    @classmethod
    def guardar_carrinho(cls, user_id: uuid.UUID | str, carrinho: dict[str, Any]) -> None:
        """Persiste o carrinho atualizado na cache Redis com TTL configurável."""
        carrinho["atualizado_em"] = timezone.now().isoformat()
        cls.recalcular_totais(carrinho)
        chave = cls._obter_chave_cache(user_id)
        cache.set(chave, carrinho, timeout=cls.CART_TTL_SECONDS)

    @classmethod
    def limpar_carrinho(cls, user_id: uuid.UUID | str) -> None:
        """Elimina completamente o carrinho ativo do utilizador na cache Redis."""
        chave = cls._obter_chave_cache(user_id)
        cache.delete(chave)

    @classmethod
    def recalcular_totais(cls, carrinho: dict[str, Any]) -> None:
        """
        Recalcula o subtotal financeiro em unidades mínimas inteiras e a contagem total de itens.
        """
        subtotal = 0
        total_itens = 0
        for item in carrinho.get("itens", []):
            qtd = int(item.get("quantidade", 0))
            preco_unitario = int(item.get("preco_unitario", 0))
            # Suplementos das opções
            opcoes_total = sum(int(op.get("preco_adicional", 0)) for op in item.get("opcoes", []))
            item_subtotal = (preco_unitario + opcoes_total) * qtd
            item["subtotal_item"] = item_subtotal
            subtotal += item_subtotal
            total_itens += qtd

        carrinho["subtotal"] = subtotal
        carrinho["total_itens"] = total_itens

    @classmethod
    def adicionar_ou_atualizar_item(
        cls,
        user_id: uuid.UUID | str,
        novo_item: dict[str, Any],
        loja_id: str,
        loja_nome: str,
        substituir_carrinho: bool = False,
    ) -> dict[str, Any]:
        """
        Adiciona uma linha de item ao carrinho ou acumula a quantidade caso o mesmo
        item e opções já existam.
        """
        carrinho = cls.obter_carrinho(user_id)

        # Se for solicitado substituir carrinho ou se o carrinho anterior estiver vazio
        if substituir_carrinho or not carrinho.get("itens") or carrinho.get("loja_id") != loja_id:
            carrinho = {
                "utilizador_id": str(user_id),
                "loja_id": loja_id,
                "loja_nome": loja_nome,
                "itens": [],
                "preferencia_substituicao_padrao": PreferenciaSubstituicao.SUBSTITUIR_EQUIVALENTE,
                "subtotal": 0,
                "total_itens": 0,
                "criado_em": timezone.now().isoformat(),
                "atualizado_em": timezone.now().isoformat(),
            }

        carrinho["loja_id"] = loja_id
        carrinho["loja_nome"] = loja_nome

        # Identifica se já existe o mesmo item com as mesmas opções
        itens_existentes = carrinho.setdefault("itens", [])
        opcoes_ids_novas = sorted(str(op.get("opcao_id")) for op in novo_item.get("opcoes", []))

        item_encontrado = None
        for item in itens_existentes:
            if str(item.get("item_id")) == str(novo_item["item_id"]):
                opcoes_ids_existentes = sorted(str(op.get("opcao_id")) for op in item.get("opcoes", []))
                if opcoes_ids_existentes == opcoes_ids_novas:
                    item_encontrado = item
                    break

        if item_encontrado:
            item_encontrado["quantidade"] = int(item_encontrado.get("quantidade", 0)) + int(novo_item["quantidade"])
            if novo_item.get("notas"):
                item_encontrado["notas"] = novo_item["notas"]
            if novo_item.get("preferencia_substituicao"):
                item_encontrado["preferencia_substituicao"] = novo_item["preferencia_substituicao"]
        else:
            itens_existentes.append(novo_item)

        cls.guardar_carrinho(user_id, carrinho)
        return carrinho

    @classmethod
    def atualizar_quantidade_item(
        cls,
        user_id: uuid.UUID | str,
        item_id: str,
        nova_quantidade: int,
    ) -> dict[str, Any]:
        """
        Atualiza a quantidade de um item no carrinho. Se quantidade <= 0, remove o item.
        """
        carrinho = cls.obter_carrinho(user_id)
        itens = carrinho.get("itens", [])

        if nova_quantidade <= 0:
            carrinho["itens"] = [it for it in itens if str(it.get("item_id")) != str(item_id)]
        else:
            for it in itens:
                if str(it.get("item_id")) == str(item_id):
                    it["quantidade"] = nova_quantidade
                    break

        if not carrinho["itens"]:
            carrinho["loja_id"] = None
            carrinho["loja_nome"] = None

        cls.guardar_carrinho(user_id, carrinho)
        return carrinho

    @classmethod
    def remover_item(cls, user_id: uuid.UUID | str, item_id: str) -> dict[str, Any]:
        """Remove todas as ocorrências de um determinado item do carrinho."""
        return cls.atualizar_quantidade_item(user_id, item_id, nova_quantidade=0)

    @classmethod
    def definir_preferencia_substituicao(
        cls,
        user_id: uuid.UUID | str,
        preferencia: str,
        item_id: str | None = None,
    ) -> dict[str, Any]:
        """
        RN-063: Define a preferência de substituição de um item específico ou
        globalmente para todos os itens do carrinho ativo.
        """
        carrinho = cls.obter_carrinho(user_id)
        if item_id:
            encontrado = False
            for it in carrinho.get("itens", []):
                if str(it.get("item_id")) == str(item_id):
                    it["preferencia_substituicao"] = preferencia
                    encontrado = True
                    break
            if not encontrado:
                raise ValueError(f"Item com ID {item_id} não encontrado no carrinho.")
        else:
            carrinho["preferencia_substituicao_padrao"] = preferencia
            for it in carrinho.get("itens", []):
                it["preferencia_substituicao"] = preferencia

        cls.guardar_carrinho(user_id, carrinho)
        return carrinho

