"""
Configuração do Django Admin para a aplicação 'logistics'.
Gere o cadastro e monitoramento de Estafetas e Entregas operacionais.
"""
from django.contrib import admin
from django.utils.translation import gettext_lazy as _

from apps.logistics.models import Entrega, Estafeta


@admin.register(Estafeta)
class EstafetaAdmin(admin.ModelAdmin):
    list_display = (
        "utilizador",
        "tipo_veiculo",
        "matricula",
        "status_onboarding",
        "ativo",
        "disponivel",
        "classificacao_media",
    )
    list_filter = ("status_onboarding", "ativo", "disponivel", "tipo_veiculo")
    search_fields = (
        "utilizador__nome",
        "utilizador__telemovel",
        "utilizador__email",
        "matricula",
    )
    ordering = ("-ativo", "utilizador__nome")

    fieldsets = (
        (
            _("Identificação e Veículo"),
            {
                "fields": (
                    "utilizador",
                    "tipo_veiculo",
                    "matricula",
                    "modelo_veiculo",
                )
            },
        ),
        (
            _("Operação e Disponibilidade"),
            {
                "fields": (
                    "status_onboarding",
                    "ativo",
                    "disponivel",
                    "classificacao_media",
                )
            },
        ),
    )


@admin.register(Entrega)
class EntregaAdmin(admin.ModelAdmin):
    list_display = (
        "id_curto",
        "pedido",
        "estafeta",
        "estado_logistico",
        "codigo_confirmacao_pin",
        "distancia_km",
        "criado_em",
    )
    list_filter = ("estado_logistico", "criado_em")
    search_fields = (
        "id",
        "pedido__id",
        "estafeta__utilizador__nome",
        "estafeta__utilizador__telemovel",
        "codigo_confirmacao_pin",
    )
    readonly_fields = ("id", "criado_em", "atualizado_em")
    ordering = ("-criado_em",)

    @admin.display(description="Entrega")
    def id_curto(self, obj: Entrega) -> str:
        return f"ENT-{str(obj.id)[:8].upper()}"
