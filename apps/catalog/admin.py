"""
Configuração do Django Admin para a aplicação 'catalog'.
Permite gerir Lojas Parceiras, Cardápios, Categorias, Itens, Opções e Mídias de Vitrine.
"""
from django.contrib import admin
from django.utils.html import format_html
from django.utils.translation import gettext_lazy as _

from apps.catalog.models import (
    CategoriaItem,
    GrupoOpcao,
    HorarioFuncionamento,
    ItemMenu,
    MidiaLoja,
    OpcaoItem,
    ParceiroLoja,
)


class HorarioFuncionamentoInline(admin.TabularInline):
    model = HorarioFuncionamento
    extra = 1
    fields = ("dia_semana", "abertura", "fecho", "aberto")


class MidiaLojaInline(admin.TabularInline):
    model = MidiaLoja
    extra = 1
    fields = ("tipo", "ficheiro", "url_remota", "ordem", "ativo")


@admin.register(ParceiroLoja)
class ParceiroLojaAdmin(admin.ModelAdmin):
    list_display = (
        "nome",
        "nif",
        "contacto",
        "estado",
        "raio_entrega_km",
        "classificacao_media",
        "total_avaliacoes",
    )
    list_filter = ("estado",)
    search_fields = ("nome", "nif", "contacto", "morada_texto")
    inlines = [HorarioFuncionamentoInline, MidiaLojaInline]
    ordering = ("nome",)

    fieldsets = (
        (
            _("Informações Gerais"),
            {
                "fields": (
                    "nome",
                    "nif",
                    "proprietario",
                    "estado",
                    "contacto",
                    "morada_texto",
                )
            },
        ),
        (
            _("Licenças e Fiscal"),
            {
                "fields": ("alvara", "licenca_sanitaria", "dados_bancarios"),
            },
        ),
        (
            _("Logística e Cobertura"),
            {
                "fields": (
                    "geolocalizacao",
                    "raio_entrega_km",
                    "poligono_cobertura",
                ),
            },
        ),
        (
            _("Métricas e Reputação"),
            {
                "fields": (
                    "classificacao_media",
                    "total_avaliacoes",
                ),
            },
        ),
    )


@admin.register(CategoriaItem)
class CategoriaItemAdmin(admin.ModelAdmin):
    list_display = ("nome", "loja", "ordem", "ativo")
    list_filter = ("ativo", "loja")
    search_fields = ("nome", "loja__nome")
    ordering = ("loja", "ordem", "nome")


class OpcaoItemInline(admin.TabularInline):
    model = OpcaoItem
    extra = 1
    fields = ("nome", "preco_adicional", "disponivel", "ordem")


@admin.register(GrupoOpcao)
class GrupoOpcaoAdmin(admin.ModelAdmin):
    list_display = ("nome", "item_menu", "min_selecao", "max_selecao", "obrigatorio")
    list_filter = ("obrigatorio", "item_menu__loja")
    search_fields = ("nome", "item_menu__nome", "item_menu__loja__nome")
    inlines = [OpcaoItemInline]


@admin.register(OpcaoItem)
class OpcaoItemAdmin(admin.ModelAdmin):
    list_display = ("nome", "grupo", "preco_adicional", "disponivel", "ordem")
    list_filter = ("disponivel", "grupo__item_menu__loja")
    search_fields = ("nome", "grupo__nome")


@admin.register(ItemMenu)
class ItemMenuAdmin(admin.ModelAdmin):
    list_display = (
        "nome",
        "loja",
        "categoria",
        "preco_base",
        "disponivel",
        "em_destaque",
        "tempo_preparo_minutos",
    )
    list_filter = ("disponivel", "em_destaque", "loja", "categoria")
    search_fields = ("nome", "descricao", "loja__nome")
    ordering = ("loja", "categoria", "nome")

    fieldsets = (
        (
            _("Identificação do Produto"),
            {
                "fields": (
                    "loja",
                    "categoria",
                    "nome",
                    "descricao",
                    "preco_base",
                    "imagem",
                )
            },
        ),
        (
            _("Disponibilidade e Operações"),
            {
                "fields": (
                    "disponivel",
                    "em_destaque",
                    "tempo_preparo_minutos",
                    "ordem",
                ),
            },
        ),
    )


@admin.register(HorarioFuncionamento)
class HorarioFuncionamentoAdmin(admin.ModelAdmin):
    list_display = ("loja", "dia_semana", "abertura", "fecho", "aberto")
    list_filter = ("dia_semana", "aberto", "loja")
    ordering = ("loja", "dia_semana")


@admin.register(MidiaLoja)
class MidiaLojaAdmin(admin.ModelAdmin):
    list_display = ("loja", "tipo", "ficheiro", "ativo", "ordem", "data_criacao")
    list_filter = ("tipo", "ativo", "loja")
    search_fields = ("loja__nome", "titulo", "descricao")
    ordering = ("loja", "ordem", "-data_criacao")
