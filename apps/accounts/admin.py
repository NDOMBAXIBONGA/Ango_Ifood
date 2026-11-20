"""
Configuração do Django Admin para a aplicação 'accounts'.
Disponibiliza a gestão de Utilizadores (CustomUser), Moradas, Consentimentos e Sessões OTP.
"""
from django.contrib import admin, messages
from django.contrib.auth.admin import UserAdmin
from django.http import HttpRequest
from django.utils.translation import gettext_lazy as _
from unfold.forms import AdminPasswordChangeForm, UserChangeForm, UserCreationForm

from core.admin_base import MasterModelAdmin, display
from apps.accounts.models import (
    CustomUser,
    Morada,
    PerfilConsentimento,
    RegistoOTP,
    RegistoOTPEmail,
)

# Customização da identidade visual do Django Admin
admin.site.site_header = "Ango_Ifood — Administração Central"
admin.site.site_title = "Ango_Ifood Admin"
admin.site.index_title = "Painel de Gestão e Operações"


class CustomUserCreationForm(UserCreationForm):
    class Meta(UserCreationForm.Meta):
        model = CustomUser
        fields = ("telemovel", "email", "nome", "tipo_utilizador", "estado")


class CustomUserChangeForm(UserChangeForm):
    class Meta(UserChangeForm.Meta):
        model = CustomUser
        fields = "__all__"


@admin.register(CustomUser)
class CustomUserAdmin(MasterModelAdmin, UserAdmin):
    """
    Gestão avançada de utilizadores da plataforma (Cliente, Parceiro, Estafeta, Admin).
    """

    model = CustomUser
    form = CustomUserChangeForm
    add_form = CustomUserCreationForm
    change_password_form = AdminPasswordChangeForm

    list_display = (
        "telemovel",
        "nome",
        "email",
        "tipo_utilizador_badge",
        "estado_badge",
        "is_staff",
        "is_active",
        "data_criacao",
    )
    list_filter = (
        "tipo_utilizador",
        "estado",
        "is_staff",
        "is_superuser",
        "is_active",
        "data_criacao",
    )
    search_fields = ("telemovel", "nome", "email")
    ordering = ("-data_criacao",)

    @display(
        description=_("Tipo"),
        label={
            "CLIENTE": "info",
            "PARCEIRO": "primary",
            "ESTAFETA": "warning",
            "ADMIN": "purple",
        },
    )
    def tipo_utilizador_badge(self, obj: CustomUser) -> str:
        return obj.tipo_utilizador or "CLIENTE"

    @display(
        description=_("Estado"),
        label={
            "ATIVO": "success",
            "SUSPENSO": "warning",
            "BLOQUEADO": "danger",
            "PENDENTE": "secondary",
        },
    )
    def estado_badge(self, obj: CustomUser) -> str:
        return obj.estado or "ATIVO"

    fieldsets = (
        (
            _("Identificação e Papel"),
            {
                "fields": (
                    "telemovel",
                    "email",
                    "nome",
                    "password",
                    "tipo_utilizador",
                    "estado",
                )
            },
        ),
        (
            _("Dados Pessoais"),
            {
                "fields": ("data_nascimento",),
            },
        ),
        (
            _("Permissões e Acesso"),
            {
                "fields": (
                    "is_active",
                    "is_staff",
                    "is_superuser",
                    "groups",
                    "user_permissions",
                ),
            },
        ),
        (
            _("Auditoria"),
            {
                "fields": ("last_login", "data_criacao"),
            },
        ),
    )

    readonly_fields = ("data_criacao", "last_login")

    # Para criação de utilizador via formulário do Django Admin
    add_fieldsets = (
        (
            None,
            {
                "classes": ("wide",),
                "fields": (
                    "telemovel",
                    "email",
                    "nome",
                    "password1",
                    "password2",
                    "tipo_utilizador",
                    "estado",
                    "is_staff",
                    "is_superuser",
                ),
            },
        ),
    )

    def get_fieldsets(self, request, obj=None):
        if not obj:
            return self.add_fieldsets
        return super().get_fieldsets(request, obj)

    def get_form(self, request, obj=None, **kwargs):
        defaults = {}
        if obj is None:
            defaults["form"] = self.add_form
        defaults.update(kwargs)
        return super().get_form(request, obj, **defaults)

    actions = ["ativar_contas", "suspender_contas", "bloquear_contas"]

    @admin.action(description="🟢 Ativar Contas Selecionadas")
    def ativar_contas(self, request: HttpRequest, queryset):
        qtd = queryset.update(estado=CustomUser.EstadoConta.ATIVO, is_active=True)
        self.message_user(request, f"{qtd} conta(s) ativada(s) com sucesso.", level=messages.SUCCESS)

    @admin.action(description="🟡 Suspender Contas Selecionadas")
    def suspender_contas(self, request: HttpRequest, queryset):
        qtd = queryset.update(estado=CustomUser.EstadoConta.SUSPENSO, is_active=False)
        self.message_user(request, f"{qtd} conta(s) suspensa(s).", level=messages.WARNING)

    @admin.action(description="🔴 Bloquear Contas Selecionadas (Fraude / Violação)")
    def bloquear_contas(self, request: HttpRequest, queryset):
        qtd = queryset.update(estado=CustomUser.EstadoConta.BLOQUEADO, is_active=False)
        self.message_user(request, f"{qtd} conta(s) bloqueada(s) definitivamente.", level=messages.ERROR)


