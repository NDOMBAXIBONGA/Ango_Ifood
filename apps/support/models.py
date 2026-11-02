"""
Modelos de dados da aplicação 'support' (Tickets, Incidentes, Mediação de Disputas e Compensações).
Implementa a Secção 6.15, Secção 11 e as Regras de Negócio RN-106, RN-138 a RN-142:
- RN-106: Limite de compensação por perfil (Agente <= 3.000 Kz / 300.000 cêntimos; exige Supervisor se superior).
- RN-138: Abertura e categorização de disputas de clientes e parceiros.
- RN-139: Alerta de SLA de Suporte para incidentes de segurança alimentar e saúde pública (< 5 minutos).
- RN-140: Classificação de incidentes graves de segurança (reação alérgica, intoxicação alimentar).
- RN-141: Mediação e resolução fundamentada de disputas associadas a um pedido (Procedente_Cliente, Procedente_Parceiro, Improcedente).
- RN-142: Registo e auditoria completa imutável com identificação do autor da decisão e justificação.
"""
from __future__ import annotations

import uuid
from typing import Any

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _


class TicketDisputa(models.Model):
    """
    Entidade: Representa um Ticket de Suporte / Disputa sobre um Pedido (Secção 6.15, Secção 11,
    RN-106, RN-138 a RN-142).
    Garante auditoria estritamente imutável pós-resolução.
    """

    class EstadoTicket(models.TextChoices):
        """Estados do fluxo de tratamento de uma disputa (Secção 11, RN-141)."""

        ABERTO = "ABERTO", _("Aberto")
        EM_ANALISE = "EM_ANALISE", _("Em Análise")
        RESOLVIDO = "RESOLVIDO", _("Resolvido")

    class TipoIncidente(models.TextChoices):
        """Categorias oficiais de incidentes e disputas (RN-138, RN-140)."""

        DISPUTA_COMERCIAL = "DISPUTA_COMERCIAL", _("Disputa Comercial / Contratual")
        ITEM_FALTOU = "ITEM_FALTOU", _("Item em Falta / Incorreto")
        DERRAME_DANOS = "DERRAME_DANOS", _("Derrame ou Danos na Embalagem")
        ATRASO_GRAVE = "ATRASO_GRAVE", _("Atraso Excessivo na Entrega")
        REACAO_ALERGICA = "REACAO_ALERGICA", _("Reação Alérgica Grave (RN-140)")
        INTOXICACAO_ALIMENTAR = "INTOXICACAO_ALIMENTAR", _("Intoxicação Alimentar (RN-140)")
        OUTRO = "OUTRO", _("Outro Incidente Operacional")

    class PrioridadeTicket(models.TextChoices):
        """Prioridades com impacto direto em SLAs operacionais (RN-139)."""

        BAIXA = "BAIXA", _("Baixa")
        MEDIA = "MEDIA", _("Média")
        ALTA = "ALTA", _("Alta (SLA < 5 min - RN-139)")
        CRITICA = "CRITICA", _("Crítica (Segurança e Saúde Pública - RN-140)")

    class DecisaoDisputa(models.TextChoices):
        """Choices formais de resolução de disputas (RN-141)."""

        PROCEDENTE_CLIENTE = "Procedente_Cliente", _("Procedente_Cliente (A favor do Cliente)")
        PROCEDENTE_PARCEIRO = "Procedente_Parceiro", _("Procedente_Parceiro (A favor do Parceiro)")
        IMPROCEDENTE = "Improcedente", _("Improcedente (Rejeitada)")

    # Secção 11: Identificador único universal (UUID v4) do ticket/disputa
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Ticket / Disputa"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do ticket de disputa."),
    )

    # Secção 11 / RN-141: Pedido alvo da reclamação ou disputa
    pedido = models.ForeignKey(
        "orders.Pedido",
        on_delete=models.PROTECT,
        related_name="tickets_disputa",
        verbose_name=_("Pedido"),
        help_text=_("Secção 11 / RN-141: Pedido ao qual esta disputa ou incidente diz respeito."),
    )

    # RN-138 / RN-140: Categoria do incidente
    tipo_incidente = models.CharField(
        max_length=30,
        choices=TipoIncidente.choices,
        default=TipoIncidente.DISPUTA_COMERCIAL,
        db_index=True,
        verbose_name=_("Tipo de Incidente"),
        help_text=_("RN-138 / RN-140: Classificação do incidente ou reclamação."),
    )

    # RN-139: Nível de prioridade para monitorização de SLAs de suporte
    prioridade = models.CharField(
        max_length=15,
        choices=PrioridadeTicket.choices,
        default=PrioridadeTicket.MEDIA,
        db_index=True,
        verbose_name=_("Prioridade"),
        help_text=_("RN-139: Nível de prioridade com impacto no SLA de escalamento imediato."),
    )

    # RN-138 / RN-141: Motivo detalhado da abertura da disputa
    motivo = models.TextField(
        verbose_name=_("Motivo da Disputa"),
        help_text=_("RN-141: Descrição detalhada do motivo que originou o ticket ou disputa."),
    )

    # Secção 11 / RN-141: Estado atual do ticket (Aberto, Em_Analise, Resolvido)
    estado = models.CharField(
        max_length=20,
        choices=EstadoTicket.choices,
        default=EstadoTicket.ABERTO,
        db_index=True,
        verbose_name=_("Estado da Disputa"),
        help_text=_("Secção 11 / RN-141: Estado atual do ticket (Aberto, Em_Analise, Resolvido)."),
    )

    # RN-141: Decisão formal proferida pelo suporte
    decisao = models.CharField(
        max_length=30,
        choices=DecisaoDisputa.choices,
        blank=True,
        default="",
        db_index=True,
        verbose_name=_("Decisão"),
        help_text=_("RN-141: Decisão da mediação (Procedente_Cliente, Procedente_Parceiro, Improcedente)."),
    )

    # RN-141 / RN-142: Fundamentação e justificação técnica da decisão tomada
    motivo_justificacao = models.TextField(
        blank=True,
        default="",
        verbose_name=_("Justificação Fundamentada"),
        help_text=_(
            "RN-141 / RN-142: Justificação fundamentada da decisão após análise de evidências, logs e GPS."
        ),
    )

    # RN-059 / RN-106 / RN-141: Valor de compensação ou crédito concedido em unidades mínimas inteiras (Cêntimos)
    compensacao_valor = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Valor de Compensação (Inteiro)"),
        help_text=_(
            "RN-059 / RN-106 / RN-141: Montante de compensação ou reembolso em unidades mínimas inteiras (Cêntimos/Kz)."
        ),
    )

    # RN-106 / RN-141 / RN-142: Agente de suporte que registou a decisão
    autor_decisao = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name="disputas_decididas",
        verbose_name=_("Autor da Decisão"),
        help_text=_(
            "RN-141 / RN-142: Operador/Agente de Suporte responsável pelo registo da decisão."
        ),
    )

    # RN-106: Supervisor que aprovou a compensação caso o valor ultrapasse o teto do agente (3.000 Kz)
    supervisor_aprovador = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name="compensacoes_aprovadas",
        verbose_name=_("Supervisor Aprovador"),
        help_text=_(
            "RN-106: Supervisor que autorizou a compensação superior a 3.000 Kz (300.000 cêntimos)."
        ),
    )

    # RN-139: Flag indicando se o alerta de SLA < 5 minutos já foi disparado
    is_alerta_escalado = models.BooleanField(
        default=False,
        verbose_name=_("Alerta Escalado"),
        help_text=_("RN-139: Indica se a tarefa Celery de escalamento de SLA já foi emitida."),
    )

    data_criacao = models.DateTimeField(
        auto_now_add=True,
        db_index=True,
        verbose_name=_("Data de Criação"),
    )
    data_atualizacao = models.DateTimeField(
        auto_now=True,
        verbose_name=_("Data de Atualização"),
    )
    data_resolucao = models.DateTimeField(
        null=True,
        blank=True,
        db_index=True,
        verbose_name=_("Data de Resolução"),
    )

    class Meta:
        db_table = "support_ticket_disputa"
        verbose_name = _("Ticket / Disputa")
        verbose_name_plural = _("Tickets / Disputas")
        ordering = ["-data_criacao"]
        indexes = [
            models.Index(fields=["pedido", "estado"], name="idx_disputa_ped_est"),
            models.Index(fields=["tipo_incidente", "prioridade"], name="idx_disputa_tp_prio"),
            models.Index(fields=["estado", "-data_criacao"], name="idx_disputa_est_dt"),
        ]

    def clean(self) -> None:
        """
        RN-106, RN-141 e RN-142: Validações de integridade do ticket.
        """
        super().clean()
        if self.estado == self.EstadoTicket.RESOLVIDO:
            if not self.decisao:
                raise ValidationError(
                    _("RN-141: Um ticket resolvido exige a seleção de uma 'decisao' válida.")
                )
            if not self.motivo_justificacao or len(self.motivo_justificacao.strip()) < 10:
                raise ValidationError(
                    _("RN-142: É obrigatório fornecer uma 'motivo_justificacao' detalhada (mínimo 10 caracteres).")
                )
            if self.autor_decisao is None:
                raise ValidationError(
                    _("RN-142: Todo o ticket resolvido exige a identificação obrigatória do 'autor_decisao'.")
                )

    def save(self, *args: Any, **kwargs: Any) -> None:
        """
        RN-142: Imutabilidade pós-resolução.
        Uma vez proferida e persistida a decisão, o registo fica congelado contra edições arbitrárias.
        """
        if self.pk and not self._state.adding:
            db_instance = TicketDisputa.objects.filter(pk=self.pk).first()
            if db_instance and db_instance.estado == self.EstadoTicket.RESOLVIDO:
                # Impede alteração de campos críticos da decisão
                if (
                    db_instance.decisao != self.decisao
                    or db_instance.compensacao_valor != self.compensacao_valor
                    or db_instance.motivo_justificacao != self.motivo_justificacao
                ):
                    raise ValidationError(
                        _(
                            "RN-142 (Imutabilidade de Auditoria): Decisões administrativas já resolvidas "
                            "são estritamente imutáveis e não podem ser editadas."
                        )
                    )

        if self.estado == self.EstadoTicket.RESOLVIDO and not self.data_resolucao:
            self.data_resolucao = timezone.now()

        self.full_clean()
        super().save(*args, **kwargs)

    def delete(self, *args: Any, **kwargs: Any) -> tuple[int, dict[str, int]]:
        """
        RN-142: Proíbe a eliminação física de tickets de suporte para auditoria regulamentar.
        """
        raise ValidationError(
            _("RN-142: É expressamente proibido eliminar registos de suporte e disputas.")
        )

    def __str__(self) -> str:
        return (
            f"Ticket {self.id} | Pedido {self.pedido_id} | "
            f"{self.tipo_incidente} ({self.prioridade}) | {self.estado} [{self.decisao}]"
        )


