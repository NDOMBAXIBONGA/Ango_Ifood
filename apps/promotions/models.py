"""
Modelos de dados da aplicação 'promotions' (Cupões de Desconto e Campanhas Promocionais).
Implementa a Secção 11 e as Regras de Negócio RN-055, RN-056 e RN-059:
- RN-055: Definição explícita de quem financia o desconto (Plataforma, Parceiro ou Partilhado)
  para cálculo correto da comissão e liquidação.
- RN-056: Regras de cupão (código único, tipo fixo ou percentagem, janela de validade,
  montante mínimo de pedido, limite global e limite por utilizador).
- RN-059: Valores monetários armazenados em unidades mínimas inteiras.
"""
import uuid

from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _


class CupaoDesconto(models.Model):
    """
    Entidade 3: Representa um Cupão de Desconto promocional (Secção 11, RN-055, RN-056, RN-059).
    """

    class TipoDesconto(models.TextChoices):
        """Tipo de cálculo do benefício do cupão (RN-056)."""

        FIXO = "FIXO", _("Valor Fixo")
        PERCENTAGEM = "PERCENTAGEM", _("Percentagem")

    class FinanciadorCupao(models.TextChoices):
        """Entidade que suporta financeiramente o custo do desconto (RN-055)."""

        PLATAFORMA = "PLATAFORMA", _("Plataforma")
        PARCEIRO = "PARCEIRO", _("Parceiro")
        PARTILHADO = "PARTILHADO", _("Partilhado")

    # Secção 11: Identificador único universal (UUID v4) do cupão
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Cupão"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do cupão de desconto."),
    )

    # RN-056: Código alfanumérico único introduzido pelo cliente no checkout
    codigo = models.CharField(
        max_length=50,
        unique=True,
        db_index=True,
        verbose_name=_("Código do Cupão"),
        help_text=_("RN-056: Código promocional único (ex.: 'BEMVINDO1000')."),
    )

    # RN-056: Natureza do desconto (Fixo em unidades mínimas ou Percentagem)
    tipo_desconto = models.CharField(
        max_length=15,
        choices=TipoDesconto.choices,
        verbose_name=_("Tipo de Desconto"),
        help_text=_("RN-056: Define se o desconto é de valor Fixo ou Percentagem."),
    )

    # RN-056 / RN-059: Valor do desconto (inteiro: unidades mínimas se Fixo; 1 a 100 se Percentagem)
    valor = models.PositiveBigIntegerField(
        validators=[MinValueValidator(1)],
        verbose_name=_("Valor do Desconto (Inteiro)"),
        help_text=_(
            "RN-056 / RN-059: Valor inteiro do desconto (em unidades mínimas se Fixo, ou de 1 a 100 se Percentagem)."
        ),
    )

    # RN-056: Data/hora de início de vigência do cupão
    validade_inicio = models.DateTimeField(
        db_index=True,
        verbose_name=_("Início de Validade"),
        help_text=_("RN-056: Data e hora a partir da qual o cupão pode ser utilizado."),
    )

    # RN-056: Data/hora limite de expiração do cupão
    validade_fim = models.DateTimeField(
        db_index=True,
        verbose_name=_("Fim de Validade"),
        help_text=_("RN-056: Data e hora em que o cupão expira."),
    )

    # RN-056 / RN-059: Subtotal mínimo exigido no carrinho para aplicar o cupão (inteiro)
    montante_minimo_pedido = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Montante Mínimo do Pedido (Inteiro)"),
        help_text=_(
            "RN-056 / RN-059: Subtotal mínimo do pedido (em unidades mínimas inteiras) para elegibilidade do cupão."
        ),
    )

    # RN-056: Limite total de utilizações em toda a plataforma (controlo de orçamento da campanha)
    limite_global_uso = models.PositiveIntegerField(
        default=1000,
        validators=[MinValueValidator(1)],
        verbose_name=_("Limite Global de Uso"),
        help_text=_("RN-056: Número máximo total de vezes que este cupão pode ser resgatado na plataforma."),
    )

    # RN-056 / RN-132: Limite máximo de utilizações pelo mesmo utilizador
    limite_por_utilizador = models.PositiveSmallIntegerField(
        default=1,
        validators=[MinValueValidator(1)],
        verbose_name=_("Limite de Uso por Utilizador"),
        help_text=_("RN-056: Número máximo de vezes que um mesmo cliente pode utilizar este cupão."),
    )

    # RN-055 / RN-056: Quem assume o custo financeiro do desconto na liquidação
    financiador = models.CharField(
        max_length=15,
        choices=FinanciadorCupao.choices,
        default=FinanciadorCupao.PLATAFORMA,
        verbose_name=_("Financiador do Desconto"),
        help_text=_(
            "RN-055 / RN-056: Entidade que financia o desconto (Plataforma, Parceiro, Partilhado)."
        ),
    )

    class Meta:
        db_table = "promotions_cupao_desconto"
        verbose_name = _("Cupão de Desconto")
        verbose_name_plural = _("Cupões de Desconto")
        ordering = ["-validade_fim", "codigo"]
        indexes = [
            models.Index(fields=["codigo", "validade_inicio", "validade_fim"], name="idx_cupao_codigo_validade"),
        ]

    def clean(self) -> None:
        """
        RN-056:
        1. Garante que `validade_fim` é posterior a `validade_inicio`.
        2. Se `tipo_desconto == PERCENTAGEM`, garante que `valor` está entre 1 e 100.
        3. Normaliza o `codigo` em maiúsculas sem espaços laterais.
        """
        super().clean()
        if self.codigo:
            self.codigo = self.codigo.strip().upper()
        if self.validade_inicio and self.validade_fim and self.validade_fim <= self.validade_inicio:
            raise ValidationError(
                _("RN-056: A data de 'validade_fim' tem de ser posterior a 'validade_inicio'.")
            )
        if self.tipo_desconto == self.TipoDesconto.PERCENTAGEM and (self.valor < 1 or self.valor > 100):
            raise ValidationError(
                _("RN-056: Para cupões do tipo Percentagem, o 'valor' deve situar-se entre 1 e 100.")
            )

    @property
    def esta_dentro_da_validade(self) -> bool:
        """RN-056: Verifica se o momento atual se encontra dentro da janela de validade do cupão."""
        agora = timezone.now()
        return self.validade_inicio <= agora <= self.validade_fim

    def __str__(self) -> str:
        sufixo = "%" if self.tipo_desconto == self.TipoDesconto.PERCENTAGEM else " (unid. mín.)"
        return f"Cupão {self.codigo} (-{self.valor}{sufixo} | Financiador: {self.financiador})"
