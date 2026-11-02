"""
Views Django REST Framework e SimpleJWT para o fluxo de autenticação passwordless por código único (OTP).
Implementa os endpoints REST de segurança e ciclo de vida de utilizador (RN-001 a RN-008).

Endpoints:
1. POST `/api/v1/auth/request-otp/` (RN-001, RN-002, RN-008)
2. POST `/api/v1/auth/verify-otp/` (RN-001, RN-002, RN-006, RN-008)
3. POST `/api/v1/auth/complete-registration/` (RN-001, RN-003, RN-004, RN-006, RN-007)
"""
from __future__ import annotations

import logging
import secrets
from datetime import timedelta
from typing import Any

from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import permissions, status
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.brevo_service import BrevoEmailService
from apps.accounts.models import CustomUser, PerfilConsentimento, RegistoOTP
from apps.accounts.serializers import (
    CompleteRegistrationSerializer,
    RequestOTPSerializer,
    UtilizadorResumoSerializer,
    VerifyOTPSerializer,
)

logger = logging.getLogger(__name__)

# Parâmetros operacionais e SLAs da regra RN-002 (Secções 6.1 e 8)
OTP_EXPIRACAO_MINUTOS = 5
OTP_MAX_TENTATIVAS = 5
OTP_MAX_ENVIOS_HORA = 3
OTP_DURACAO_BLOQUEIO_MINUTOS = 15


def gerar_tokens_jwt_para_utilizador(user: CustomUser) -> dict[str, str]:
    """
    RN-006: Gera o par de tokens JWT (Refresh e Access) via SimpleJWT,
    injetando claims adicionais para controlo de sessão e identificação rápida.
    """
    refresh = RefreshToken.for_user(user)
    refresh["telemovel"] = user.telemovel
    refresh["estado"] = user.estado
    refresh["nome"] = user.nome
    return {
        "access": str(refresh.access_token),
        "refresh": str(refresh),
    }


