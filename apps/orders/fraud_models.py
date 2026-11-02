"""
Modelos de dados para Segurança, Auditoria e Prevenção de Fraude ('orders' / 'security').
Implementa rigorosamente as Regras de Negócio da Secção 6.14:
- RN-130: Monitorização contínua de risco e classificação probabilística de transações.
- RN-131: Rastreabilidade de dispositivos móveis (`device_id`) e cartões de pagamento múltiplos.
- RN-132: Proteção contra abuso de promoções, cupões de boas-vindas e programas de referral.
- RN-133: Deteção de telemetria anómala, GPS falso e velocidades físicas impossíveis de estafetas.
- RN-135: Lista de Bloqueio Imutável de identificadores confirmados como fraudulentos.
- RN-068: Conformidade absoluta com PCI DSS (apenas hashes/fingerprints e tokens opacos; nunca armazena PAN/CVV).
"""
import uuid
from typing import Any

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _


class DispositivoUtilizador(models.Model):
    """
    Rastreia os dispositivos móveis utilizados para aceder à plataforma (RN-131).
    Permite detetar se o mesmo hardware está a ser partilhado por múltiplas contas.
    """

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Dispositivo Registado"),
    )
    utilizador = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="dispositivos_associados",
        verbose_name=_("Utilizador"),
    )
    device_id = models.CharField(
        max_length=128,
        db_index=True,
        verbose_name=_("ID Único do Dispositivo (Hardware/App UUID)"),
        help_text=_("RN-131: Identificador único gerado na app móvel do utilizador."),
    )
    ip_origem = models.GenericIPAddressField(
        null=True,
        blank=True,
        verbose_name=_("Endereço IP de Origem"),
    )
    user_agent = models.TextField(
        blank=True,
        default="",
        verbose_name=_("User Agent / Plataforma"),
    )
    data_primeiro_acesso = models.DateTimeField(
        auto_now_add=True,
        verbose_name=_("Data do Primeiro Acesso"),
    )
    data_ultimo_acesso = models.DateTimeField(
        auto_now=True,
        db_index=True,
        verbose_name=_("Data do Último Acesso"),
    )

    class Meta:
        db_table = "security_dispositivo_utilizador"
        verbose_name = _("Dispositivo do Utilizador")
        verbose_name_plural = _("Dispositivos dos Utilizadores")
        unique_together = [("utilizador", "device_id")]
        indexes = [
            models.Index(fields=["device_id", "data_ultimo_acesso"], name="idx_disp_devid_acesso"),
        ]

    def __str__(self) -> str:
        return f"Device {self.device_id[:12]}... (User: {self.utilizador_id})"


class ImpressaoDigitalCartao(models.Model):
    """
    Registo de cartões de pagamento tokenizados para deteção de partilha fraudulenta (RN-131).
    Em total cumprimento com a regra PCI DSS RN-068, nunca armazena PAN nem CVV.
    Guarda exclusivamente o fingerprint unidirecional (SHA-256) gerado pelo gateway.
    """

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Registo"),
    )
    utilizador = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="cartoes_registados",
        verbose_name=_("Utilizador Titular"),
    )
    card_fingerprint = models.CharField(
        max_length=64,
        db_index=True,
        verbose_name=_("Fingerprint Criptográfico do Cartão"),
        help_text=_("RN-068 / RN-131: Hash SHA-256 único e não reversível do cartão fornecido pelo gateway."),
    )
    gateway_token = models.CharField(
        max_length=128,
        blank=True,
        default="",
        verbose_name=_("Token do Gateway (tok_... / pm_...)"),
    )
    ultimos_quatro = models.CharField(
        max_length=4,
        blank=True,
        default="",
        verbose_name=_("Últimos 4 Dígitos"),
    )
    bandeira = models.CharField(
        max_length=30,
        blank=True,
        default="",
        verbose_name=_("Bandeira / Esquema"),
    )
    data_associacao = models.DateTimeField(
        auto_now_add=True,
        db_index=True,
        verbose_name=_("Data de Registo"),
    )

    class Meta:
        db_table = "security_cartao_fingerprint"
        verbose_name = _("Impressão Digital de Cartão (PCI DSS)")
        verbose_name_plural = _("Impressões Digitais de Cartões")
        unique_together = [("utilizador", "card_fingerprint")]
        indexes = [
            models.Index(fields=["card_fingerprint", "data_associacao"], name="idx_card_fgprint_data"),
        ]

    def __str__(self) -> str:
        return f"Card ****{self.ultimos_quatro} [{self.bandeira}] (User: {self.utilizador_id})"


