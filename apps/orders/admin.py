"""
Configuração do Django Admin para a aplicação 'orders'.
Gere Pedidos (OMS), Linhas de Pedidos e Opções Selecionadas.
"""
from django.contrib import admin
from django.utils.translation import gettext_lazy as _

from core.admin_base import MasterModelAdmin
from apps.orders.models import LinhaPedido, LinhaPedidoOpcaoSelecionada, Pedido


class LinhaPedidoOpcaoSelecionadaInline(admin.TabularInline):
    model = LinhaPedidoOpcaoSelecionada
    extra = 0
    readonly_fields = ("opcao", "preco_unitario_cobrado")


class LinhaPedidoInline(admin.TabularInline):
    model = LinhaPedido
    extra = 0
    fields = ("item", "quantidade", "preco_unitario_base", "total_linha", "instrucoes_especiais")
    readonly_fields = ("total_linha",)


@admin.register(Pedido)
class PedidoAdmin(MasterModelAdmin):
    protected_from_deletion = True  # Proteção de integridade contra deleção de pedidos
    list_display = (
        "id_curto",
        "cliente",
        "loja",
        "estado",
        "total_formatado",
        "metodo_pagamento",
        "data_criacao",
    )
    list_filter = ("estado", "metodo_pagamento", "loja", "data_criacao")
    search_fields = (
        "id",
        "cliente__nome",
        "cliente__telemovel",
        "cliente__email",
        "loja__nome",
    )
    ordering = ("-data_criacao",)
    inlines = [LinhaPedidoInline]
    actions = ["export_to_csv"]

    fieldsets = (
        (
            _("Identificação do Pedido"),
            {
                "fields": (
                    "id",
                    "cliente",
                    "loja",
                    "estado",
                    "metodo_pagamento",
                )
            },
        ),
        (
            _("Discriminação Financeira (Valores em Unidades Mínimas / Cêntimos de Kz)"),
            {
                "fields": (
                    "subtotal",
                    "taxa_entrega",
                    "taxa_servico",
                    "taxa_pequeno_pedido",
                    "gorjeta_estafeta",
                    "descontos",
                    "total_cobrado",
                )
            },
        ),
        (
            _("Prazos e Auditoria"),
            {
                "fields": (
                    "cotacao_expira_em",
                    "data_criacao",
                    "data_atualizacao",
                )
            },
        ),
    )

    readonly_fields = ("id", "data_criacao", "data_atualizacao")

    @admin.display(description="Pedido")
    def id_curto(self, obj: Pedido) -> str:
        return f"#{str(obj.id)[:8].upper()}"

    @admin.display(description="Total")
    def total_formatado(self, obj: Pedido) -> str:
        # Se os valores são armazenados como cêntimos ou valor inteiro de Kz
        return f"{obj.total_cobrado:,.2f} Kz" if obj.total_cobrado else "0.00 Kz"


@admin.register(LinhaPedido)
class LinhaPedidoAdmin(MasterModelAdmin):
    list_display = ("pedido", "item", "quantidade", "preco_unitario_base", "total_linha")
    list_filter = ("pedido__estado", "pedido__loja")
    search_fields = ("pedido__id", "item__nome")
    inlines = [LinhaPedidoOpcaoSelecionadaInline]


@admin.register(LinhaPedidoOpcaoSelecionada)
class LinhaPedidoOpcaoSelecionadaAdmin(MasterModelAdmin):
    list_display = ("linha_pedido", "opcao", "preco_unitario_cobrado")
    search_fields = ("opcao__nome", "linha_pedido__pedido__id")