class RequestOTPView(APIView):
    """
    Endpoint 1: `POST /api/v1/auth/request-otp/`
    Recebe 'telemovel', valida o formato internacional E.164 (RN-001).
    Aplica rate-limiting de 3 envios por hora (RN-002), verifica suspensão de conta (RN-008),
    gera um OTP criptográfico de 6 dígitos com TTL de 5 minutos e simula o envio no log.
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []

    @transaction.atomic
    def post(self, request: Request) -> Response:
        serializer = RequestOTPSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        telemovel: str = serializer.validated_data["telemovel"]

        agora = timezone.now()

        # RN-008: Verifica se a conta associada a este número está com o estado 'SUSPENSO'
        utilizador_existente = CustomUser.objects.filter(telemovel=telemovel).first()
        if (
            utilizador_existente is not None
            and utilizador_existente.estado == CustomUser.EstadoConta.SUSPENSO
        ):
            logger.warning(
                "RN-008: Tentativa de envio de OTP rejeitada para conta suspensa: %s",
                telemovel,
            )
            return Response(
                {
                    "erro": "conta_suspensa",
                    "detalhe": _(
                        "RN-008: A conta associada a este número de telemóvel encontra-se suspensa "
                        "por motivos de segurança. Contacte a equipa de suporte."
                    ),
                },
                status=status.HTTP_403_FORBIDDEN,
            )

        # Recupera o registo OTP atual com lock transacional
        registo_existente = (
            RegistoOTP.objects.select_for_update()
            .filter(telemovel=telemovel)
            .first()
        )

        nova_contagem_envios = 1

        if registo_existente is not None:
            # Verifica se o telemóvel está sob bloqueio ativo de tentativas
            if registo_existente.bloqueado_ate and agora < registo_existente.bloqueado_ate:
                segundos_restantes = int((registo_existente.bloqueado_ate - agora).total_seconds())
                logger.warning(
                    "RN-002: Pedido de OTP bloqueado para %s até %s.",
                    telemovel,
                    registo_existente.bloqueado_ate.isoformat(),
                )
                return Response(
                    {
                        "erro": "telemovel_bloqueado",
                        "detalhe": _(
                            "RN-002: O número de telemóvel encontra-se temporariamente bloqueado "
                            "devido a excesso de tentativas incorretas."
                        ),
                        "bloqueado_ate": registo_existente.bloqueado_ate.isoformat(),
                        "retry_after_seconds": segundos_restantes,
                    },
                    status=status.HTTP_429_TOO_MANY_REQUESTS,
                )

            # RN-002: Verifica a janela de 1 hora para o limite de 3 envios
            # O momento do envio original é estimado subtraindo o TTL de 5 min da expiração
            momento_ultimo_envio = registo_existente.expira_em - timedelta(minutes=OTP_EXPIRACAO_MINUTOS)
            if agora - momento_ultimo_envio < timedelta(hours=1):
                if registo_existente.contagem_envios_hora >= OTP_MAX_ENVIOS_HORA:
                    logger.warning(
                        "RN-002: Limite de %d envios por hora atingido para %s.",
                        OTP_MAX_ENVIOS_HORA,
                        telemovel,
                    )
                    return Response(
                        {
                            "erro": "limite_envios_excedido",
                            "detalhe": _(
                                f"RN-002: O número de telemóvel já atingiu o limite máximo de {OTP_MAX_ENVIOS_HORA} "
                                "envios de código OTP na última hora. Por favor, tente novamente mais tarde."
                            ),
                        },
                        status=status.HTTP_429_TOO_MANY_REQUESTS,
                    )
                nova_contagem_envios = registo_existente.contagem_envios_hora + 1
            else:
                nova_contagem_envios = 1

        # Gera código numérico de 6 dígitos criptograficamente seguro (000000 a 999999)
        codigo_seguro = f"{secrets.randbelow(1_000_000):06d}"
        expira_em = agora + timedelta(minutes=OTP_EXPIRACAO_MINUTOS)

        # Grava ou atualiza o registo no modelo 'RegistoOTP' reiniciando tentativas para 5
        registo_otp, _ = RegistoOTP.objects.update_or_create(
            telemovel=telemovel,
            defaults={
                "codigo_otp": codigo_seguro,
                "tentativas_restantes": OTP_MAX_TENTATIVAS,
                "expira_em": expira_em,
                "bloqueado_ate": None,
                "contagem_envios_hora": nova_contagem_envios,
            },
        )

        # Despacho do e-mail transacional via Brevo se um e-mail foi fornecido ou inferido
        email_destino = serializer.validated_data.get("email") or (telemovel if "@" in telemovel else None)
        if email_destino:
            brevo_service = BrevoEmailService()
            sucesso_brevo = brevo_service.enviar_email_otp(
                email_destino=email_destino,
                codigo_otp=codigo_seguro,
            )
            if sucesso_brevo:
                logger.info("Código OTP enviado com sucesso via Brevo para o e-mail: %s", email_destino)
            else:
                logger.warning("Falha ao entregar código OTP via Brevo para o e-mail: %s", email_destino)

        # Registo em log do envio do desafio OTP
        mensagem_log = (
            f"[CANAL AUTH] RN-002 | Destino: {telemovel} (E-mail: {email_destino or 'N/A'}) | "
            f"Código OTP: {codigo_seguro} | Expira em: {expira_em.isoformat()} ({OTP_EXPIRACAO_MINUTOS} min) | "
            f"Tentativas: {OTP_MAX_TENTATIVAS} | Envios na hora: {nova_contagem_envios}/{OTP_MAX_ENVIOS_HORA}"
        )
        logger.info(mensagem_log)
        print(mensagem_log)

        return Response(
            {
                "mensagem": _("RN-002: Código de verificação OTP gerado e enviado com sucesso."),
                "telemovel": telemovel,
                "expira_em": registo_otp.expira_em.isoformat(),
                "validade_minutos": OTP_EXPIRACAO_MINUTOS,
                "tentativas_permitidas": OTP_MAX_TENTATIVAS,
                "envios_restantes_na_hora": max(0, OTP_MAX_ENVIOS_HORA - nova_contagem_envios),
            },
            status=status.HTTP_200_OK,
        )


class VerifyOTPView(APIView):
    """
    Endpoint 2: `POST /api/v1/auth/verify-otp/`
    Recebe 'telemovel' e 'codigo_otp'.
    Valida as seguintes falhas com HTTP 400 Bad Request:
    - Se 'bloqueado_ate' for maior que a hora atual (bloqueio por tentativas excedidas).
    - Se a hora atual for maior que o campo 'expira_em' (código expirou após 5 minutos).
    - Se o código introduzido estiver incorreto (decrementa tentativas; a 0 bloqueia por 15 min per RN-002).
    
    Se válido:
    - Se a conta já existir: emite tokens JWT (SimpleJWT) e retorna HTTP 200 OK com o perfil (RN-006).
    - Se a conta não existir: devolve flag transacional 'registo_pendente=True' para redirecionar à finalização.
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []

    @transaction.atomic
    def post(self, request: Request) -> Response:
        serializer = VerifyOTPSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        telemovel: str = serializer.validated_data["telemovel"]
        codigo_submetido: str = serializer.validated_data["codigo_otp"]
        agora = timezone.now()

        # Recupera o registo ativo no modelo 'RegistoOTP' com bloqueio de concorrência
        registo_otp = (
            RegistoOTP.objects.select_for_update()
            .filter(telemovel=telemovel)
            .first()
        )

        if registo_otp is None:
            return Response(
                {
                    "erro": "otp_inexistente",
                    "detalhe": _("RN-002: Nenhum código OTP foi solicitado para este número de telemóvel."),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # 1. Validação: Bloqueado_ate > hora atual
        if registo_otp.bloqueado_ate and registo_otp.bloqueado_ate > agora:
            segundos_espera = int((registo_otp.bloqueado_ate - agora).total_seconds())
            logger.warning(
                "RN-002: Verificação recusada para %s — sob bloqueio até %s.",
                telemovel,
                registo_otp.bloqueado_ate.isoformat(),
            )
            return Response(
                {
                    "erro": "telemovel_bloqueado",
                    "detalhe": _(
                        "RN-002: O número de telemóvel encontra-se temporariamente bloqueado "
                        "por tentativas excessivas. Aguarde que o período de penalização expire."
                    ),
                    "bloqueado_ate": registo_otp.bloqueado_ate.isoformat(),
                    "segundos_restantes": segundos_espera,
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # 2. Validação: Hora atual > expira_em (expirou após 5 minutos)
        if agora > registo_otp.expira_em:
            logger.info("RN-002: Código OTP para %s expirou às %s.", telemovel, registo_otp.expira_em.isoformat())
            return Response(
                {
                    "erro": "otp_expirado",
                    "detalhe": _(
                        "RN-002: O código OTP expirou após 5 minutos de validade. "
                        "Solicite um novo código de verificação."
                    ),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # 3. Validação: Código incorreto e gestão do contador decrescente
        codigo_valido = secrets.compare_digest(registo_otp.codigo_otp, codigo_submetido)

        if not codigo_valido:
            # Decrementa o campo 'tentativas_restantes'
            registo_otp.tentativas_restantes = max(0, registo_otp.tentativas_restantes - 1)

            if registo_otp.tentativas_restantes == 0:
                # Atingiu 0 tentativas: define 'bloqueado_ate' para os próximos 15 minutos (RN-002)
                bloqueio_15m = agora + timedelta(minutes=OTP_DURACAO_BLOQUEIO_MINUTOS)
                registo_otp.bloqueado_ate = bloqueio_15m
                registo_otp.save(update_fields=["tentativas_restantes", "bloqueado_ate"])

                logger.warning(
                    "RN-002: 5 tentativas de OTP esgotadas para %s. Bloqueado por 15 minutos até %s.",
                    telemovel,
                    bloqueio_15m.isoformat(),
                )
                return Response(
                    {
                        "erro": "tentativas_esgotadas",
                        "detalhe": _(
                            f"RN-002: Código OTP incorreto. O limite de tentativas foi esgotado. "
                            f"O número foi bloqueado por {OTP_DURACAO_BLOQUEIO_MINUTOS} minutos."
                        ),
                        "tentativas_restantes": 0,
                        "bloqueado_ate": bloqueio_15m.isoformat(),
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )

            registo_otp.save(update_fields=["tentativas_restantes"])
            return Response(
                {
                    "erro": "codigo_incorreto",
                    "detalhe": _("RN-002: Código OTP incorreto."),
                    "tentativas_restantes": registo_otp.tentativas_restantes,
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Código idêntico e válido: neutraliza o OTP para evitar repetição (replay attack)
        registo_otp.expira_em = agora
        registo_otp.tentativas_restantes = 0
        registo_otp.save(update_fields=["expira_em", "tentativas_restantes"])

        # Verifica se o utilizador já possui conta criada com este telemóvel
        utilizador = CustomUser.objects.filter(telemovel=telemovel).first()

        if utilizador is not None:
            # RN-008: Bloqueio estrito de acesso para conta suspensa
            if utilizador.estado == CustomUser.EstadoConta.SUSPENSO:
                return Response(
                    {
                        "erro": "conta_suspensa",
                        "detalhe": _("RN-008: Esta conta encontra-se suspensa. Contacte a equipa de suporte."),
                    },
                    status=status.HTTP_403_FORBIDDEN,
                )

            # Caso a conta já exista: gera e devolve os tokens JWT de Acesso e Refresh (RN-006)
            tokens = gerar_tokens_jwt_para_utilizador(utilizador)
            return Response(
                {
                    "mensagem": _("RN-006: Autenticação passwordless realizada com sucesso."),
                    "registo_pendente": False,
                    "tokens": tokens,
                    "perfil": UtilizadorResumoSerializer(utilizador).data,
                },
                status=status.HTTP_200_OK,
            )
        else:
            # Caso a conta não exista: cria temporariamente flag transacional no payload de resposta
            # indicando que o número foi validado mas necessita de finalizar registo de dados básicos
            return Response(
                {
                    "mensagem": _(
                        "RN-002: Número de telemóvel verificado com sucesso. "
                        "Redirecione para o formulário de finalização de registo de dados básicos."
                    ),
                    "registo_pendente": True,
                    "requires_registration_completion": True,
                    "telemovel": telemovel,
                    "campos_obrigatorios": ["nome", "email", "data_nascimento"],
                },
                status=status.HTTP_200_OK,
            )


class CompleteRegistrationView(APIView):
    """
    Endpoint 3: `POST /api/v1/auth/complete-registration/`
    Recebe 'telemovel', 'nome', 'email' e 'data_nascimento'.
    Valida obrigatoriamente se a 'data_nascimento' confere uma idade igual ou superior
    a 18 anos civis no momento da execução (RN-003). Caso seja menor, rejeita com HTTP 400 Bad Request.
    Cria o utilizador na tabela CustomUser, ativa os perfis de consentimento padrão (RN-004)
    e emite os tokens JWT finais (RN-006).
    """

    permission_classes = [permissions.AllowAny]

    @transaction.atomic
    def post(self, request: Request) -> Response:
        serializer = CompleteRegistrationSerializer(
            data=request.data,
            context={"request": request},
        )
        serializer.is_valid(raise_exception=True)

        telemovel: str = serializer.validated_data["telemovel"]
        nome: str = serializer.validated_data["nome"]
        email: str = serializer.validated_data["email"]
        data_nascimento = serializer.validated_data["data_nascimento"]

        # Verifica se já existe um utilizador registado com este telemóvel
        utilizador_existente = CustomUser.objects.filter(telemovel=telemovel).first()
        if utilizador_existente is not None:
            if utilizador_existente.estado == CustomUser.EstadoConta.SUSPENSO:
                return Response(
                    {
                        "erro": "conta_suspensa",
                        "detalhe": _("RN-008: Conta associada suspensa por motivos de segurança."),
                    },
                    status=status.HTTP_403_FORBIDDEN,
                )

            # Se for um utilizador pendente, atualiza o registo existente
            if utilizador_existente.estado == CustomUser.EstadoConta.PENDENTE:
                utilizador_existente.nome = nome
                utilizador_existente.email = email
                utilizador_existente.data_nascimento = data_nascimento
                utilizador_existente.estado = CustomUser.EstadoConta.ATIVO
                utilizador_existente.is_active = True
                utilizador_existente.save(
                    update_fields=["nome", "email", "data_nascimento", "estado", "is_active"]
                )
                user = utilizador_existente
            else:
                return Response(
                    {
                        "erro": "telemovel_ja_registado",
                        "detalhe": _("RN-001: Já existe uma conta ativa para este número de telemóvel. Efetue o login com OTP."),
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )
        else:
            # Cria o utilizador na tabela CustomUser com estado ATIVO
            user = CustomUser.objects.create_user(
                telemovel=telemovel,
                nome=nome,
                email=email,
                data_nascimento=data_nascimento,
                estado=CustomUser.EstadoConta.ATIVO,
                is_active=True,
            )

        # Ativa os perfis de consentimento padrão (RN-004)
        termos_utilizacao = serializer.validated_data.get("termos_utilizacao", True)
        politica_privacidade = serializer.validated_data.get("politica_privacidade", True)
        marketing = serializer.validated_data.get("marketing", False)
        localizacao_segundo_plano = serializer.validated_data.get("localizacao_segundo_plano", False)

        PerfilConsentimento.objects.update_or_create(
            utilizador=user,
            defaults={
                "termos_utilizacao": termos_utilizacao,
                "politica_privacidade": politica_privacidade,
                "marketing": marketing,
                "localizacao_segundo_plano": localizacao_segundo_plano,
            },
        )

        logger.info(
            "RN-003 / RN-004: Utilizador criado e ativado com sucesso: %s (id=%s, idade=%d anos).",
            user.telemovel,
            user.id,
            user.data_nascimento and (timezone.localdate().year - user.data_nascimento.year) or 0,
        )

        # Emite os tokens JWT finais (RN-006)
        tokens = gerar_tokens_jwt_para_utilizador(user)

        return Response(
            {
                "mensagem": _("RN-003 / RN-004: Registo concluído com sucesso e conta ativada."),
                "registo_pendente": False,
                "tokens": tokens,
                "perfil": UtilizadorResumoSerializer(user).data,
            },
            status=status.HTTP_201_CREATED,
        )
