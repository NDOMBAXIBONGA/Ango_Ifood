"""
Modelos e Escolhas da aplicação 'cart' (Carrinho de Compras e Preferências de Substituição).
Implementa a regra de negócio RN-063.
"""
from django.db import models
from django.utils.translation import gettext_lazy as _


class PreferenciaSubstituicao(models.TextChoices):
    """
    RN-063: Opções automáticas de substituição caso um item fique indisponível após a submissão:
    1. REMOVER: Remove o item do pedido e ajusta o subtotal automaticamente.
    2. SUBSTITUIR_EQUIVALENTE: Substitui o item por um produto equivalente sugerido pelo parceiro.
    3. CANCELAR_ITEM: Cancela a linha do item ou notifica o cliente antes de prosseguir.
    """

    REMOVER = "REMOVER", _("Remover Item e Recalcular Total")
    SUBSTITUIR_EQUIVALENTE = "SUBSTITUIR_EQUIVALENTE", _("Substituir por Equivalente")
    CANCELAR_ITEM = "CANCELAR_ITEM", _("Cancelar o Item")

