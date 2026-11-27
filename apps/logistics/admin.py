"""
Configuração do Django Admin para a aplicação 'logistics'.
Gere o cadastro, verificação e monitoramento de Estafetas e Entregas operacionais em tempo real.
"""
from django.contrib import admin, messages
from django.http import HttpRequest
from django.utils.translation import gettext_lazy as _

from core.admin_base import MasterModelAdmin, display
from apps.logistics.models import Entrega, Estafeta


@admin.register(Estafeta)
class EstafetaAdmin(MasterModelAdmin):
    list_display = (
        "utilizador",
        "tipo_veiculo",
        "carta_conducao",
        "status_onboarding_badge",
        "is_online_badge",
        "score_reputacao",
        "saldo_carteira",
    )
    list_filter = ("status_onboarding", "is_online", "tipo_veiculo")
    search_fields = (
        "utilizador__nome",
        "utilizador__telemovel",
        "utilizador__email",
        "carta_conducao",
    )
    ordering = ("-score_reputacao", "utilizador__nome")
    actions = ["aprovar_onboarding", "bloquear_estafeta", "export_to_csv"]

    @display(
        description=_("Onboarding"),
        label={
            "PENDENTE": "warning",
            "APROVADO": "success",
            "REJEITADO": "danger",
            "BLOQUEADO": "danger",
        },
    )
    def status_onboarding_badge(self, obj: Estafeta) -> str:
        return obj.status_onboarding

    @display(
        description=_("Disponibilidade"),
        boolean=True,
    )
    def is_online_badge(self, obj: Estafeta) -> bool:
        return obj.is_online

    fieldsets = (
        (
            _("Identificação e Veículo"),
            {
                "fields": (
                    "utilizador",
                    "tipo_veiculo",
                    "marca_modelo_veiculo",
                    "matricula_veiculo",
                    "carta_conducao",
                    "carta_conducao_url",
                    "documentos_veiculo_url",
                    "navegador_padrao",
                )
            },
        ),
        (
            _("Dados Bancários e Fiscais (Repasses)"),
            {
                "fields": (
                    "nif",
                    "banco_nome",
                    "numero_conta",
                    "iban",
                )
            },
        ),
        (
            _("Operação e Desempenho"),
            {
                "fields": (
                    "status_onboarding",
                    "is_online",
                    "score_reputacao",
                    "saldo_carteira",
                )
            },
        ),
    )

    @admin.action(description="✅ Aprovar Onboarding dos Estafetas Selecionados")
    def aprovar_onboarding(self, request: HttpRequest, queryset):
        atualizados = queryset.update(status_onboarding="APROVADO")
        self.message_user(request, f"{atualizados} estafeta(s) aprovado(s) com sucesso.", level=messages.SUCCESS)

    @admin.action(description="🛑 Bloquear Estafetas Selecionados")
    def bloquear_estafeta(self, request: HttpRequest, queryset):
        atualizados = queryset.update(is_online=False, status_onboarding="BLOQUEADO")
        self.message_user(request, f"{atualizados} estafeta(s) bloqueado(s) temporariamente.", level=messages.WARNING)


@admin.register(Entrega)
class EntregaAdmin(MasterModelAdmin):
    protected_from_deletion = True  # Proteção auditável para pedidos e entregas
    list_display = (
        "id_curto",
        "pedido",
        "estafeta",
        "estado_logistico_badge",
        "pin_entrega",
        "distancia_km",
        "eta_estimada",
    )
    list_filter = ("estado_logistico", "eta_estimada")
    search_fields = (
        "id",
        "pedido__id",
        "estafeta__utilizador__nome",
        "estafeta__utilizador__telemovel",
        "pin_entrega",
    )
    readonly_fields = ("id", "eta_estimada")
    ordering = ("-eta_estimada",)
    actions = ["marcar_entregue_manual", "export_to_csv"]

    @display(
        description=_("Estado Logístico"),
        label={
            "PENDENTE_ATRIBUICAO": "secondary",
            "ATRIBUIDO": "info",
            "A_CAMINHO_RECOLHA": "warning",
            "RECOLHIDO": "purple",
            "A_CAMINHO_ENTREGA": "primary",
            "ENTREGUE": "success",
            "FALHADA": "danger",
        },
    )
    def estado_logistico_badge(self, obj: Entrega) -> str:
        return obj.estado_logistico

    @admin.display(description="Distância (km)")
    def distancia_km(self, obj: Entrega) -> str:
        if obj.distancia_metros is not None:
            try:
                return f"{float(obj.distancia_metros) / 1000.0:.2f} km"
            except (ValueError, TypeError):
                return f"{obj.distancia_metros} m"
        return "0.00 km"

    @admin.display(description="Entrega")
    def id_curto(self, obj: Entrega) -> str:
        return f"ENT-{str(obj.id)[:8].upper()}"

    @admin.action(description="📦 Forçar Conclusão de Entrega (Administrativo / Auditado)")
    def marcar_entregue_manual(self, request: HttpRequest, queryset):
        for entrega in queryset:
            entrega.estado_logistico = "ENTREGUE"
            entrega.save()
        self.message_user(request, f"{queryset.count()} entrega(s) concluída(s) administrativamente.", level=messages.INFO)
