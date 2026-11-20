"""
Modelos de dados da aplicação 'accounts'.
Implementa as regras de negócio RN-001 a RN-008 do documento funcional:
- RN-001: Identificação única e autenticação principal via número de telemóvel.
- RN-002: Verificação por OTP (validade, limite de 5 tentativas, rate-limit horário e bloqueio temporário).
- RN-003: Dados obrigatórios de registo e validação de perfil (nome, email único, data de nascimento, estado).
- RN-004: Gestão de consentimentos RGPD (Termos, Privacidade, Marketing, Localização em 2.º plano) com registo temporal.
- RN-005: Gestão de moradas georreferenciadas (PostGIS PointField SRID 4326) e metadados de entrega para o estafeta.
- RN-006: Controlo de suspensão e bloqueio operacional da conta.
- RN-007: Transição de estados da conta (Pendente -> Ativo -> Suspenso).
- RN-008: Auditoria temporal de criação, retenção e ciclo de vida da conta de utilizador.
"""
import uuid
from typing import Any

from django.contrib.auth.base_user import BaseUserManager
from django.contrib.auth.models import AbstractUser
from django.contrib.gis.db import models as gis_models
from django.core.exceptions import ValidationError
from django.core.validators import RegexValidator
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

# Validador E.164 para números de telemóvel (RN-001, RN-002)
validador_telemovel = RegexValidator(
    regex=r"^\+?[1-9]\d{7,14}$",
    message=_(
        "RN-001: O número de telemóvel deve estar no formato internacional E.164 "
        "(ex.: +351912345678), contendo entre 8 e 15 dígitos."
    ),
)


class CustomUserManager(BaseUserManager):
    """
    Manager personalizado para o modelo CustomUser onde o 'telemovel' é o identificador
    único de autenticação em substituição do 'username' padrão (RN-001).
    """

    use_in_migrations = True

    def create_user(
        self,
        telemovel: str | None = None,
        email: str | None = None,
        nome: str | None = None,
        password: str | None = None,
        **extra_fields: Any,
    ) -> "CustomUser":
        """
        Cria e guarda um utilizador regular com telemóvel ou email e nome (RN-001, RN-003).
        """
        if not telemovel and not email:
            raise ValueError(_("RN-001: É obrigatório fornecer pelo menos 'telemovel' ou 'email'."))
        if not nome:
            raise ValueError(_("RN-003: O campo 'nome' é obrigatório."))

        email_normalizado = self.normalize_email(email) if email else None
        extra_fields.setdefault("is_active", True)

        user = self.model(
            telemovel=telemovel.strip() if telemovel else None,
            email=email_normalizado,
            nome=nome.strip(),
            **extra_fields,
        )
        if password:
            user.set_password(password)
        else:
            user.set_unusable_password()

        user.save(using=self._db)
        return user

    def create_superuser(
        self,
        telemovel: str,
        email: str,
        nome: str,
        password: str | None = None,
        **extra_fields: Any,
    ) -> "CustomUser":
        """
        Cria e guarda um superutilizador ativo com permissões administrativas (RN-001, RN-007).
        """
        extra_fields.setdefault("is_staff", True)
        extra_fields.setdefault("is_superuser", True)
        extra_fields.setdefault("is_active", True)
        extra_fields.setdefault("estado", CustomUser.EstadoConta.ATIVO)

        if extra_fields.get("is_staff") is not True:
            raise ValueError(_("Superuser precisa de ter is_staff=True."))
        if extra_fields.get("is_superuser") is not True:
            raise ValueError(_("Superuser precisa de ter is_superuser=True."))

        return self.create_user(telemovel, email, nome, password, **extra_fields)


