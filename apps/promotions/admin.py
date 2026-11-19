"""
Configuração do Django Admin para a aplicação 'promotions'.
Gere Cupões de Desconto e Campanhas Promocionais.
"""
from django.contrib import admin
from apps.promotions.models import CupaoDesconto


@admin.register(CupaoDesconto)
class CupaoDescontoAdmin(admin.ModelAdmin):
    list_display = (
        "codigo",
        "tipo_desconto",
        "valor_desconto",
        "financiador",
        "ativo",
        "utilizacoes_atuais",
        "limite_utilizacoes_global",
        "data_inicio",
        "data_fim",
    )
    list_filter = ("ativo", "tipo_desconto", "financiador", "data_inicio", "data_fim")
    search_fields = ("codigo",)
    ordering = ("-data_inicio", "codigo")
