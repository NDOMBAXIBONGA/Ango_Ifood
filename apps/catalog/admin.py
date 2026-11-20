"""
Configuração do Django Admin para a aplicação 'catalog'.
Permite gerir Lojas Parceiras, Cardápios, Categorias, Itens, Opções e Mídias de Vitrine.
"""
from django.contrib import admin
from django.utils.translation import gettext_lazy as _

from core.admin_base import MasterModelAdmin, TabularInline, display
from apps.catalog.models import (
    CategoriaItem,
    GrupoOpcao,
    HorarioFuncionamento,
    ItemMenu,
    MidiaLoja,
    OpcaoItem,
    ParceiroLoja,
)


class HorarioFuncionamentoInline(TabularInline):
    model = HorarioFuncionamento
    extra = 1
    fields = ("dia_semana", "hora_abertura", "hora_fecho", "is_pausa_temporaria")


class MidiaLojaInline(TabularInline):
    model = MidiaLoja
    extra = 1
    fields = ("tipo", "nome_arquivo", "url", "legenda")


@admin.register(ParceiroLoja)
class ParceiroLojaAdmin(MasterModelAdmin):
    list_display = (
        "nome",
        "nif",
        "contacto",
        "estado_badge",
        "raio_entrega_km",
        "comissao_percentagem",
        "score_reputacao",
        "is_patrocinado",
        "is_entrega_gratis",
    )
    list_filter = ("estado", "is_patrocinado", "is_entrega_gratis")
    search_fields = ("nome", "nif", "contacto", "morada_texto")
    inlines = [HorarioFuncionamentoInline, MidiaLojaInline]
    ordering = ("nome",)

    @display(
        description=_("Estado"),
        label={
            "PENDENTE": "warning",
            "ATIVO": "success",
            "SUSPENSO": "danger",
            "INATIVO": "secondary",
        },
    )
    def estado_badge(self, obj: ParceiroLoja) -> str:
        return obj.estado

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
                    "is_entrega_gratis",
                ),
            },
        ),
        (
            _("Métricas e Reputação"),
            {
                "fields": (
                    "comissao_percentagem",
                    "score_reputacao",
                    "is_patrocinado",
                ),
            },
        ),
    )


@admin.register(CategoriaItem)
class CategoriaItemAdmin(MasterModelAdmin):
    list_display = ("nome", "loja", "ordem_exibicao")
    list_filter = ("loja",)
    search_fields = ("nome", "loja__nome")
    ordering = ("loja", "ordem_exibicao", "nome")


class OpcaoItemInline(TabularInline):
    model = OpcaoItem
    extra = 1
    fields = ("nome", "preco_adicional", "is_disponivel")


@admin.register(GrupoOpcao)
class GrupoOpcaoAdmin(MasterModelAdmin):
    list_display = ("nome", "item", "minimo_escolhas", "maximo_escolhas", "is_obrigatorio")
    list_filter = ("is_obrigatorio", "item__loja")
    search_fields = ("nome", "item__nome", "item__loja__nome")
    inlines = [OpcaoItemInline]


@admin.register(OpcaoItem)
class OpcaoItemAdmin(MasterModelAdmin):
    list_display = ("nome", "grupo", "preco_adicional", "is_disponivel")
    list_filter = ("is_disponivel", "grupo__item__loja")
    search_fields = ("nome", "grupo__nome")


@admin.register(ItemMenu)
class ItemMenuAdmin(MasterModelAdmin):
    list_display = (
        "nome",
        "loja",
        "categoria",
        "preco",
        "is_disponivel",
        "is_destaque",
    )
    list_filter = ("is_disponivel", "is_destaque", "loja", "categoria")
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
                    "preco",
                    "imagem_url",
                    "alergenos",
                )
            },
        ),
        (
            _("Disponibilidade e Destaque"),
            {
                "fields": (
                    "is_disponivel",
                    "is_destaque",
                ),
            },
        ),
    )


@admin.register(HorarioFuncionamento)
class HorarioFuncionamentoAdmin(MasterModelAdmin):
    list_display = ("loja", "dia_semana", "hora_abertura", "hora_fecho", "is_pausa_temporaria")
    list_filter = ("dia_semana", "is_pausa_temporaria", "loja")
    ordering = ("loja", "dia_semana")


@admin.register(MidiaLoja)
class MidiaLojaAdmin(MasterModelAdmin):
    list_display = ("loja", "tipo", "nome_arquivo", "url", "criado_em")
    list_filter = ("tipo", "loja", "criado_em")
    search_fields = ("loja__nome", "nome_arquivo", "legenda")
    ordering = ("loja", "-criado_em")