class CustomUser(AbstractUser):
    """
    Entidade 1: Utilizador personalizado do sistema (substitui o User padrão do Django).
    Utiliza o 'telemovel' como identificador principal de login (RN-001) e gere o ciclo
    de vida e estado operacional da conta (RN-003, RN-006, RN-007, RN-008).
    """

    class EstadoConta(models.TextChoices):
        """Estados possíveis da conta do utilizador (RN-003, RN-006, RN-007, RN-008)."""

        ATIVO = "ATIVO", _("Ativo")
        SUSPENSO = "SUSPENSO", _("Suspenso")
        PENDENTE = "PENDENTE", _("Pendente")

    class TipoUtilizador(models.TextChoices):
        """Papel operacional do utilizador na plataforma (RBAC)."""

        CLIENTE = "CLIENTE", _("Cliente")
        PARCEIRO = "PARCEIRO", _("Parceiro / Restaurante")
        ESTAFETA = "ESTAFETA", _("Estafeta / Entregador")
        ADMIN = "ADMIN", _("Administrador")

    # Remove o campo username herdado do AbstractUser para impor o telemóvel como credencial (RN-001)
    username = None  # type: ignore[assignment]

    # RN-003 / RN-008: Identificador primário universal (UUID v4) para segurança e rastreabilidade
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Utilizador"),
        help_text=_("RN-003 / RN-008: Identificador único universal (UUID v4) do utilizador."),
    )

    # Papel funcional / Tipo de Utilizador (RBAC)
    tipo_utilizador = models.CharField(
        max_length=20,
        choices=TipoUtilizador.choices,
        default=TipoUtilizador.CLIENTE,
        db_index=True,
        verbose_name=_("Tipo de Utilizador / Papel"),
        help_text=_("Perfil funcional e permissões operacionais do utilizador na plataforma."),
    )

    # RN-003: Nome completo do utilizador para identificação no perfil e entregas
    nome = models.CharField(
        max_length=150,
        blank=True,
        default="",
        verbose_name=_("Nome Completo"),
        help_text=_("RN-003: Nome completo do titular da conta."),
    )

    # RN-001: Identificador principal de autenticação e contacto para OTP (opcional para contas criadas via e-mail)
    telemovel = models.CharField(
        max_length=20,
        unique=True,
        null=True,
        blank=True,
        db_index=True,
        validators=[validador_telemovel],
        verbose_name=_("Número de Telemóvel"),
        help_text=_(
            "RN-001: Identificador único do utilizador (formato E.164, ex: +351912345678)."
        ),
    )

    # RN-003: Endereço de correio eletrónico único para faturação, recibos e recuperação de conta
    email = models.EmailField(
        unique=True,
        null=True,
        blank=True,
        db_index=True,
        verbose_name=_("Endereço de Email"),
        help_text=_("RN-003: Endereço de email único associado à conta."),
    )

    # RN-003, RN-006, RN-007, RN-008: Estado operacional da conta (Pendente por defeito até validação OTP/perfil)
    estado = models.CharField(
        max_length=15,
        choices=EstadoConta.choices,
        default=EstadoConta.PENDENTE,
        db_index=True,
        verbose_name=_("Estado da Conta"),
        help_text=_(
            "RN-003 / RN-006 / RN-007 / RN-008: Estado atual da conta (Ativo, Suspenso, Pendente)."
        ),
    )

    # RN-003: Data de nascimento para verificação de maioridade legal e restrições de produtos
    data_nascimento = models.DateField(
        null=True,
        blank=True,
        verbose_name=_("Data de Nascimento"),
        help_text=_("RN-003: Data de nascimento do utilizador para validação de elegibilidade/idade."),
    )

    # RN-003, RN-008: Timestamp imutável do momento de registo da conta para auditoria
    data_criacao = models.DateTimeField(
        auto_now_add=True,
        editable=False,
        verbose_name=_("Data de Criação"),
        help_text=_("RN-003 / RN-008: Data e hora exatas da criação do registo da conta."),
    )

    # Definição do campo de autenticação principal e campos obrigatórios (RN-001, RN-003)
    USERNAME_FIELD = "telemovel"
    REQUIRED_FIELDS = ["email", "nome"]

    objects = CustomUserManager()

    class Meta:
        db_table = "accounts_custom_user"
        verbose_name = _("Utilizador")
        verbose_name_plural = _("Utilizadores")
        ordering = ["-data_criacao"]
        indexes = [
            models.Index(fields=["telemovel"], name="idx_user_telemovel"),
            models.Index(fields=["email"], name="idx_user_email"),
            models.Index(fields=["tipo_utilizador"], name="idx_user_tipo_utilizador"),
            models.Index(fields=["estado", "data_criacao"], name="idx_user_estado_criacao"),
        ]

    @property
    def is_cliente(self) -> bool:
        return self.tipo_utilizador == self.TipoUtilizador.CLIENTE

    @property
    def is_parceiro(self) -> bool:
        return self.tipo_utilizador == self.TipoUtilizador.PARCEIRO

    @property
    def is_estafeta(self) -> bool:
        return self.tipo_utilizador == self.TipoUtilizador.ESTAFETA

    def __str__(self) -> str:
        return f"{self.nome} ({self.telemovel}) [{self.estado}]"

    def save(self, *args: Any, **kwargs: Any) -> None:
        """
        Sincroniza a flag nativa `is_active` do Django com o estado de negócio quando
        a conta é suspensa (RN-006, RN-007, RN-008).
        """
        if self.estado == self.EstadoConta.SUSPENSO:
            self.is_active = False
        elif self.estado == self.EstadoConta.ATIVO:
            self.is_active = True
        super().save(*args, **kwargs)


