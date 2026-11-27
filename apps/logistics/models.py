"""
Modelos de dados da aplicação 'logistics' (Estafetas, Despacho, Entregas e Prova de Entrega).
Implementa a Secção 11 e as Regras de Negócio RN-082 a RN-101:
- RN-082: Onboarding documental de estafeta (carta de condução quando aplicável, documentos do veículo, aprovação).
- RN-083: Disponibilidade online/offline condicionada a aprovação e localização ativa em PostGIS.
- RN-084 / RN-085: Critérios de elegibilidade (veículo, proximidade PostGIS, score de reputação).
- RN-093: Confirmação de recolha na loja.
- RN-094: Tracking geográfico durante o transporte.
- RN-095: Validação de entrega com PIN de 4 dígitos, foto e coordenadas GPS (PostGIS PointField SRID 4326).
"""
import secrets
import uuid
from decimal import Decimal
from typing import Any

from django.conf import settings
from django.contrib.gis.db import models as gis_models
from django.core.exceptions import ValidationError
from django.core.validators import MaxValueValidator, MinValueValidator, RegexValidator
from django.db import models
from django.utils.translation import gettext_lazy as _


def gerar_pin_4_digitos() -> str:
    """RN-095: Gera um PIN numérico criptograficamente seguro de 4 dígitos (0000 a 9999)."""
    return f"{secrets.randbelow(10000):04d}"


validador_pin_entrega = RegexValidator(
    regex=r"^\d{4}$",
    message=_("RN-095: O PIN de entrega tem de conter exatamente 4 dígitos numéricos."),
)