@admin.register(Morada)
class MoradaAdmin(MasterModelAdmin):
    """
    Gestão de moradas de clientes e endereços georreferenciados.
    """

    list_display = (
        "id",
        "utilizador",
        "texto_endereco",
        "referencia",
        "andar_porta",
    )
    list_filter = ("utilizador",)
    search_fields = (
        "texto_endereco",
        "referencia",
        "andar_porta",
        "utilizador__nome",
        "utilizador__telemovel",
        "utilizador__email",
    )
    ordering = ("utilizador",)


@admin.register(PerfilConsentimento)
class PerfilConsentimentoAdmin(MasterModelAdmin):
    """
    Auditoria e registo de consentimentos legais e RGPD dos utilizadores.
    """
    protected_from_deletion = True

    list_display = (
        "utilizador",
        "termos_utilizacao",
        "politica_privacidade",
        "marketing",
        "localizacao_segundo_plano",
        "timestamp",
    )
    list_filter = (
        "termos_utilizacao",
        "politica_privacidade",
        "marketing",
        "localizacao_segundo_plano",
    )
    search_fields = ("utilizador__nome", "utilizador__telemovel", "utilizador__email")
    readonly_fields = ("timestamp",)


@admin.register(RegistoOTP)
class RegistoOTPAdmin(MasterModelAdmin):
    """
    Registo e auditoria de códigos OTP enviados por SMS.
    """
    protected_from_deletion = True

    list_display = (
        "telemovel",
        "codigo_otp",
        "tentativas_restantes",
        "expira_em",
        "bloqueado_ate",
        "contagem_envios_hora",
    )
    list_filter = ("expira_em", "bloqueado_ate")
    search_fields = ("telemovel",)
    readonly_fields = ("expira_em",)
    ordering = ("-expira_em",)


@admin.register(RegistoOTPEmail)
class RegistoOTPEmailAdmin(MasterModelAdmin):
    """
    Registo e auditoria de códigos OTP enviados por E-mail.
    """
    protected_from_deletion = True

    list_display = (
        "email",
        "codigo_hash",
        "tentativas_restantes",
        "is_verificado",
        "expira_em",
        "criado_em",
    )
    list_filter = ("is_verificado", "expira_em", "criado_em")
    search_fields = ("email", "ip_origem")
    readonly_fields = ("criado_em", "atualizado_em")
    ordering = ("-criado_em",)