class PerfilConsentimento(models.Model):
    """
    Entidade 2: Registo de consentimentos legais e de privacidade (RGPD) do utilizador.
    Implementa a regra RN-004 garantindo rastreabilidade das permissões concedidas.
    """

    # RN-004: Relação estrita 1-para-1 com o utilizador titular dos consentimentos
    utilizador = models.OneToOneField(
        CustomUser,
        on_delete=models.CASCADE,
        related_name="consentimento",
        primary_key=True,
        verbose_name=_("Utilizador"),
        help_text=_("RN-004: Utilizador a quem pertence este perfil de consentimento (OneToOne)."),
    )

    # RN-004: Aceitação obrigatória dos Termos e Condições de Utilização da plataforma
    termos_utilizacao = models.BooleanField(
        default=False,
        verbose_name=_("Aceitou Termos de Utilização"),
        help_text=_("RN-004: Indica se o utilizador aceitou os Termos de Utilização (obrigatório)."),
    )

    # RN-004: Aceitação obrigatória da Política de Privacidade e tratamento de dados
    politica_privacidade = models.BooleanField(
        default=False,
        verbose_name=_("Aceitou Política de Privacidade"),
        help_text=_("RN-004: Indica se o utilizador tomou conhecimento e aceitou a Política de Privacidade."),
    )

    # RN-004: Consentimento opcional para comunicações promocionais e campanhas de marketing
    marketing = models.BooleanField(
        default=False,
        verbose_name=_("Aceitou Comunicações de Marketing"),
        help_text=_("RN-004: Consentimento opcional para envio de notificações e ofertas promocionais."),
    )

    # RN-004: Consentimento para recolha de geolocalização em segundo plano (rastreio de entrega)
    localizacao_segundo_plano = models.BooleanField(
        default=False,
        verbose_name=_("Autorizou Localização em Segundo Plano"),
        help_text=_(
            "RN-004: Autorização explícita para recolha de coordenadas GPS em segundo plano."
        ),
    )

    # RN-004: Registo temporal da última recolha/atualização do consentimento para auditoria RGPD
    timestamp = models.DateTimeField(
        auto_now=True,
        verbose_name=_("Data/Hora do Consentimento"),
        help_text=_("RN-004: Carimbo temporal (timestamp) da assinatura/atualização dos consentimentos."),
    )

    class Meta:
        db_table = "accounts_perfil_consentimento"
        verbose_name = _("Perfil de Consentimento")
        verbose_name_plural = _("Perfis de Consentimento")

    def clean(self) -> None:
        """
        RN-004: Valida que os consentimentos estritamente obrigatórios (Termos e Privacidade)
        foram aceites antes de ativar a utilização da plataforma.
        """
        super().clean()
        if not self.termos_utilizacao or not self.politica_privacidade:
            raise ValidationError(
                _(
                    "RN-004: A aceitação dos Termos de Utilização e da Política de Privacidade "
                    "é obrigatória."
                )
            )

    def __str__(self) -> str:
        try:
            user_str = self.utilizador.telemovel if self.utilizador_id else "Sem Utilizador"
        except Exception:
            user_str = "Sem Utilizador"
        ts_str = self.timestamp.isoformat() if getattr(self, "timestamp", None) else "Sem Data"
        return f"Consentimento de {user_str} @ {ts_str}"


