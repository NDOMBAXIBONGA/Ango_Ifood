"""
Configuração do Django Admin para a aplicação 'logistics'.
Gere o cadastro, verificação e monitoramento de Estafetas e Entregas operacionais em tempo real.
"""
from django.contrib import admin, messages
from django.http import HttpRequest
from django.utils.translation import gettext_lazy as _

from core.admin_base import MasterModelAdmin
from apps.logistics.models import Entrega, Estafeta


@admin.register(Estafeta)
class EstafetaAdmin(MasterModelAdmin):
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
    actions = ["aprovar_onboarding", "bloquear_estafeta", "export_to_csv"]

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

    @admin.action(description="✅ Aprovar Onboarding dos Estafetas Selecionados")
    def aprovar_onboarding(self, request: HttpRequest, queryset):
        atualizados = queryset.update(status_onboarding="APROVADO", ativo=True)
        self.message_user(request, f"{atualizados} estafeta(s) aprovado(s) com sucesso.", level=messages.SUCCESS)

    @admin.action(description="🛑 Bloquear Estafetas Selecionados")
    def bloquear_estafeta(self, request: HttpRequest, queryset):
        atualizados = queryset.update(ativo=False, disponivel=False)
        self.message_user(request, f"{atualizados} estafeta(s) bloqueado(s) temporariamente.", level=messages.WARNING)


@admin.register(Entrega)
class EntregaAdmin(MasterModelAdmin):
    protected_from_deletion = True  # Proteção auditável para pedidos e entregas
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
    actions = ["marcar_entregue_manual", "export_to_csv"]

    @admin.display(description="Entrega")
    def id_curto(self, obj: Entrega) -> str:
        return f"ENT-{str(obj.id)[:8].upper()}"

    @admin.action(description="📦 Forçar Conclusão de Entrega (Administrativo / Auditado)")
    def marcar_entregue_manual(self, request: HttpRequest, queryset):
        for entrega in queryset:
            entrega.estado_logistico = "ENTREGUE"
            entrega.save()
        self.message_user(request, f"{queryset.count()} entrega(s) concluída(s) administrativamente.", level=messages.INFO)
