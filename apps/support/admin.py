"""
Configuração do Django Admin para a aplicação 'support'.
Permite gerir Tickets de Suporte, Disputas de Pedidos e Parâmetros de Configuração Operacional.
"""
from django.contrib import admin
from core.admin_base import MasterModelAdmin
from apps.support.models import Parametro, TicketDisputa


@admin.register(TicketDisputa)
class TicketDisputaAdmin(MasterModelAdmin):
    list_display = (
        "id_curto",
        "pedido",
        "utilizador_reclamante",
        "tipo_incidente",
        "prioridade",
        "estado",
        "decisao",
        "data_criacao",
    )
    list_filter = ("estado", "prioridade", "tipo_incidente", "decisao", "data_criacao")
    search_fields = (
        "id",
        "pedido__id",
        "pedido__cliente__nome",
        "pedido__cliente__telemovel",
        "motivo",
    )
    readonly_fields = ("id", "data_criacao", "data_atualizacao")
    ordering = ("-data_criacao",)

    @admin.display(description="Ticket")
    def id_curto(self, obj: TicketDisputa) -> str:
        return f"TCK-{str(obj.id)[:8].upper()}"

    @admin.display(description="Cliente / Reclamante")
    def utilizador_reclamante(self, obj: TicketDisputa) -> str:
        if obj.pedido and getattr(obj.pedido, "cliente", None):
            return obj.pedido.cliente.nome or obj.pedido.cliente.telemovel
        return "-"


@admin.register(Parametro)
class ParametroAdmin(MasterModelAdmin):
    list_display = ("chave", "nome", "valor", "unidade", "ambito", "versao")
    list_filter = ("ambito", "unidade")
    search_fields = ("chave", "nome")
    ordering = ("chave",)