class Morada(gis_models.Model):
    """
    Entidade 3: Morada de entrega associada a um utilizador com suporte espacial PostGIS.
    Implementa a regra RN-005 para cálculo de raio de entrega, rotas e instruções ao estafeta.
    """

    # RN-005: Identificador único universal da morada
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Morada"),
        help_text=_("RN-005: Identificador único universal (UUID v4) da morada."),
    )

    # RN-005: Utilizador proprietário da morada (um utilizador pode ter múltiplas moradas)
    utilizador = models.ForeignKey(
        CustomUser,
        on_delete=models.CASCADE,
        related_name="moradas",
        verbose_name=_("Utilizador"),
        help_text=_("RN-005: Utilizador a quem pertence esta morada de entrega."),
    )

    # RN-005: Coordenada geográfica exata (Longitude, Latitude) em WGS84 (SRID 4326) no PostGIS
    geolocalizacao = gis_models.PointField(
        srid=4326,
        geography=True,
        spatial_index=True,
        verbose_name=_("Geolocalização (PostGIS)"),
        help_text=_(
            "RN-005: Ponto geográfico PostGIS (Longitude/Latitude) com SRID=4326 para cálculos de distância."
        ),
    )

    # RN-005: Endereço textual completo formatado (rua, número, código postal, localidade)
    texto_endereco = models.CharField(
        max_length=255,
        verbose_name=_("Texto do Endereço"),
        help_text=_("RN-005: Morada completa em formato textual (rua, n.º, código postal, cidade)."),
    )

    # RN-005: Ponto de referência visual ou comercial próximo para facilitar a localização
    referencia = models.CharField(
        max_length=150,
        blank=True,
        default="",
        verbose_name=_("Ponto de Referência"),
        help_text=_("RN-005: Referência adicional de apoio à chegada (ex.: 'Junto à farmácia central')."),
    )

    # RN-005: Identificação específica de andar, fração, bloco ou número da porta
    andar_porta = models.CharField(
        max_length=80,
        blank=True,
        default="",
        verbose_name=_("Andar / Porta"),
        help_text=_("RN-005: Indicação do andar, porta, lote ou apartamento (ex.: '3.º Esq.')."),
    )

    # RN-005: Observações e instruções operacionais destinadas ao estafeta no ato da entrega
    instrucoes_estafeta = models.TextField(
        blank=True,
        default="",
        verbose_name=_("Instruções para o Estafeta"),
        help_text=_(
            "RN-005: Instruções específicas para o estafeta (ex.: código da campainha, deixar na receção)."
        ),
    )

    class Meta:
        db_table = "accounts_morada"
        verbose_name = _("Morada")
        verbose_name_plural = _("Moradas")
        indexes = [
            models.Index(fields=["utilizador"], name="idx_morada_utilizador"),
        ]

    def __str__(self) -> str:
        try:
            user_str = self.utilizador.telemovel if self.utilizador_id else "Sem Utilizador"
        except Exception:
            user_str = "Sem Utilizador"
        endereco = getattr(self, "texto_endereco", "") or "Endereço não definido"
        andar = getattr(self, "andar_porta", "")
        porta = f" ({andar})" if andar else ""
        return f"{endereco}{porta} - {user_str}"


