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
import threading
from datetime import timedelta
from typing import Any

from django.conf import settings
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import permissions, serializers, status, viewsets
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView
from rest_framework_simplejwt.tokens import RefreshToken

from apps.accounts.brevo_service import BrevoEmailService
from apps.accounts.models import (
    CustomUser,
    Morada,
    PerfilConsentimento,
    RegistoOTP,
    RegistoOTPEmail,
)
from apps.accounts.serializers import (
    CompleteRegistrationSerializer,
    EmailOTPRequestSerializer,
    EmailOTPVerifySerializer,
    EmailPasswordLoginSerializer,
    EmailRegisterSerializer,
    MoradaSerializer,
    RequestOTPSerializer,
    UtilizadorResumoSerializer,
    VerifyOTPSerializer,
)

logger = logging.getLogger(__name__)


import ipaddress


def obter_ip_cliente(request: Request) -> str | None:
    """Extrai o endereço IP real do cliente, considerando cabeçalhos de proxies reversos e sanitizando o valor."""
    ip_raw = None
    x_forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR")
    if x_forwarded_for:
        ip_raw = x_forwarded_for.split(",")[0].strip()
    else:
        ip_raw = request.META.get("REMOTE_ADDR", "").strip()

    if not ip_raw:
        return None

    # Remove porta caso venha agregada em cabeçalhos (ex.: '192.168.1.1:54321')
    if ":" in ip_raw and "." in ip_raw:
        ip_raw = ip_raw.split(":")[0].strip()

    try:
        ipaddress.ip_address(ip_raw)
        return ip_raw
    except ValueError:
        return None

# Parâmetros operacionais e SLAs da regra RN-002 (Secções 6.1 e 8)
OTP_EXPIRACAO_MINUTOS = 5
OTP_MAX_TENTATIVAS = 5
OTP_MAX_ENVIOS_HORA = 3
OTP_DURACAO_BLOQUEIO_MINUTOS = 15


