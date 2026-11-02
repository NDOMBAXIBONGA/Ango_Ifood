"""
Configuração do Django Admin para a aplicação 'finance'.
Garante visualização de auditoria com permissões estritas de leitura apenas (read-only).
"""
from typing import Any

from django.contrib import admin
from django.http import HttpRequest

from apps.finance.models import EventoPedido, LivroRazaoLedger


@admin.register(EventoPedido)
class EventoPedidoAdmin(admin.ModelAdmin):
    list_display = ("timestamp", "tipo_evento", "autor", "pedido_id")
    list_filter = ("tipo_evento", "timestamp")
    search_fields = ("pedido__id", "autor", "tipo_evento")
    readonly_fields = ("id", "pedido", "tipo_evento", "autor", "timestamp", "dados_adicionais")
    ordering = ("-timestamp",)

    def has_add_permission(self, request: HttpRequest) -> bool:
        return False

    def has_change_permission(self, request: HttpRequest, obj: Any = None) -> bool:
        return False

    def has_delete_permission(self, request: HttpRequest, obj: Any = None) -> bool:
        return False


@admin.register(LivroRazaoLedger)
class LivroRazaoLedgerAdmin(admin.ModelAdmin):
    list_display = ("timestamp", "referencia_pedido_id", "conta_origem", "conta_destino", "debito", "credito")
    list_filter = ("conta_origem", "conta_destino", "timestamp")
    search_fields = ("referencia_pedido__id", "conta_origem", "conta_destino")
    readonly_fields = ("id", "referencia_pedido", "conta_origem", "conta_destino", "debito", "credito", "timestamp")
    ordering = ("-timestamp",)

    def has_add_permission(self, request: HttpRequest) -> bool:
        return False

    def has_change_permission(self, request: HttpRequest, obj: Any = None) -> bool:
        return False

    def has_delete_permission(self, request: HttpRequest, obj: Any = None) -> bool:
        return False

