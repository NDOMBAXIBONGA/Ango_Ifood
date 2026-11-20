"""
Configuração do Django Admin para a aplicação 'support'.
Permite gerir Tickets de Suporte, Disputas de Pedidos e Parâmetros de Configuração Operacional.
"""
from django.contrib import admin
from django.utils.translation import gettext_lazy as _
from core.admin_base import MasterModelAdmin, display
from apps.support.models import Parametro, TicketDisputa


@admin.register(TicketDisputa)
class TicketDisputaAdmin(MasterModelAdmin):
    list_display = (
        "id_curto",
        "pedido",
        "utilizador_reclamante",
        "tipo_incidente",
        "prioridade_badge",
        "estado_badge",
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

    @display(
        description=_("Prioridade"),
        label={
            "ALTA": "danger",
            "MEDIA": "warning",
            "BAIXA": "info",
        },
    )
    def prioridade_badge(self, obj: TicketDisputa) -> str:
        return obj.prioridade

    @display(
        description=_("Estado"),
        label={
            "ABERTO": "warning",
            "EM_ANALISE": "info",
            "RESOLVIDO": "success",
            "REJEITADO": "secondary",
        },
    )
    def estado_badge(self, obj: TicketDisputa) -> str:
        return obj.estado

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