def gerar_tokens_jwt_para_utilizador(user: CustomUser) -> dict[str, str]:
    """
    RN-006: Gera o par de tokens JWT (Refresh e Access) via SimpleJWT,
    injetando claims adicionais para controlo de sessão e identificação rápida.
    Garante resiliência automática se as tabelas de token_blacklist ainda não estiverem migradas.
    """
    try:
        refresh = RefreshToken.for_user(user)
    except Exception as e:
        err_msg = str(e).lower()
        if "token_blacklist" in err_msg or "does not exist" in err_msg or "relation" in err_msg:
            try:
                from django.core.management import call_command
                call_command("migrate", "token_blacklist", interactive=False)
                refresh = RefreshToken.for_user(user)
            except Exception:
                # Fallback gerando token Refresh diretamente sem persistência imediata em blacklist
                refresh = RefreshToken()
                refresh[refresh.user_id_field] = str(user.pk)
        else:
            raise

    refresh["telemovel"] = user.telemovel or ""
    refresh["email"] = user.email or ""
    refresh["estado"] = user.estado
    refresh["nome"] = user.nome
    refresh["tipo_utilizador"] = getattr(user, "tipo_utilizador", CustomUser.TipoUtilizador.CLIENTE)
    refresh["role"] = getattr(user, "tipo_utilizador", CustomUser.TipoUtilizador.CLIENTE).lower()
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
    throttle_classes = []

    @transaction.atomic
    def post(self, request: Request) -> Response:
        # Delegação transparente para EmailRequestOTPView caso o payload contenha e-mail
        email_param = request.data.get("email") or request.data.get("telemovel")
        if email_param and "@" in str(email_param):
            return EmailRequestOTPView().post(request)

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

        # Despacho assíncrono do e-mail transacional via Brevo se um e-mail foi fornecido ou inferido
        email_destino = serializer.validated_data.get("email") or (telemovel if "@" in telemovel else None)
        if email_destino:
            threading.Thread(
                target=BrevoEmailService().enviar_email_otp,
                args=(email_destino, codigo_seguro),
                daemon=True,
            ).start()
            logger.info("Disparo assíncrono de OTP via Brevo iniciado para: %s", email_destino)

        # Registo em log do envio do desafio OTP
        mensagem_log = (
            f"[CANAL AUTH] RN-002 | Destino: {telemovel} (E-mail: {email_destino or 'N/A'}) | "
            f"Código OTP: {codigo_seguro} | Expira em: {expira_em.isoformat()} ({OTP_EXPIRACAO_MINUTOS} min) | "
            f"Tentativas: {OTP_MAX_TENTATIVAS} | Envios na hora: {nova_contagem_envios}/{OTP_MAX_ENVIOS_HORA}"
        )
        logger.info(mensagem_log)
        print(mensagem_log)

        resp_payload = {
            "mensagem": _("RN-002: Código de verificação OTP gerado e enviado com sucesso."),
            "telemovel": telemovel,
            "expira_em": registo_otp.expira_em.isoformat(),
            "validade_minutos": OTP_EXPIRACAO_MINUTOS,
            "tentativas_permitidas": OTP_MAX_TENTATIVAS,
            "envios_restantes_na_hora": max(0, OTP_MAX_ENVIOS_HORA - nova_contagem_envios),
        }
        if getattr(settings, "EXPOSE_OTP_HINT", True):
            resp_payload["otp_hint"] = codigo_seguro

        return Response(
            resp_payload,
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
    throttle_classes = []

    @transaction.atomic
    def post(self, request: Request) -> Response:
        # Delegação transparente para EmailVerifyOTPView caso o payload contenha e-mail
        email_param = request.data.get("email") or request.data.get("telemovel")
        if email_param and "@" in str(email_param):
            return EmailVerifyOTPView().post(request)

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
    Recebe 'telemovel' (opcional se registo por e-mail), 'nome', 'email' e 'data_nascimento'.
    Valida obrigatoriamente se a 'data_nascimento' confere uma idade igual ou superior
    a 18 anos civis no momento da execução (RN-003). Caso seja menor, rejeita com HTTP 400 Bad Request.
    Cria ou ativa o utilizador na tabela CustomUser, ativa os perfis de consentimento padrão (RN-004)
    e emite os tokens JWT finais (RN-006).
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []
    throttle_classes = []

    @transaction.atomic
    def post(self, request: Request) -> Response:
        try:
            serializer = CompleteRegistrationSerializer(
                data=request.data,
                context={"request": request},
            )
            serializer.is_valid(raise_exception=True)

            telemovel: str | None = serializer.validated_data.get("telemovel")
            nome: str = serializer.validated_data["nome"]
            email: str = serializer.validated_data["email"]
            data_nascimento = serializer.validated_data["data_nascimento"]
            password: str | None = serializer.validated_data.get("password") or None

            # Se telemovel tiver formato de email ou for vazio, normaliza para None
            if telemovel and "@" in str(telemovel):
                telemovel = None

            # Procura se já existe um utilizador por telemóvel (se fornecido) ou por e-mail
            utilizador_existente = None
            if telemovel:
                utilizador_existente = CustomUser.objects.filter(telemovel=telemovel).first()
            if utilizador_existente is None:
                utilizador_existente = CustomUser.objects.filter(email__iexact=email).first()

            if utilizador_existente is not None:
                if utilizador_existente.estado == CustomUser.EstadoConta.SUSPENSO:
                    return Response(
                        {
                            "erro": "conta_suspensa",
                            "detalhe": _("RN-008: Conta associada suspensa por motivos de segurança."),
                        },
                        status=status.HTTP_403_FORBIDDEN,
                    )

                tipo_solicitado = serializer.validated_data.get(
                    "tipo_utilizador", CustomUser.TipoUtilizador.CLIENTE
                )

                # Se for um utilizador pendente, atualiza o registo existente
                if utilizador_existente.estado == CustomUser.EstadoConta.PENDENTE:
                    utilizador_existente.nome = nome
                    utilizador_existente.email = email
                    if telemovel:
                        utilizador_existente.telemovel = telemovel
                    utilizador_existente.data_nascimento = data_nascimento
                    utilizador_existente.estado = CustomUser.EstadoConta.ATIVO
                    utilizador_existente.tipo_utilizador = tipo_solicitado
                    utilizador_existente.is_active = True
                    campos_update = ["nome", "email", "data_nascimento", "estado", "tipo_utilizador", "is_active"]
                    if telemovel:
                        campos_update.append("telemovel")
                    if password:
                        utilizador_existente.set_password(password)
                        campos_update.append("password")
                    utilizador_existente.save(update_fields=campos_update)
                    user = utilizador_existente
                else:
                    return Response(
                        {
                            "erro": "conta_ja_registada",
                            "detalhe": _("RN-001 / RN-003: Já existe uma conta ativa para estes dados. Efetue o login com a sua palavra-passe ou código OTP."),
                        },
                        status=status.HTTP_400_BAD_REQUEST,
                    )
            else:
                tipo_solicitado = serializer.validated_data.get(
                    "tipo_utilizador", CustomUser.TipoUtilizador.CLIENTE
                )
                # Cria o utilizador na tabela CustomUser com estado ATIVO
                user = CustomUser.objects.create_user(
                    telemovel=telemovel,
                    nome=nome,
                    email=email,
                    password=password,
                    data_nascimento=data_nascimento,
                    tipo_utilizador=tipo_solicitado,
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

            # Invalida os registos OTP para este e-mail após a criação bem-sucedida
            RegistoOTPEmail.objects.filter(email__iexact=email).delete()

            logger.info(
                "RN-003 / RN-004: Utilizador criado e ativado com sucesso: %s (id=%s, idade=%d anos).",
                user.email or user.telemovel,
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
        except serializers.ValidationError:
            raise
        except Exception as e:
            logger.error("Erro ao completar registo: %s", e, exc_info=True)
            return Response(
                {
                    "erro": "erro_interno",
                    "detalhe": f"Falha ao completar registo: {str(e)}",
                },
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )


# ==============================================================================
# FLUXO DEDICADO DE AUTENTICAÇÃO POR E-MAIL E OTP (Brevo Transactional API)
# ==============================================================================

class EmailRequestOTPView(APIView):
    """
    Endpoint 1: `POST /api/v1/auth/email/request/`
    - Recebe 'email' no payload. Valida o formato.
    - Aplica Rate Limiting: Máximo de 3 pedidos de e-mail por hora para o mesmo IP ou e-mail.
    - Gera um número aleatório e criptograficamente seguro de 6 dígitos.
    - Grava no modelo `RegistoOTPEmail`: email, codigo_hash, tentativas_restantes (5),
      expira_em (agora + 5 minutos) e is_verificado (False).
    - Invoca de forma assíncrona o `BrevoEmailService.enviar_email_otp` para despachar o e-mail em background.
    - Retorna HTTP 200 OK.
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []
    throttle_classes = []

    def post(self, request: Request) -> Response:
        try:
            serializer = EmailOTPRequestSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            email: str = serializer.validated_data["email"]

            agora = timezone.now()
            uma_hora_atras = agora - timedelta(hours=1)
            ip_cliente = obter_ip_cliente(request)
            # Rate Limiting: Máximo de 3 pedidos de e-mail por hora para o mesmo e-mail ou mesmo IP
            pedidos_email_hora = RegistoOTPEmail.objects.filter(
                email=email,
                criado_em__gte=uma_hora_atras,
            ).count()

            pedidos_ip_hora = 0
            if ip_cliente:
                pedidos_ip_hora = RegistoOTPEmail.objects.filter(
                    ip_origem=ip_cliente,
                    criado_em__gte=uma_hora_atras,
                ).count()

            # Rate Limiting (RN-002): Máximo de 3 pedidos por hora por e-mail.
            # Para IP, tolerância ampliada (25/h) para acomodar CGNAT de operadoras móveis (Unitel/Africell).
            limite_ip = 25
            is_dev = getattr(settings, "DEBUG", False) or getattr(settings, "EXPOSE_OTP_HINT", False)
            if pedidos_email_hora >= 3 or (pedidos_ip_hora >= limite_ip and not is_dev):
                logger.warning(
                    "Rate limit de OTP por e-mail excedido: e-mail=%s (pedidos=%d), IP=%s (pedidos=%d)",
                    email,
                    pedidos_email_hora,
                    ip_cliente,
                    pedidos_ip_hora,
                )
                return Response(
                    {
                        "erro": "rate_limit_excedido",
                        "detalhe": _("Limite máximo de 3 pedidos de código por hora atingido para este e-mail. Por favor, tente mais tarde."),
                    },
                    status=status.HTTP_429_TOO_MANY_REQUESTS,
                )

            # Gera código numérico seguro de 6 dígitos (000000 a 999999)
            codigo_seguro = f"{secrets.randbelow(1_000_000):06d}"
            expira_em = agora + timedelta(minutes=5)

            # Cria ou substitui registo pendente no modelo RegistoOTPEmail
            registo = RegistoOTPEmail(
                email=email,
                tentativas_restantes=5,
                expira_em=expira_em,
                is_verificado=False,
                ip_origem=ip_cliente or None,
                contagem_pedidos_hora=pedidos_email_hora + 1,
            )
            registo.set_codigo(codigo_seguro)
            registo.save()

            # Invoca assincronamente o serviço BrevoEmailService para envio imediato em background
            threading.Thread(
                target=BrevoEmailService().enviar_email_otp,
                args=(email, codigo_seguro),
                daemon=True,
            ).start()

            logger.info(
                "OTP por e-mail gerado para %s | IP=%s | Expira em %s",
                email,
                ip_cliente,
                expira_em.isoformat(),
            )

            resp_data = {
                "sucesso": True,
                "mensagem": _("Código de confirmação enviado para o seu e-mail com sucesso."),
                "email": email,
                "expira_em": expira_em.isoformat(),
                "validade_minutos": 5,
            }
            if getattr(settings, "EXPOSE_OTP_HINT", True):
                resp_data["otp_hint"] = codigo_seguro

            return Response(resp_data, status=status.HTTP_200_OK)
        except Exception as e:
            logger.error("Erro interno no processamento de pedido de OTP por e-mail: %s", e, exc_info=True)
            # Auto-recuperação resiliente caso a tabela da base de dados ainda não tenha sido migrada
            err_msg = str(e).lower()
            if "does not exist" in err_msg or "relation" in err_msg or "table" in err_msg:
                try:
                    logger.info("A aplicar migrações pendentes de autenticação automaticamente...")
                    from django.core.management import call_command
                    for app_target in ["contenttypes", "auth", "accounts", "sessions"]:
                        try:
                            call_command("migrate", app_target, interactive=False)
                        except Exception:
                            pass

                    # Executa a criação do OTP após migração bem-sucedida
                    codigo_seguro = f"{secrets.randbelow(1_000_000):06d}"
                    expira_em = timezone.now() + timedelta(minutes=5)
                    registo = RegistoOTPEmail(
                        email=email,
                        tentativas_restantes=5,
                        expira_em=expira_em,
                        is_verificado=False,
                        ip_origem=ip_cliente or None,
                        contagem_pedidos_hora=1,
                    )
                    registo.set_codigo(codigo_seguro)
                    registo.save()

                    threading.Thread(
                        target=BrevoEmailService().enviar_email_otp,
                        args=(email, codigo_seguro),
                        daemon=True,
                    ).start()

                    return Response(
                        {
                            "sucesso": True,
                            "mensagem": _("Código de confirmação enviado para o seu e-mail com sucesso."),
                            "email": email,
                            "expira_em": expira_em.isoformat(),
                            "validade_minutos": 5,
                        },
                        status=status.HTTP_200_OK,
                    )
                except Exception as retry_err:
                    logger.critical("Falha na auto-migração e reprocessamento: %s", retry_err, exc_info=True)

            return Response(
                {
                    "erro": "erro_interno",
                    "detalhe": _("Não foi possível gerar o código neste momento. Tente novamente."),
                    "debug_erro": f"{type(e).__name__}: {str(e)}",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )


class EmailVerifyOTPView(APIView):
    """
    Endpoint 2: `POST /api/v1/auth/email/verify/`
    - Recebe 'email' e 'codigo_otp' no payload.
    - Busca o registo ativo mais recente na base de dados.
    - Valida se o código está correto, se não ultrapassou as 5 tentativas falhadas e se não expirou (5 min).
    - Se falhar: decrementa as tentativas e lança HTTP 400 Bad Request.
    - Se validado com sucesso: altera flag para `is_verificado=True` e retorna HTTP 200 OK.
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []
    throttle_classes = []

    def post(self, request: Request) -> Response:
        serializer = EmailOTPVerifySerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        email: str = serializer.validated_data["email"]
        codigo_otp: str = serializer.validated_data["codigo_otp"]

        registo = (
            RegistoOTPEmail.objects.filter(email=email)
            .order_by("-criado_em")
            .first()
        )

        if not registo:
            return Response(
                {
                    "erro": "registo_nao_encontrado",
                    "detalhe": _("Nenhum código de confirmação foi solicitado para este e-mail. Solicite um novo código."),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        if registo.esta_expirado:
            return Response(
                {
                    "erro": "codigo_expirado",
                    "detalhe": _("O código de confirmação expirou (validade de 5 minutos). Solicite um novo código."),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        if registo.tentativas_restantes <= 0:
            return Response(
                {
                    "erro": "tentativas_esgotadas",
                    "detalhe": _("Número máximo de 5 tentativas excedido. Solicite um novo código de confirmação."),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        if not registo.check_codigo(codigo_otp):
            tentativas = registo.decrementar_tentativa()
            return Response(
                {
                    "erro": "codigo_invalido",
                    "detalhe": _(f"Código incorreto. Restam {tentativas} tentativa(s)."),
                    "tentativas_restantes": tentativas,
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Sucesso na validação do código
        registo.is_verificado = True
        registo.save(update_fields=["is_verificado", "atualizado_em"])

        logger.info("E-mail verificado com sucesso via OTP: %s", email)

        return Response(
            {
                "sucesso": True,
                "mensagem": _("E-mail verificado com sucesso."),
                "email": email,
                "is_verificado": True,
            },
            status=status.HTTP_200_OK,
        )


class EmailRegisterView(APIView):
    """
    Endpoint 3: `POST /api/v1/auth/email/register/`
    - Recebe 'email', 'nome', 'data_nascimento' e 'password'.
    - Valida estritamente se o registo de e-mail associado possui a flag `is_verificado == True` na base de dados.
      Se não estiver verificado, bloqueia imediatamente o registo com HTTP 403 Forbidden.
    - Valida se o utilizador é maior de 18 anos.
    - Se passar nas validações, cria a conta na tabela CustomUser e emite os tokens JWT finais da sessão.
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []
    throttle_classes = []

    @transaction.atomic
    def post(self, request: Request) -> Response:
        serializer = EmailRegisterSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        email: str = serializer.validated_data["email"]
        nome: str = serializer.validated_data["nome"]
        data_nascimento = serializer.validated_data["data_nascimento"]
        password: str = serializer.validated_data["password"]
        telemovel: str | None = serializer.validated_data.get("telemovel") or None

        # Validação estrita: O e-mail DEVE estar com is_verificado == True na base de dados
        registo_verificado = RegistoOTPEmail.objects.filter(
            email=email,
            is_verificado=True,
        ).exists()

        if not registo_verificado:
            logger.warning("Tentativa de registo bloqueada: e-mail não verificado (%s)", email)
            return Response(
                {
                    "erro": "email_nao_verificado",
                    "detalhe": _(
                        "O endereço de e-mail ainda não foi validado com código OTP. "
                        "A validação é obrigatória antes de concluir a criação da conta."
                    ),
                },
                status=status.HTTP_403_FORBIDDEN,
            )

        tipo_solicitado = serializer.validated_data.get(
            "tipo_utilizador", CustomUser.TipoUtilizador.CLIENTE
        )

        # Criação do utilizador na tabela CustomUser
        user = CustomUser.objects.create_user(
            telemovel=telemovel,
            email=email,
            nome=nome,
            password=password,
            data_nascimento=data_nascimento,
            tipo_utilizador=tipo_solicitado,
            estado=CustomUser.EstadoConta.ATIVO,
        )

        # Gravação dos consentimentos obrigatórios
        PerfilConsentimento.objects.update_or_create(
            utilizador=user,
            defaults={
                "termos_utilizacao": serializer.validated_data.get("termos_utilizacao", True),
                "politica_privacidade": serializer.validated_data.get("politica_privacidade", True),
                "marketing": serializer.validated_data.get("marketing", False),
            },
        )

        # Invalida os registos OTP para este e-mail após a criação bem-sucedida
        RegistoOTPEmail.objects.filter(email=email).delete()

        logger.info(
            "Utilizador registado e ativado via e-mail com sucesso: %s (id=%s)",
            user.email,
            user.id,
        )

        # Emissão dos tokens JWT de sessão
        tokens = gerar_tokens_jwt_para_utilizador(user)

        return Response(
            {
                "mensagem": _("Conta criada com sucesso."),
                "tokens": tokens,
                "perfil": UtilizadorResumoSerializer(user).data,
            },
            status=status.HTTP_201_CREATED,
        )


class GoogleAuthView(APIView):
    """
    Endpoint para autenticação social com Google Sign-In (POST /api/v1/auth/google/).
    Recebe o ID token emitido pelo Google Play Services / Google OAuth,
    valida a assinatura e dados do utilizador diretamente junto da API Google,
    e emite os tokens de sessão JWT (SimpleJWT).
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []
    throttle_classes = []

    def post(self, request: Request) -> Response:
        token = request.data.get("token")
        if not token or not isinstance(token, str):
            return Response(
                {
                    "erro": "token_obrigatorio",
                    "detalhe": _("O token de autenticação Google é obrigatório."),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        import requests

        # Validação do ID token na API oficial de verificação de tokens da Google
        try:
            google_response = requests.get(
                "https://oauth2.googleapis.com/tokeninfo",
                params={"id_token": token.strip()},
                timeout=10,
            )
        except Exception as e:
            logger.error("Erro ao contactar API Google para validação de token: %s", e)
            return Response(
                {
                    "erro": "erro_comunicacao_google",
                    "detalhe": _("Não foi possível validar o token junto dos servidores Google."),
                },
                status=status.HTTP_502_BAD_GATEWAY,
            )

        if google_response.status_code != 200:
            logger.warning("Token Google inválido rejeitado pela API da Google: %s", google_response.text)
            return Response(
                {
                    "erro": "token_invalido",
                    "detalhe": _("Token Google inválido ou expirado."),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        payload = google_response.json()
        email = payload.get("email")
        if not email:
            return Response(
                {
                    "erro": "email_nao_encontrado",
                    "detalhe": _("A conta Google não forneceu um endereço de e-mail válido."),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        email_normalizado = email.strip().lower()
        nome = payload.get("name") or payload.get("given_name") or email_normalizado.split("@")[0]

        # Procura ou cria o utilizador
        try:
            with transaction.atomic():
                user = CustomUser.objects.filter(email=email_normalizado).first()
                if user:
                    if user.estado == CustomUser.EstadoConta.SUSPENSO or not user.is_active:
                        return Response(
                            {
                                "erro": "conta_suspensa",
                                "detalhe": _("Esta conta encontra-se suspensa ou inativa. Contacte o suporte."),
                            },
                            status=status.HTTP_403_FORBIDDEN,
                        )
                else:
                    user = CustomUser.objects.create_user(
                        email=email_normalizado,
                        nome=nome,
                        estado=CustomUser.EstadoConta.ATIVO,
                    )
                    # Cria os consentimentos obrigatórios
                    PerfilConsentimento.objects.get_or_create(
                        utilizador=user,
                        defaults={
                            "termos_utilizacao": True,
                            "politica_privacidade": True,
                            "marketing": False,
                        },
                    )

            tokens = gerar_tokens_jwt_para_utilizador(user)
            logger.info("Autenticação Google bem-sucedida para o e-mail: %s", user.email)
            return Response(
                {
                    "mensagem": _("Autenticado com sucesso via Google."),
                    "tokens": tokens,
                    "perfil": UtilizadorResumoSerializer(user).data,
                },
                status=status.HTTP_200_OK,
            )
        except Exception as e:
            logger.error("Erro ao autenticar utilizador Google: %s", e, exc_info=True)
            return Response(
                {
                    "erro": "erro_interno",
                    "detalhe": _("Erro interno ao processar a autenticação Google."),
                },
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )


class EmailPasswordLoginView(APIView):
    """
    Endpoint: `POST /api/v1/auth/login/`
    Autenticação tradicional por e-mail (ou telemóvel) e palavra-passe.
    Valida as credenciais, verifica suspensão de conta (RN-008) e emite o par de tokens JWT.
    """

    permission_classes = [permissions.AllowAny]
    authentication_classes = []
    throttle_classes = []

    def post(self, request: Request) -> Response:
        try:
            serializer = EmailPasswordLoginSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)

            identificador: str = serializer.validated_data["email"].strip()
            password: str = serializer.validated_data["password"]

            # Busca o utilizador por e-mail ou por telemóvel
            user = CustomUser.objects.filter(email__iexact=identificador).first()
            if not user:
                user = CustomUser.objects.filter(telemovel=identificador).first()

            if not user:
                return Response(
                    {
                        "erro": "utilizador_nao_encontrado",
                        "detalhe": _("Não foi encontrada nenhuma conta associada a este e-mail. Crie uma nova conta ou verifique o endereço."),
                    },
                    status=status.HTTP_401_UNAUTHORIZED,
                )

            # Verifica se o utilizador já tem palavra-passe configurada (contas criadas via Código OTP)
            if not user.has_usable_password():
                return Response(
                    {
                        "erro": "senha_nao_configurada",
                        "detalhe": _("Esta conta foi criada via Código OTP e ainda não possui palavra-passe. Aceda pela aba 'Código OTP' para entrar diretamente."),
                    },
                    status=status.HTTP_401_UNAUTHORIZED,
                )

            if not user.check_password(password):
                return Response(
                    {
                        "erro": "credenciais_invalidas",
                        "detalhe": _("Palavra-passe incorreta. Verifique a senha digitada ou aceda rapidamente via Código OTP."),
                    },
                    status=status.HTTP_401_UNAUTHORIZED,
                )

            # RN-008: Verificação de suspensão
            if user.estado == CustomUser.EstadoConta.SUSPENSO:
                return Response(
                    {
                        "erro": "conta_suspensa",
                        "detalhe": _("RN-008: Conta suspensa por motivos de segurança. Contacte o suporte."),
                    },
                    status=status.HTTP_403_FORBIDDEN,
                )

            # Se o utilizador estava PENDENTE, ativa a conta
            if user.estado == CustomUser.EstadoConta.PENDENTE:
                user.estado = CustomUser.EstadoConta.ATIVO
                user.is_active = True
                user.save(update_fields=["estado", "is_active"])

            tokens = gerar_tokens_jwt_para_utilizador(user)

            logger.info(
                "Utilizador autenticado com sucesso via palavra-passe: %s (id=%s)",
                user.email or user.telemovel,
                user.id,
            )

            return Response(
                {
                    "mensagem": _("Autenticação realizada com sucesso."),
                    "registo_pendente": False,
                    "tokens": tokens,
                    "perfil": UtilizadorResumoSerializer(user).data,
                },
                status=status.HTTP_200_OK,
            )
        except serializers.ValidationError as val_err:
            return Response(val_err.detail, status=status.HTTP_400_BAD_REQUEST)
        except Exception as e:
            logger.exception("Erro interno no processamento de login com palavra-passe: %s", e)
            return Response(
                {
                    "erro": "erro_interno",
                    "detalhe": _("Erro interno ao processar autenticação. Tente novamente."),
                },
                status=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )


class MoradaViewSet(viewsets.ModelViewSet):
    """
    ViewSet para gestão de moradas do cliente autenticado (RN-005):
    - GET /api/v1/auth/moradas/
    - POST /api/v1/auth/moradas/
    - DELETE /api/v1/auth/moradas/{id}/
    """

    permission_classes = [permissions.IsAuthenticated]
    serializer_class = MoradaSerializer

    def get_queryset(self):
        user = self.request.user
        if not user.is_authenticated:
            return Morada.objects.none()
        return Morada.objects.filter(utilizador=user)

    def perform_create(self, serializer):
        serializer.save(utilizador=self.request.user)