class Estafeta(gis_models.Model):
    """
    Entidade 1: Representa o perfil operacional e logístico de um Estafeta na plataforma
    (Secção 6.8, Secção 11, RN-082, RN-083, RN-084).
    """

    class TipoVeiculo(models.TextChoices):
        """Tipos de veículo suportados para cálculo de capacidade e ETA (RN-082, RN-084)."""

        MOTA = "MOTA", _("Mota")
        CARRO = "CARRO", _("Carro")
        BICICLETA = "BICICLETA", _("Bicicleta")

    class StatusOnboarding(models.TextChoices):
        """Estados de validação documental do estafeta (RN-082)."""

        PENDENTE = "PENDENTE", _("Pendente")
        APROVADO = "APROVADO", _("Aprovado")

    # Secção 11: Identificador único universal (UUID v4) do estafeta
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Estafeta"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do estafeta."),
    )

    # Secção 11 / RN-082: Ligação 1-para-1 com a conta de utilizador base (CustomUser)
    utilizador = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="perfil_estafeta",
        verbose_name=_("Utilizador"),
        help_text=_("RN-082: Conta de utilizador (CustomUser) associada a este estafeta."),
    )

    # RN-082 / RN-084: Tipo de veículo utilizado nas entregas
    tipo_veiculo = models.CharField(
        max_length=15,
        choices=TipoVeiculo.choices,
        db_index=True,
        verbose_name=_("Tipo de Veículo"),
        help_text=_("RN-082 / RN-084: Veículo utilizado pelo estafeta (Mota, Carro, Bicicleta)."),
    )

    # RN-082: Número da carta de condução (obrigatório para veículos motorizados: Mota e Carro)
    carta_conducao = models.CharField(
        max_length=50,
        blank=True,
        default="",
        verbose_name=_("Carta de Condução"),
        help_text=_("RN-082: Número da carta de condução (obrigatório para Mota e Carro)."),
    )

    # RN-082: URL da foto/PDF da carta de condução
    carta_conducao_url = models.URLField(
        max_length=500,
        blank=True,
        default="",
        verbose_name=_("URL da Carta de Condução"),
        help_text=_("RN-082: Endereço URL do comprovativo digital da carta de condução."),
    )

    # RN-082: URL do documento/seguro/registo do veículo armazenado de forma segura
    documentos_veiculo_url = models.URLField(
        max_length=500,
        blank=True,
        default="",
        verbose_name=_("URL dos Documentos do Veículo"),
        help_text=_("RN-082: Endereço URL dos documentos comprovativos do veículo e seguro."),
    )

    # Identificação da Viatura (Marca/Modelo e Matrícula)
    marca_modelo_veiculo = models.CharField(
        max_length=100,
        blank=True,
        default="Haojue 125",
        verbose_name=_("Marca e Modelo da Viatura"),
        help_text=_("Marca, cilindrada e modelo da viatura do estafeta."),
    )

    matricula_veiculo = models.CharField(
        max_length=30,
        blank=True,
        default="LD-00-00-AA",
        verbose_name=_("Matrícula da Viatura"),
        help_text=_("Chapa de matrícula oficial da viatura (ex.: LD-44-99-AF)."),
    )

    # Dados Fiscais e Bancários para Repasses (RN-082 / RN-146)
    nif = models.CharField(
        max_length=30,
        blank=True,
        default="",
        verbose_name=_("NIF do Estafeta"),
        help_text=_("Número de Identificação Fiscal do estafeta."),
    )

    banco_nome = models.CharField(
        max_length=100,
        blank=True,
        default="Banco Angolano de Investimentos (BAI)",
        verbose_name=_("Banco para Repasses"),
        help_text=_("Instituição bancária angolana para liquidação de repasses."),
    )

    numero_conta = models.CharField(
        max_length=50,
        blank=True,
        default="",
        verbose_name=_("Número de Conta Bancária"),
    )

    iban = models.CharField(
        max_length=50,
        blank=True,
        default="AO06.0040.0000.0000.0000.0000.0",
        verbose_name=_("IBAN"),
        help_text=_("IBAN angolano (AO06...) para transferências e saques da carteira."),
    )

    navegador_padrao = models.CharField(
        max_length=30,
        blank=True,
        default="OSRM_INTEGRADO",
        verbose_name=_("Navegador GPS Padrão"),
        help_text=_("Preferência de navegação do estafeta (OSRM_INTEGRADO, GOOGLE_MAPS, WAZE)."),
    )

    # RN-082: Estado de aprovação do onboarding (só estafetas Aprovados podem ficar online)
    status_onboarding = models.CharField(
        max_length=15,
        choices=StatusOnboarding.choices,
        default=StatusOnboarding.PENDENTE,
        db_index=True,
        verbose_name=_("Estado de Onboarding"),
        help_text=_("RN-082: Estado da verificação documental (Pendente, Aprovado)."),
    )

    # RN-083: Indica se o estafeta está disponível e online para receber ofertas de despacho
    is_online = models.BooleanField(
        default=False,
        db_index=True,
        verbose_name=_("Está Online"),
        help_text=_(
            "RN-082 / RN-083: Indica se o estafeta está online. Exige status_onboarding='APROVADO' e localização ativa."
        ),
    )

    # RN-083 / RN-084 / RN-094: Última posição GPS conhecida do estafeta em PostGIS (SRID 4326)
    ultima_geolocalizacao = gis_models.PointField(
        srid=4326,
        geography=True,
        spatial_index=True,
        null=True,
        blank=True,
        verbose_name=_("Última Geolocalização (PostGIS)"),
        help_text=_(
            "RN-083 / RN-084 / RN-094: Coordenada GPS mais recente do estafeta (PostGIS PointField SRID 4326)."
        ),
    )

    # RN-084 / RN-085 / RN-116: Pontuação de reputação do estafeta (0.00 a 5.00)
    score_reputacao = models.DecimalField(
        max_digits=3,
        decimal_places=2,
        default=Decimal("5.00"),
        validators=[MinValueValidator(Decimal("0.00")), MaxValueValidator(Decimal("5.00"))],
        db_index=True,
        verbose_name=_("Score de Reputação"),
        help_text=_(
            "RN-084 / RN-085 / RN-116: Score de desempenho e avaliação do estafeta usado no motor de despacho."
        ),
    )

    # Secção 11 / RN-069 / RN-146 / RN-148: Saldo acumulado na carteira do estafeta em unidades mínimas inteiras
    # (BigIntegerField permite saldo negativo quando há numerário em mão por depositar ou danos imputados)
    saldo_carteira = models.BigIntegerField(
        default=0,
        verbose_name=_("Saldo da Carteira (Inteiro)"),
        help_text=_(
            "Secção 11 / RN-146 / RN-148: Saldo financeiro do estafeta em unidades mínimas inteiras (Cêntimos/Kwanza)."
        ),
    )

    class Meta:
        db_table = "logistics_estafeta"
        verbose_name = _("Estafeta")
        verbose_name_plural = _("Estafetas")
        indexes = [
            models.Index(
                fields=["status_onboarding", "is_online", "-score_reputacao"],
                name="idx_estafeta_despacho",
            ),
        ]

    def clean(self) -> None:
        """
        RN-082 e RN-083:
        1. Só estafetas com `status_onboarding == APROVADO` podem ficar `is_online=True`.
        2. Estar `is_online=True` exige `ultima_geolocalizacao` preenchida.
        3. Veículos motorizados (`MOTA`, `CARRO`) exigem `carta_conducao`.
        """
        super().clean()
        if self.tipo_veiculo in (self.TipoVeiculo.MOTA, self.TipoVeiculo.CARRO) and not self.carta_conducao:
            raise ValidationError(
                _("RN-082: A carta de condução é obrigatória para estafetas de Mota ou Carro.")
            )
        if self.is_online and self.status_onboarding != self.StatusOnboarding.APROVADO:
            raise ValidationError(
                _("RN-082: Apenas estafetas com onboarding 'Aprovado' podem ficar online.")
            )
        if self.is_online and self.ultima_geolocalizacao is None:
            raise ValidationError(
                _("RN-083: Para ficar online, o estafeta tem de partilhar uma geolocalização ativa.")
            )

    def __str__(self) -> str:
        online_str = "ONLINE" if getattr(self, "is_online", False) else "OFFLINE"
        try:
            user_nome = (
                self.utilizador.nome
                if (self.utilizador_id and self.utilizador and self.utilizador.nome)
                else (self.utilizador.telemovel if (self.utilizador_id and self.utilizador) else "Sem Utilizador")
            )
        except Exception:
            user_nome = "Sem Utilizador"
        tipo = getattr(self, "tipo_veiculo", "Veículo")
        return f"Estafeta {user_nome} [{tipo} | {online_str}]"


