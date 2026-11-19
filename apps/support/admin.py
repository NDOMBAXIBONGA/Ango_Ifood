"""
Configuração do Django Admin para a aplicação 'support'.
Permite gerir Tickets de Suporte, Disputas de Pedidos e Parâmetros de Configuração Operacional.
"""
from django.contrib import admin
from apps.support.models import Parametro, TicketDisputa


@admin.register(TicketDisputa)
class TicketDisputaAdmin(admin.ModelAdmin):
    list_display = (
        "id_curto",
        "pedido",
        "utilizador_reclamante",
        "tipo_incidente",
        "prioridade",
        "estado",
        "decisao",
        "criado_em",
    )
    list_filter = ("estado", "prioridade", "tipo_incidente", "decisao", "criado_em")
    search_fields = (
        "id",
        "pedido__id",
        "utilizador_reclamante__nome",
        "utilizador_reclamante__telemovel",
        "motivo",
    )
    readonly_fields = ("id", "criado_em", "atualizado_em")
    ordering = ("-criado_em",)

    @admin.display(description="Ticket")
    def id_curto(self, obj: TicketDisputa) -> str:
        return f"TCK-{str(obj.id)[:8].upper()}"


@admin.register(Parametro)
class ParametroAdmin(admin.ModelAdmin):
    list_display = ("chave", "nome", "valor", "tipo_dado", "ambito", "versao")
    list_filter = ("ambito", "tipo_dado")
    search_fields = ("chave", "nome")
    ordering = ("chave",)
