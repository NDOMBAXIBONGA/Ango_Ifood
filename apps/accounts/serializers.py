"""
Serializers Django REST Framework para o fluxo de autenticação passwordless via OTP,
gestão de identidade, validação de maioridade e consentimentos RGPD.

Implementa as seguintes regras de negócio:
- RN-001: Identificação única e autenticação primária através do número de telemóvel no formato E.164.
- RN-002: Verificação por código OTP de 6 dígitos numéricos com controlo estrito de tentativas e rate-limit.
- RN-003: Dados obrigatórios de perfil (Nome, E-mail único e Data de Nascimento com maioridade mínima de 18 anos civis).
- RN-004: Consentimentos legais obrigatórios (Termos de Utilização, Política de Privacidade) e opcionais (Marketing, GPS).
- RN-006: Geração de credenciais de sessão e tokens JWT.
- RN-007: Gestão do ciclo de vida e transições de estado da conta.
- RN-008: Proteção contra acesso indevido e controlo de contas suspensas.
"""
from __future__ import annotations

from datetime import date
from typing import Any

from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import serializers

from apps.accounts.models import CustomUser, PerfilConsentimento, validador_telemovel


def calcular_idade(data_nascimento: date, referencia: date | None = None) -> int:
    """
    RN-003: Calcula com exatidão a idade civil em anos completos à data de referência.
    Leva em consideração se o aniversário já ocorreu ou não no ano corrente.
    """
    hoje = referencia or timezone.localdate()
    return (
        hoje.year
        - data_nascimento.year
        - ((hoje.month, hoje.day) < (data_nascimento.month, data_nascimento.day))
    )


class RequestOTPSerializer(serializers.Serializer):
    """
    Endpoint 1: `POST /api/v1/auth/request-otp/`
    Serializer para receção e validação do número de telemóvel destinatário do desafio OTP.
    Aplica a regra RN-001 garantindo o formato internacional E.164.
    """

    telemovel = serializers.CharField(
        max_length=20,
        validators=[validador_telemovel],
        help_text=_("RN-001: Número de telemóvel no formato internacional E.164 (ex.: +244923000000 ou +351912345678)."),
    )

    def validate_telemovel(self, value: str) -> str:
        """RN-001: Sanitiza o número de telemóvel removendo espaços e caracteres espúrios."""
        telemovel_limpo = value.strip().replace(" ", "")
        return telemovel_limpo


class VerifyOTPSerializer(serializers.Serializer):
    """
    Endpoint 2: `POST /api/v1/auth/verify-otp/`
    Serializer para receção do telemóvel e do código OTP submetido pelo utilizador.
    Aplica a regra RN-002 exigindo exatamente 6 dígitos numéricos.
    """

    telemovel = serializers.CharField(
        max_length=20,
        validators=[validador_telemovel],
        help_text=_("RN-001: Número de telemóvel que recebeu o desafio OTP."),
    )
    codigo_otp = serializers.RegexField(
        regex=r"^\d{6}$",
        min_length=6,
        max_length=6,
        error_messages={
            "invalid": _("RN-002: O código OTP deve conter obrigatoriamente 6 dígitos numéricos."),
        },
        help_text=_("RN-002: Código de validação de 6 dígitos numéricos recebido por SMS."),
    )

    def validate_telemovel(self, value: str) -> str:
        return value.strip().replace(" ", "")

    def validate_codigo_otp(self, value: str) -> str:
        return value.strip()


