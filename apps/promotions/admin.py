"""
Configuração do Django Admin para a aplicação 'promotions'.
Gere Cupões de Desconto e Campanhas Promocionais.
"""
from django.contrib import admin
from django.utils.translation import gettext_lazy as _
from core.admin_base import MasterModelAdmin, display
from apps.promotions.models import CupaoDesconto


@admin.register(CupaoDesconto)
class CupaoDescontoAdmin(MasterModelAdmin):
    list_display = (
        "codigo",
        "tipo_desconto_badge",
        "valor",
        "financiador_badge",
        "montante_minimo_pedido",
        "limite_global_uso",
        "validade_inicio",
        "validade_fim",
    )
    list_filter = ("tipo_desconto", "financiador", "validade_inicio", "validade_fim")
    search_fields = ("codigo",)
    ordering = ("-validade_inicio", "codigo")

    @display(
        description=_("Tipo"),
        label={
            "PERCENTAGEM": "primary",
            "VALOR_FIXO": "success",
            "ENTREGA_GRATIS": "info",
        },
    )
    def tipo_desconto_badge(self, obj: CupaoDesconto) -> str:
        return obj.tipo_desconto or "PERCENTAGEM"

    @display(
        description=_("Financiador"),
        label={
            "PLATAFORMA": "purple",
            "PARCEIRO": "warning",
            "MISTO": "secondary",
        },
    )
    def financiador_badge(self, obj: CupaoDesconto) -> str:
        return obj.financiador or "PLATAFORMA"