class ListaBloqueioImutavel(models.Model):
    """
    Entidade de Lista Negra / Bloqueio Imutável permanente (RN-135).
    Armazena identificadores fraudulentos confirmados com impedimento absoluto de remoção física.
    """

    class TipoIdentificador(models.TextChoices):
        USER_ID = "USER_ID", _("ID do Utilizador (UUID)")
        DEVICE_ID = "DEVICE_ID", _("ID do Dispositivo Móvel")
        CARD_FINGERPRINT = "CARD_FINGERPRINT", _("Fingerprint do Cartão Bancário")
        TELEMOVEL = "TELEMOVEL", _("Número de Telemóvel E.164")
        EMAIL = "EMAIL", _("Endereço de Email")
        IP_ADDRESS = "IP_ADDRESS", _("Endereço IP")
        ESTAFETA_ID = "ESTAFETA_ID", _("ID do Estafeta")

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Entrada de Bloqueio"),
    )
    tipo_identificador = models.CharField(
        max_length=30,
        choices=TipoIdentificador.choices,
        db_index=True,
        verbose_name=_("Tipo de Identificador Bloqueado"),
    )
    valor_identificador = models.CharField(
        max_length=255,
        db_index=True,
        verbose_name=_("Valor do Identificador Bloqueado"),
    )
    motivo = models.TextField(
        verbose_name=_("Motivo Circunstanciado do Bloqueio"),
    )
    score_risco = models.PositiveSmallIntegerField(
        default=100,
        verbose_name=_("Score de Risco no Momento do Bloqueio"),
    )
    evidencia = models.JSONField(
        default=dict,
        blank=True,
        verbose_name=_("Evidência Estruturada (JSON)"),
    )
    bloqueado_por = models.CharField(
        max_length=100,
        default="SISTEMA_ANTIFRAUDE",
        verbose_name=_("Ator Responsável pelo Bloqueio"),
    )
    data_bloqueio = models.DateTimeField(
        auto_now_add=True,
        db_index=True,
        editable=False,
        verbose_name=_("Data/Hora do Bloqueio"),
    )
    is_ativo = models.BooleanField(
        default=True,
        verbose_name=_("Bloqueio Ativo"),
    )

    class Meta:
        db_table = "security_lista_bloqueio_imutavel"
        verbose_name = _("Entrada da Lista de Bloqueio Imutável")
        verbose_name_plural = _("Lista de Bloqueio Imutável (Blacklist)")
        ordering = ["-data_bloqueio"]
        indexes = [
            models.Index(fields=["tipo_identificador", "valor_identificador"], name="idx_blacklist_tipo_valor"),
        ]

    def delete(self, *args: Any, **kwargs: Any) -> tuple[int, dict[str, int]]:
        """
        RN-135: Garante a imutabilidade da lista de bloqueio. Entradas nunca são eliminadas fisicamente.
        """
        raise ValidationError(
            _("RN-135: Violação de Imutabilidade. Entradas na lista de bloqueio nunca podem ser eliminadas.")
        )

    def __str__(self) -> str:
        return f"BLACKLIST [{self.tipo_identificador}] {self.valor_identificador} - {self.motivo[:40]}"


class RegistoAlertaFraude(models.Model):
    """
    Registo histórico de alertas e anomalias operacionais para auditoria e monitorização do backoffice.
    """

    class TipoFraude(models.TextChoices):
        DISPOSITIVO_CARTAO_MULTICONTAS = "DISPOSITIVO_CARTAO_MULTICONTAS", _("Dispositivo/Cartão Partilhado (>3 Contas)")
        ABUSO_PROMOCOES_MORADA = "ABUSO_PROMOCOES_MORADA", _("Abuso de Promoções/Referral na Mesma Morada")
        GPS_FALSO_VELOCIDADE_IMPOSSIVEL = "GPS_FALSO_VELOCIDADE_IMPOSSIVEL", _("Telemetria Anómala / Velocidade Impossível")
        BLACKLIST_HIT = "BLACKLIST_HIT", _("Identificador Presente na Lista de Bloqueio")
        PADRAO_SUSPEITO = "PADRAO_SUSPEITO", _("Padrão Comportamental Suspeito")

    class Severidade(models.TextChoices):
        BAIXA = "BAIXA", _("Baixa")
        MEDIA = "MEDIA", _("Média")
        ALTA = "ALTA", _("Alta")
        CRITICA = "CRITICA", _("Crítica")

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Alerta"),
    )
    pedido = models.ForeignKey(
        "orders.Pedido",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name="alertas_fraude",
        verbose_name=_("Pedido Associado"),
    )
    utilizador = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name="alertas_fraude",
        verbose_name=_("Utilizador Investigado"),
    )
    estafeta = models.ForeignKey(
        "logistics.Estafeta",
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name="alertas_fraude",
        verbose_name=_("Estafeta Investigado"),
    )
    tipo_fraude = models.CharField(
        max_length=40,
        choices=TipoFraude.choices,
        db_index=True,
        verbose_name=_("Tipo de Fraude Detetada"),
    )
    severidade = models.CharField(
        max_length=15,
        choices=Severidade.choices,
        default=Severidade.MEDIA,
        db_index=True,
        verbose_name=_("Nível de Severidade"),
    )
    score_atribuido = models.PositiveSmallIntegerField(
        default=0,
        verbose_name=_("Score de Risco Atribuído"),
    )
    detalhes = models.JSONField(
        default=dict,
        blank=True,
        verbose_name=_("Detalhes e Métricas da Análise"),
    )
    acao_tomada = models.CharField(
        max_length=100,
        verbose_name=_("Ação Automática Tomada"),
    )
    data_criacao = models.DateTimeField(
        auto_now_add=True,
        db_index=True,
        verbose_name=_("Data/Hora do Alerta"),
    )

    class Meta:
        db_table = "security_registo_alerta_fraude"
        verbose_name = _("Registo de Alerta de Fraude")
        verbose_name_plural = _("Registos de Alertas de Fraude")
        ordering = ["-data_criacao"]

    def __str__(self) -> str:
        return f"[{self.severidade}] {self.tipo_fraude} (Score: {self.score_atribuido}) @ {self.data_criacao.isoformat()}"