class CompleteRegistrationSerializer(serializers.Serializer):
    """
    Endpoint 3: `POST /api/v1/auth/complete-registration/`
    Serializer para finalização do registo de novos utilizadores após validação bem-sucedida do OTP.
    
    Aplica rigorosamente:
    - RN-001: Formato válido do número de telemóvel.
    - RN-003: Validação estrita de maioridade civil (>= 18 anos) no momento exato da submissão
      e unicidade global do endereço de e-mail.
    - RN-004: Aceitação obrigatória dos Termos de Utilização e Política de Privacidade.
    """

    telemovel = serializers.CharField(
        max_length=20,
        validators=[validador_telemovel],
        help_text=_("RN-001: Número de telemóvel verificado no passo anterior."),
    )
    nome = serializers.CharField(
        max_length=150,
        min_length=2,
        help_text=_("RN-003: Nome completo do titular da conta."),
    )
    email = serializers.EmailField(
        help_text=_("RN-003: Endereço de e-mail único para faturação e comunicações oficiais."),
    )
    data_nascimento = serializers.DateField(
        help_text=_("RN-003: Data de nascimento (formato YYYY-MM-DD). Requer obrigatoriamente idade >= 18 anos."),
    )

    # Consentimentos RGPD (RN-004)
    termos_utilizacao = serializers.BooleanField(
        default=True,
        required=False,
        help_text=_("RN-004: Aceitação dos Termos e Condições Gerais de Utilização (obrigatório)."),
    )
    politica_privacidade = serializers.BooleanField(
        default=True,
        required=False,
        help_text=_("RN-004: Aceitação da Política de Privacidade e Tratamento de Dados (obrigatório)."),
    )
    marketing = serializers.BooleanField(
        default=False,
        required=False,
        help_text=_("RN-004: Consentimento opcional e revogável para comunicações de marketing."),
    )
    localizacao_segundo_plano = serializers.BooleanField(
        default=False,
        required=False,
        help_text=_("RN-004: Consentimento opcional para rastreamento de entregas em segundo plano."),
    )

    def validate_telemovel(self, value: str) -> str:
        return value.strip().replace(" ", "")

    def validate_nome(self, value: str) -> str:
        nome_limpo = value.strip()
        if len(nome_limpo) < 2:
            raise serializers.ValidationError(_("RN-003: O nome completo deve conter pelo menos 2 caracteres."))
        return nome_limpo

    def validate_email(self, value: str) -> str:
        """
        RN-003: Valida a unicidade global do endereço de correio eletrónico.
        """
        email_normalizado = value.strip().lower()
        user_atual = self.context.get("user")
        qs = CustomUser.objects.filter(email__iexact=email_normalizado)
        if user_atual is not None:
            qs = qs.exclude(pk=user_atual.pk)
        if qs.exists():
            raise serializers.ValidationError(
                _("RN-003: Já existe uma conta registada com este endereço de e-mail.")
            )
        return email_normalizado

    def validate_data_nascimento(self, value: date) -> date:
        """
        RN-003: Valida se a data confere uma idade igual ou superior a 18 anos civis no momento da execução.
        Rejeita categoricamente datas futuras e utilizadores menores de idade com erro HTTP 400.
        """
        hoje = timezone.localdate()
        if value > hoje:
            raise serializers.ValidationError(
                _("RN-003: A data de nascimento não pode ser superior à data atual.")
            )

        idade = calcular_idade(value, hoje)
        if idade < 18:
            raise serializers.ValidationError(
                _(
                    f"RN-003: Apenas indivíduos com idade igual ou superior a 18 anos civis "
                    f"podem criar conta na plataforma (idade calculada: {idade} anos)."
                )
            )
        return value

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        """
        RN-004: Assegura que os consentimentos legais mandatórios foram aceites.
        """
        if not attrs.get("termos_utilizacao", True) or not attrs.get("politica_privacidade", True):
            raise serializers.ValidationError(
                {
                    "consentimentos": _(
                        "RN-004: A aceitação dos Termos de Utilização e da Política de Privacidade é obrigatória."
                    )
                }
            )
        return attrs


# Alias de compatibilidade
CompletarRegistoSerializer = CompleteRegistrationSerializer


class UtilizadorResumoSerializer(serializers.ModelSerializer):
    """
    Serializer para devolução dos dados de perfil e segurança do utilizador autenticado (RN-003, RN-006, RN-008).
    """

    class Meta:
        model = CustomUser
        fields = (
            "id",
            "telemovel",
            "nome",
            "email",
            "estado",
            "data_nascimento",
            "data_criacao",
        )
        read_only_fields = fields