class RegistoOTP(models.Model):
    """
    Entidade 4: Controlo de emissão, validação, rate-limiting e bloqueio de códigos OTP (One-Time Password).
    Implementa a regra RN-002 para proteção contra ataques de força bruta e abuso de SMS.
    """

    # RN-002: Número de telemóvel destinatário do código OTP (pode ainda não ter CustomUser criado)
    telemovel = models.CharField(
        max_length=20,
        db_index=True,
        validators=[validador_telemovel],
        verbose_name=_("Número de Telemóvel"),
        help_text=_("RN-002: Número de telemóvel associado ao desafio de autenticação OTP."),
    )

    # RN-002: Código OTP gerado (ou respetivo hash) enviado ao utilizador
    codigo_otp = models.CharField(
        max_length=128,
        verbose_name=_("Código OTP"),
        help_text=_("RN-002: Código numérico temporário de verificação enviado por SMS/canal seguro."),
    )

    # RN-002: Contador decrescente de tentativas permitidas para o OTP atual (máximo inicial de 5)
    tentativas_restantes = models.PositiveSmallIntegerField(
        default=5,
        verbose_name=_("Tentativas Restantes"),
        help_text=_("RN-002: Número de tentativas de validação restantes (por defeito 5) antes de bloqueio."),
    )

    # RN-002: Momento exato em que o código OTP deixa de ser válido (TTL curto)
    expira_em = models.DateTimeField(
        db_index=True,
        verbose_name=_("Expira Em"),
        help_text=_("RN-002: Data e hora limite de validade do código OTP emitido."),
    )

    # RN-002: Timestamp até ao qual o telemóvel está impedido de validar/pedir novos OTPs após exceder limites
    bloqueado_ate = models.DateTimeField(
        null=True,
        blank=True,
        db_index=True,
        verbose_name=_("Bloqueado Até"),
        help_text=_(
            "RN-002: Data e hora até à qual o número se encontra temporariamente bloqueado "
            "por esgotamento de tentativas ou excesso de envios."
        ),
    )

    # RN-002: Contador de códigos OTP solicitados na janela da última hora (rate-limiting de envios)
    contagem_envios_hora = models.PositiveSmallIntegerField(
        default=1,
        verbose_name=_("Contagem de Envios na Última Hora"),
        help_text=_(
            "RN-002: Total acumulado de envios de OTP para este número na janela horária atual."
        ),
    )

    class Meta:
        db_table = "accounts_registo_otp"
        verbose_name = _("Registo de OTP")
        verbose_name_plural = _("Registos de OTP")
        ordering = ["-expira_em"]
        indexes = [
            models.Index(fields=["telemovel", "expira_em"], name="idx_otp_telemovel_expira"),
            models.Index(fields=["telemovel", "bloqueado_ate"], name="idx_otp_telemovel_bloqueio"),
        ]

    @property
    def esta_expirado(self) -> bool:
        """RN-002: Verifica se o código OTP já ultrapassou o tempo limite de validade."""
        return timezone.now() >= self.expira_em

    @property
    def esta_bloqueado(self) -> bool:
        """RN-002: Verifica se o número de telemóvel se encontra sob bloqueio ativo."""
        return bool(self.bloqueado_ate and timezone.now() < self.bloqueado_ate)

    def registar_falha_tentativa(self, duracao_bloqueio_minutos: int = 30) -> None:
        """
        RN-002: Decrementa `tentativas_restantes` e aplica bloqueio temporário caso atinja zero.
        """
        if self.tentativas_restantes > 0:
            self.tentativas_restantes -= 1

        if self.tentativas_restantes == 0:
            self.bloqueado_ate = timezone.now() + timezone.timedelta(minutes=duracao_bloqueio_minutos)

        self.save(update_fields=["tentativas_restantes", "bloqueado_ate"])

    def __str__(self) -> str:
        estado_bloqueio = f" [BLOQUEADO ATÉ {self.bloqueado_ate}]" if self.esta_bloqueado else ""
        return (
            f"OTP {self.telemovel} (Tentativas: {self.tentativas_restantes}, "
            f"Envios/h: {self.contagem_envios_hora}){estado_bloqueio}"
        )