class Parametro(models.Model):
    """
    Entidade de Governação e Configuração Operacional do Sistema (Secção 8 e Secção 11).
    Armazena todos os parâmetros configuráveis de SLAs, timeouts e limites da plataforma.
    Atributos principais da Secção 11: chave, valor, âmbito, vigência, versão, autor.
    Consumido transversalmente por todos os módulos do ecossistema.
    """

    class AmbitoParametro(models.TextChoices):
        GLOBAL = "Global", _("Global")
        PAIS = "Pais", _("País")
        CIDADE = "Cidade", _("Cidade")
        ZONA = "Zona", _("Zona Logística")
        PARCEIRO = "Parceiro", _("Parceiro")
        LOJA = "Loja", _("Loja")
        CONTRATO = "Contrato", _("Contrato")
        PERFIL = "Perfil", _("Perfil / Agente")

    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Parâmetro"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do parâmetro."),
    )
    chave = models.CharField(
        max_length=100,
        unique=True,
        db_index=True,
        verbose_name=_("Chave do Parâmetro"),
        help_text=_("Identificador canónico único do parâmetro (ex.: 'JANELA_CANCELAMENTO_GRATUITO')."),
    )
    nome = models.CharField(
        max_length=150,
        verbose_name=_("Nome do Parâmetro"),
        help_text=_("Designação amigável descrita na tabela da Secção 8 (ex.: 'Janela de cancelamento gratuito')."),
    )
    valor = models.CharField(
        max_length=100,
        verbose_name=_("Valor Configurado"),
        help_text=_("Valor predefinido e formatado conforme a Secção 8 (ex.: '60s', '3 min', '30s', '3 km', '2000 Kz', '5%')."),
    )
    valor_numerico = models.DecimalField(
        max_digits=14,
        decimal_places=2,
        null=True,
        blank=True,
        verbose_name=_("Valor Numérico Base"),
        help_text=_("Representação numérica padrão para operações lógicas diretas (segundos, metros, cêntimos, percentagem)."),
    )
    unidade = models.CharField(
        max_length=30,
        blank=True,
        default="",
        verbose_name=_("Unidade de Medida"),
        help_text=_("Unidade da grandeza (ex.: 'segundos', 'minutos', 'km', 'Kz', '%')."),
    )
    ambito = models.CharField(
        max_length=30,
        choices=AmbitoParametro.choices,
        default=AmbitoParametro.GLOBAL,
        db_index=True,
        verbose_name=_("Âmbito de Aplicação"),
        help_text=_("Secção 8 / Secção 11: Escopo do parâmetro (Global, Parceiro, Zona, Loja, Pais, etc.)."),
    )
    regra_associada = models.CharField(
        max_length=30,
        blank=True,
        default="",
        db_index=True,
        verbose_name=_("Regra de Negócio Associada"),
        help_text=_("Referência à regra da especificação funcional (ex.: 'RN-102', 'RN-075', 'RN-086')."),
    )
    descricao = models.TextField(
        blank=True,
        default="",
        verbose_name=_("Descrição e Notas Operacionais"),
        help_text=_("Explicação do impacto operacional e de negócio deste parâmetro."),
    )
    vigencia_inicio = models.DateTimeField(
        default=timezone.now,
        db_index=True,
        verbose_name=_("Início de Vigência"),
        help_text=_("Secção 8 / Secção 11: Data e hora a partir da qual o parâmetro entra em vigor."),
    )
    vigencia_fim = models.DateTimeField(
        null=True,
        blank=True,
        verbose_name=_("Fim de Vigência"),
        help_text=_("Secção 8 / Secção 11: Data limite de validade do parâmetro (opcional)."),
    )
    versao = models.PositiveIntegerField(
        default=1,
        verbose_name=_("Versão do Parâmetro"),
        help_text=_("Secção 8 / Secção 11: Número incremental de versionamento para auditoria."),
    )
    autor = models.CharField(
        max_length=150,
        default="DevOps / Sistema",
        verbose_name=_("Autor da Configuração"),
        help_text=_("Secção 8 / Secção 11: Responsável pela definição ou alteração do parâmetro."),
    )
    data_criacao = models.DateTimeField(
        auto_now_add=True,
        verbose_name=_("Data de Criação"),
    )
    data_atualizacao = models.DateTimeField(
        auto_now=True,
        verbose_name=_("Data de Atualização"),
    )

    class Meta:
        db_table = "support_parametro"
        verbose_name = _("Parâmetro de Sistema")
        verbose_name_plural = _("Parâmetros de Sistema")
        ordering = ["ambito", "chave"]
        indexes = [
            models.Index(fields=["chave", "vigencia_inicio"], name="idx_param_chave_vigencia"),
            models.Index(fields=["ambito", "chave"], name="idx_param_ambito_chave"),
        ]

    def __str__(self) -> str:
        return f"[{self.ambito}] {self.chave} = {self.valor} ({self.regra_associada})"
