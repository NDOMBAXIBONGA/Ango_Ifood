"""
Configuração do Django Admin para a aplicação 'promotions'.
Gere Cupões de Desconto e Campanhas Promocionais.
"""
from django.contrib import admin
from core.admin_base import MasterModelAdmin
from apps.promotions.models import CupaoDesconto


@admin.register(CupaoDesconto)
class CupaoDescontoAdmin(MasterModelAdmin):
    list_display = (
        "codigo",
        "tipo_desconto",
        "valor",
        "financiador",
        "montante_minimo_pedido",
        "limite_global_uso",
        "validade_inicio",
        "validade_fim",
    )
    list_filter = ("tipo_desconto", "financiador", "validade_inicio", "validade_fim")
    search_fields = ("codigo",)
    ordering = ("-validade_inicio", "codigo")