class RegistoOTPEmail(models.Model):
    """
    Entidade 5: Controlo de emissão, validação, rate-limiting e autorização de OTP por E-mail.
    Garante que o endereço de e-mail é validado através de código de 6 dígitos antes de permitir o registo.
    """

    email = models.EmailField(
        max_length=254,
        db_index=True,
        verbose_name=_("Endereço de E-mail"),
        help_text=_("Endereço de e-mail destinatário do código OTP."),
    )

    codigo_hash = models.CharField(
        max_length=255,
        verbose_name=_("Hash do Código OTP"),
        help_text=_("Hash criptográfico do código numérico de 6 dígitos enviado por e-mail."),
    )

    tentativas_restantes = models.PositiveSmallIntegerField(
        default=5,
        verbose_name=_("Tentativas Restantes"),
        help_text=_("Número de tentativas restantes antes da invalidação do código."),
    )

    expira_em = models.DateTimeField(
        db_index=True,
        verbose_name=_("Expira Em"),
        help_text=_("Data e hora de expiração do código (5 minutos após a emissão)."),
    )

    is_verificado = models.BooleanField(
        default=False,
        db_index=True,
        verbose_name=_("E-mail Verificado"),
        help_text=_("Indica se o código OTP foi validado com sucesso e o e-mail está habilitado para registo."),
    )

    ip_origem = models.GenericIPAddressField(
        null=True,
        blank=True,
        verbose_name=_("IP de Origem"),
        help_text=_("Endereço IP do cliente solicitante para controlo de abuso e rate-limiting."),
    )

    contagem_pedidos_hora = models.PositiveSmallIntegerField(
        default=1,
        verbose_name=_("Pedidos na Última Hora"),
        help_text=_("Contador de solicitações de e-mail para rate limiting (máximo 3 por hora)."),
    )

    criado_em = models.DateTimeField(
        auto_now_add=True,
        verbose_name=_("Criado Em"),
    )

    atualizado_em = models.DateTimeField(
        auto_now=True,
        verbose_name=_("Atualizado Em"),
    )

    class Meta:
        db_table = "accounts_registo_otp_email"
        verbose_name = _("Registo de OTP por E-mail")
        verbose_name_plural = _("Registos de OTP por E-mail")
        ordering = ["-expira_em"]
        indexes = [
            models.Index(fields=["email", "expira_em"], name="idx_otp_email_expira"),
            models.Index(fields=["email", "is_verificado"], name="idx_otp_email_verif"),
            models.Index(fields=["ip_origem", "criado_em"], name="idx_otp_email_ip_criado"),
        ]

    @property
    def esta_expirado(self) -> bool:
        return timezone.now() >= self.expira_em

    def set_codigo(self, codigo_bruto: str) -> None:
        from django.contrib.auth.hashers import make_password
        self.codigo_hash = make_password(codigo_bruto)

    def check_codigo(self, codigo_bruto: str) -> bool:
        from django.contrib.auth.hashers import check_password
        return check_password(codigo_bruto, self.codigo_hash)

    def decrementar_tentativa(self) -> int:
        if self.tentativas_restantes > 0:
            self.tentativas_restantes -= 1
            self.save(update_fields=["tentativas_restantes", "atualizado_em"])
        return self.tentativas_restantes

    def __str__(self) -> str:
        verif = " [VERIFICADO]" if self.is_verificado else ""
        return f"OTP E-mail: {self.email} (Tentativas: {self.tentativas_restantes}){verif}"
