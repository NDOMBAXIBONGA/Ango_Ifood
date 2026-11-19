"""
Configuração do Django Admin para a aplicação 'accounts'.
Disponibiliza a gestão de Utilizadores (CustomUser), Moradas, Consentimentos e Sessões OTP.
"""
from django.contrib import admin, messages
from django.contrib.auth.admin import UserAdmin
from django.http import HttpRequest
from django.utils.translation import gettext_lazy as _

from core.admin_base import MasterModelAdmin
from apps.accounts.models import (
    CustomUser,
    Morada,
    PerfilConsentimento,
    RegistoOTP,
    RegistoOTPEmail,
)

# Customização da identidade visual do Django Admin
admin.site.site_header = "Delivery Pro — Administração Central"
admin.site.site_title = "Delivery Pro Admin"
admin.site.index_title = "Painel de Gestão da Plataforma"


@admin.register(CustomUser)
class CustomUserAdmin(UserAdmin):
    """
    Gestão avançada de utilizadores da plataforma (Cliente, Parceiro, Estafeta, Admin).
    """

    model = CustomUser

    list_display = (
        "telemovel",
        "nome",
        "email",
        "tipo_utilizador",
        "estado",
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
        "rotulo",
        "utilizador",
        "endereco_formatado",
        "cidade",
        "e_padrao",
        "data_criacao",
    )
    list_filter = ("cidade", "e_padrao", "data_criacao")
    search_fields = (
        "rotulo",
        "endereco_formatado",
        "utilizador__nome",
        "utilizador__telemovel",
        "utilizador__email",
    )
    ordering = ("-data_criacao",)


@admin.register(PerfilConsentimento)
class PerfilConsentimentoAdmin(MasterModelAdmin):
    """
    Auditoria e registo de consentimentos legais e RGPD dos utilizadores.
    """
    protected_from_deletion = True

    list_display = (
        "utilizador",
        "termos_servico",
        "politica_privacidade",
        "marketing",
        "localizacao_segundo_plano",
        "data_atualizacao",
    )
    list_filter = (
        "termos_servico",
        "politica_privacidade",
        "marketing",
        "localizacao_segundo_plano",
    )
    search_fields = ("utilizador__nome", "utilizador__telemovel", "utilizador__email")
    readonly_fields = ("data_atualizacao",)


@admin.register(RegistoOTP)
class RegistoOTPAdmin(MasterModelAdmin):
    """
    Registo e auditoria de códigos OTP enviados por SMS.
    """
    protected_from_deletion = True

    list_display = (
        "telemovel",
        "codigo_hash",
        "tentativas",
        "utilizado",
        "expira_em",
        "data_criacao",
    )
    list_filter = ("utilizado", "expira_em", "data_criacao")
    search_fields = ("telemovel",)
    readonly_fields = ("data_criacao",)
    ordering = ("-data_criacao",)


@admin.register(RegistoOTPEmail)
class RegistoOTPEmailAdmin(MasterModelAdmin):
    """
    Registo e auditoria de códigos OTP enviados por E-mail.
    """
    protected_from_deletion = True

    list_display = (
        "email",
        "codigo_hash",
        "tentativas",
        "utilizado",
        "expira_em",
        "data_criacao",
    )
    list_filter = ("utilizado", "expira_em", "data_criacao")
    search_fields = ("email",)
    readonly_fields = ("data_criacao",)
    ordering = ("-data_criacao",)