class Entrega(gis_models.Model):
    """
    Entidade 2: Registo logístico de Entrega associado 1-para-1 a um Pedido (Secção 6.9 e Secção 11).
    Gere o estado da corrida, distância, ETA, PIN de 4 dígitos e provas de entrega (foto e GPS PostGIS)
    conforme RN-093 e RN-095.
    """

    class EstadoEntrega(models.TextChoices):
        """Estados operacionais da entrega (Secção 11, RN-093, RN-095)."""

        PENDENTE = "PENDENTE", _("Pendente")
        ATRIBUIDO = "ATRIBUIDO", _("Atribuído")
        RECOLHIDO = "RECOLHIDO", _("Recolhido")
        EM_TRANSITO = "EM_TRANSITO", _("Em Trânsito")
        ENTREGUE = "ENTREGUE", _("Entregue")
        FALHOU = "FALHOU", _("Falhou")

    # Secção 11: Identificador único universal (UUID v4) da entrega
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Entrega"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) da entrega."),
    )

    # Secção 11: Relação 1-para-1 com o Pedido
    pedido = models.OneToOneField(
        "orders.Pedido",
        on_delete=models.PROTECT,
        related_name="entrega_logistica",
        verbose_name=_("Pedido"),
        help_text=_("Secção 11: Pedido correspondente a esta entrega (relação 1..1)."),
    )

    # Secção 11 / RN-085 / RN-088: Estafeta atribuído à entrega (Null enquanto aguarda despacho)
    estafeta = models.ForeignKey(
        Estafeta,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="entregas",
        verbose_name=_("Estafeta"),
        help_text=_("Secção 11 / RN-085: Estafeta atualmente atribuído para realizar a entrega."),
    )

    # Secção 11: Estado atual da entrega (Pendente, Atribuido, Recolhido, Em_Transito, Entregue, Falhou)
    estado_logistico = models.CharField(
        max_length=20,
        choices=EstadoEntrega.choices,
        default=EstadoEntrega.PENDENTE,
        db_index=True,
        verbose_name=_("Estado Logístico da Entrega"),
        help_text=_("Secção 11: Estado da corrida (Pendente, Atribuido, Recolhido, Em_Transito, Entregue, Falhou)."),
    )
    estado_entrega = models.CharField(
        max_length=20,
        choices=EstadoEntrega.choices,
        default=EstadoEntrega.PENDENTE,
        verbose_name=_("Estado da Entrega (Legado)"),
    )

    # Secção 11 / RN-051 / RN-090: Distância total estimada/percorrida em metros
    distancia_metros = models.PositiveIntegerField(
        default=0,
        verbose_name=_("Distância (Metros)"),
        help_text=_("Secção 11 / RN-090: Distância da rota de entrega expressa em metros."),
    )

    # Secção 11 / RN-029: Data e hora estimada de chegada (Estimated Time of Arrival)
    eta_estimada = models.DateTimeField(
        null=True,
        blank=True,
        db_index=True,
        verbose_name=_("ETA Estimada"),
        help_text=_("RN-029 / Secção 11: Timestamp estimado de chegada ao endereço do cliente."),
    )
    eta_timestamp = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name=_("ETA Timestamp (Legado)"),
    )

    # RN-095: Código PIN de 4 dígitos enviado ao cliente para confirmação presencial da entrega
    pin_entrega = models.CharField(
        max_length=4,
        default=gerar_pin_4_digitos,
        validators=[validador_pin_entrega],
        verbose_name=_("PIN de Entrega (4 Dígitos)"),
        help_text=_("RN-095: Código numérico de 4 dígitos exigido ao estafeta para validar a entrega."),
    )

    # RN-048 / RN-095 / RN-101: URL da fotografia de prova de entrega ou registo de incidente
    prova_foto_url = models.URLField(
        max_length=500,
        null=True,
        blank=True,
        default="",
        verbose_name=_("URL da Foto de Prova de Entrega"),
        help_text=_(
            "RN-048 / RN-095: Fotografia comprovativa da entrega (obrigatória em entregas sem contacto ou sem PIN)."
        ),
    )

    # RN-048 / RN-095: Coordenada geográfica PostGIS (SRID 4326) exata onde a entrega foi confirmada
    prova_geolocalizacao = gis_models.PointField(
        srid=4326,
        geography=True,
        spatial_index=True,
        null=True,
        blank=True,
        verbose_name=_("Prova de Geolocalização (PostGIS)"),
        help_text=_(
            "RN-048 / RN-095: Ponto geográfico PostGIS (SRID 4326) capturado na conclusão da entrega."
        ),
    )
    prova_gps = gis_models.PointField(
        srid=4326,
        geography=True,
        null=True,
        blank=True,
        verbose_name=_("Prova GPS (Legado)"),
    )

    # Timestamps operacionais das 5 etapas da corrida (RN-089, RN-093, RN-095, RN-096)
    chegada_loja_em = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name=_("Chegada à Loja Em"),
        help_text=_("RN-089: Timestamp em que o estafeta chegou ao restaurante para recolha."),
    )
    recolhido_em = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name=_("Recolhido na Loja Em"),
        help_text=_("RN-093: Timestamp em que o estafeta confirmou a recolha dos pacotes."),
    )
    chegada_cliente_em = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name=_("Chegada ao Cliente Em"),
        help_text=_("RN-096: Timestamp em que o estafeta chegou ao destino e iniciou a tolerância de 7 min."),
    )
    entregue_em = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name=_("Entregue Em"),
        help_text=_("RN-095: Timestamp de conclusão da entrega."),
    )

    # RN-089: Compensação adicional por tempo de espera > 10 min na loja (em cêntimos)
    bonus_espera_centimos = models.PositiveIntegerField(
        default=0,
        verbose_name=_("Bónus de Espera na Loja (Cêntimos)"),
        help_text=_("RN-089: Bónus creditado ao estafeta quando a espera no restaurante excede 10 minutos."),
    )

    # RN-098 / RN-101: Registo de incidente ou SOS em rota
    motivo_incidente = models.TextField(
        blank=True,
        default="",
        verbose_name=_("Motivo de Incidente / SOS"),
        help_text=_("RN-098 / RN-101: Descrição de eventual incidente técnico, avaria ou SOS reportado em rota."),
    )

    class Meta:
        db_table = "logistics_entrega"
        verbose_name = _("Entrega")
        verbose_name_plural = _("Entregas")
        indexes = [
            models.Index(fields=["estado_entrega", "eta_timestamp"], name="idx_entrega_estado_eta"),
            models.Index(fields=["estafeta", "estado_entrega"], name="idx_entrega_estafeta_estado"),
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        """Sincroniza os campos canónicos com os legados para garantir interoperabilidade total."""
        if not self.estado_logistico and self.estado_entrega:
            self.estado_logistico = self.estado_entrega
        else:
            self.estado_entrega = self.estado_logistico

        if not self.eta_estimada and self.eta_timestamp:
            self.eta_estimada = self.eta_timestamp
        else:
            self.eta_timestamp = self.eta_estimada

        if not self.prova_geolocalizacao and self.prova_gps:
            self.prova_geolocalizacao = self.prova_gps
        else:
            self.prova_gps = self.prova_geolocalizacao

        super().save(*args, **kwargs)

    def __str__(self) -> str:
        try:
            estafeta_nome = (
                self.estafeta.utilizador.nome
                if (self.estafeta_id and self.estafeta and self.estafeta.utilizador_id and self.estafeta.utilizador and self.estafeta.utilizador.nome)
                else (f"Estafeta #{str(self.estafeta_id)[:6]}" if self.estafeta_id else "Sem Estafeta")
            )
        except Exception:
            estafeta_nome = "Sem Estafeta"
        estado = getattr(self, "estado_logistico", "PENDENTE")
        ped_id = getattr(self, "pedido_id", "Sem Pedido")
        return f"Entrega {self.id} (Pedido {ped_id}) - {estado} [{estafeta_nome}]"
