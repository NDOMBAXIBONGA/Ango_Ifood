"""
Camada de Modelos para 'Eventos de Pedido' e 'Livro Razão' (Ledger).
Aplicação: 'finance'
Arquitetura: Padrões Transacionais, Auditoria Financeira e Partidas Dobradas.

Implementa rigorosamente:
- Secção 5.2: Princípios da máquina de estados e imutabilidade inegociável do histórico de eventos.
- Secção 7.3: Princípios do Livro Razão Ledger de Dupla Entrada Contábil (partidas dobradas, soma líquida zero).
- Secção 11: Modelo de dados conceptual com chaves primárias UUID v4 e integridade referencial protegida.
- Secção 12.1: Catálogo canónico de eventos padronizados para webhooks, eventos de domínio e mensageria.
"""
from __future__ import annotations

import logging
import uuid
from typing import Any

from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.db.models import Sum
from django.utils.translation import gettext_lazy as _

logger = logging.getLogger(__name__)


class EventoPedido(models.Model):
    """
    Entidade: EventoPedido
    Registo histórico e de auditoria estritamente imutável das transições de estado,
    ações de atores e eventos de domínio de um Pedido (Secções 5.2, 11 e 12.1).

    Garantia de Imutabilidade:
    - Não permite atualizações (UPDATE): qualquer tentativa de alterar um registo existente
      levanta django.core.exceptions.ValidationError.
    - Não permite eliminações físicas (DELETE): registos não podem ser apagados do banco.
    """

    class TipoEvento(models.TextChoices):
        """
        Catálogo oficial de eventos padronizados associados ao ciclo de vida do pedido
        e respetivos subsistemas (Secção 12.1 da especificação técnica).
        """

        # Eventos do Ciclo de Vida do Pedido (order.*)
        ORDER_CREATED = "order.created", _("order.created (Pedido Criado no Checkout)")
        ORDER_PAID = "order.paid", _("order.paid (Pagamento Autorizado/Capturado)")
        ORDER_SENT_TO_PARTNER = "order.sent_to_partner", _("order.sent_to_partner (Enviado ao Parceiro)")
        ORDER_ACCEPTED = "order.accepted", _("order.accepted (Aceite pelo Parceiro)")
        ORDER_REJECTED = "order.rejected", _("order.rejected (Rejeitado pelo Parceiro/Timeout)")
        ORDER_IN_PREPARATION = "order.in_preparation", _("order.in_preparation (Em Preparação na Cozinha)")
        ORDER_READY = "order.ready", _("order.ready (Pronto para Recolha pelo Estafeta)")
        ORDER_PICKED_UP = "order.picked_up", _("order.picked_up (Recolhido pelo Estafeta)")
        ORDER_IN_TRANSIT = "order.in_transit", _("order.in_transit (Em Trânsito para o Cliente)")
        ORDER_DELIVERED = "order.delivered", _("order.delivered (Entregue com PIN Validado)")
        ORDER_DELIVERY_FAILED = "order.delivery_failed", _("order.delivery_failed (Falha de Entrega)")
        ORDER_COMPLETED = "order.completed", _("order.completed (Concluído e Liquidado)")
        ORDER_CANCELLED = "order.cancelled", _("order.cancelled (Pedido Cancelado)")
        ORDER_REFUNDED = "order.refunded", _("order.refunded (Pedido Reembolsado)")

        # Eventos do Subsistema Logístico (delivery.*)
        DELIVERY_OFFERED = "delivery.offered", _("delivery.offered (Corrida Oferecida a Estafeta)")
        DELIVERY_ASSIGNED = "delivery.assigned", _("delivery.assigned (Estafeta Aceitou Corrida)")
        DELIVERY_LOCATION_UPDATED = "delivery.location_updated", _("delivery.location_updated (GPS Atualizado)")
        DELIVERY_FAILED = "delivery.failed", _("delivery.failed (Falha Operacional do Estafeta)")

        # Eventos do Subsistema de Pagamentos (payment.*)
        PAYMENT_AUTHORIZED = "payment.authorized", _("payment.authorized (Pagamento Autorizado no Gateway)")
        PAYMENT_CAPTURED = "payment.captured", _("payment.captured (Pagamento Capturado no Gateway)")
        PAYMENT_REFUNDED = "payment.refunded", _("payment.refunded (Pagamento Estornado ao Cliente)")
        PAYMENT_CHARGEBACK = "payment.chargeback", _("payment.chargeback (Notificação de Chargeback)")

    # Secção 11: Chave primária UUID v4 universal
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Evento"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do evento imutável."),
    )

    # Secção 11: Chave estrangeira para o Pedido associado
    pedido = models.ForeignKey(
        "orders.Pedido",
        on_delete=models.PROTECT,
        related_name="eventos",
        editable=False,
        verbose_name=_("Pedido"),
        help_text=_("Secção 11: Pedido associado a este evento de auditoria."),
    )

    # Secção 12.1: Tipo de evento padronizado
    tipo_evento = models.CharField(
        max_length=64,
        choices=TipoEvento.choices,
        editable=False,
        db_index=True,
        verbose_name=_("Tipo de Evento"),
        help_text=_("Secção 12.1: Identificador canónico do evento de domínio."),
    )

    # Secção 5.2: Identificação do autor ou ator da transição
    autor = models.CharField(
        max_length=150,
        editable=False,
        verbose_name=_("Autor do Evento"),
        help_text=_(
            "Secção 5.2: Identificador do ator que disparou o evento (ex: 'sistema', "
            "'parceiro_uuid', 'cliente_uuid', 'estafeta_uuid')."
        ),
    )

    # Secção 5.2 / Secção 11: Carimbo temporal imutável
    timestamp = models.DateTimeField(
        auto_now_add=True,
        editable=False,
        db_index=True,
        verbose_name=_("Timestamp do Evento"),
        help_text=_("Secção 5.2: Carimbo temporal imutável do registo do evento."),
    )

    # Secção 11: Payload JSON para contexto histórico
    dados_adicionais = models.JSONField(
        default=dict,
        blank=True,
        editable=False,
        verbose_name=_("Dados Adicionais (JSON)"),
        help_text=_("Secção 11: Payload histórico detalhado com metadados do evento."),
    )

    class Meta:
        db_table = "finance_evento_pedido"
        verbose_name = _("Evento de Pedido")
        verbose_name_plural = _("Eventos de Pedido")
        ordering = ["timestamp"]
        indexes = [
            models.Index(fields=["pedido", "timestamp"], name="idx_fin_ev_ped_ts"),
            models.Index(fields=["tipo_evento", "timestamp"], name="idx_fin_ev_tp_ts"),
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        """
        Sobrescrita do método save(*args, **kwargs).
        Garante a restrição de imutabilidade intransponível: se a instância já possuir
        chave primária persistida na base de dados, bloqueia a operação e lança
        explicitamente ValidationError.
        """
        if not self._state.adding or EventoPedido.objects.filter(pk=self.pk).exists():
            raise ValidationError("Operação Inválida: Registos de eventos de pedido são imutáveis.")
        super().save(*args, **kwargs)

    def delete(self, *args: Any, **kwargs: Any) -> tuple[int, dict[str, int]]:
        """
        Sobrescrita do método delete(*args, **kwargs).
        Proíbe a eliminação física de qualquer registo de auditoria de eventos.
        """
        raise ValidationError("Secção 5.2: É expressamente proibido eliminar eventos de pedido.")

    def __str__(self) -> str:
        return f"[{self.timestamp.isoformat() if self.timestamp else 'NOVO'}] {self.tipo_evento} por {self.autor} (Pedido {self.pedido_id})"


class LivroRazaoLedger(models.Model):
    """
    Entidade: LivroRazaoLedger
    Lançamento contabilístico imutável do Livro Razão (Ledger) de dupla entrada
    (Secção 7.3, Secção 11 e RN-150).

    Princípios Fundamentais:
    - Dupla Entrada Contábil: Cada registo especifica a 'conta_origem' e a 'conta_destino'
      com valores de 'debito' e 'credito' estritamente positivos e rigorosamente iguais entre si
      (soma algébrica debito - credito = 0).
    - Contas Distintas: 'conta_origem' tem de ser diferente de 'conta_destino'.
    - Imutabilidade Contábil: Lançamentos nunca são editados nem apagados; correções são efetuadas
      exclusivamente através de novos lançamentos de estorno/compensação.
    - Auditoria de Equilíbrio: O somatório total de débitos deve igualar o somatório total de créditos
      para qualquer pedido.
    """

    class ContaContabil(models.TextChoices):
        """
        Escolhas exatas das contas contabilísticas de acordo com a Secção 7.3:
        Cliente, Parceiro, Estafeta, Plataforma, Gateway, Reembolsos, Retencoes, Promocoes.
        """

        CLIENTE = "Cliente", _("Cliente (Contas a Receber / Pago)")
        PARCEIRO = "Parceiro", _("Parceiro (Contas a Pagar / Repasse)")
        ESTAFETA = "Estafeta", _("Estafeta (Contas a Pagar / Frete)")
        PLATAFORMA = "Plataforma", _("Plataforma (Receita / Take Rate)")
        GATEWAY = "Gateway", _("Gateway (Custos de Processamento)")
        REEMBOLSOS = "Reembolsos", _("Reembolsos (Estornos)")
        RETENCOES = "Retencoes", _("Retenções (Cauções / Garantias)")
        PROMOCOES = "Promocoes", _("Promoções (Despesas com Subsídios e Descontos)")

    # Secção 11: Identificador único UUID v4
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Lançamento"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do lançamento no ledger."),
    )

    # Secção 7.3: Conta de Origem (Debitada)
    conta_origem = models.CharField(
        max_length=30,
        choices=ContaContabil.choices,
        editable=False,
        db_index=True,
        verbose_name=_("Conta de Origem"),
        help_text=_("Secção 7.3: Conta debitada no lançamento de dupla entrada."),
    )

    # Secção 7.3: Conta de Destino (Creditada)
    conta_destino = models.CharField(
        max_length=30,
        choices=ContaContabil.choices,
        editable=False,
        db_index=True,
        verbose_name=_("Conta de Destino"),
        help_text=_("Secção 7.3: Conta creditada no lançamento de dupla entrada."),
    )

    # Secção 7.3: Débito em unidades mínimas inteiras (inteiro estritamente positivo)
    debito = models.IntegerField(
        validators=[MinValueValidator(1)],
        editable=False,
        verbose_name=_("Valor a Débito (Inteiro)"),
        help_text=_("Secção 7.3: Montante a débito em unidades mínimas inteiras (positivo)."),
    )

    # Secção 7.3: Crédito em unidades mínimas inteiras (inteiro estritamente positivo)
    credito = models.IntegerField(
        validators=[MinValueValidator(1)],
        editable=False,
        verbose_name=_("Valor a Crédito (Inteiro)"),
        help_text=_("Secção 7.3: Montante a crédito em unidades mínimas inteiras (positivo)."),
    )

    # Secção 7.3 / Secção 11: Pedido que originou o lançamento
    referencia_pedido = models.ForeignKey(
        "orders.Pedido",
        on_delete=models.PROTECT,
        related_name="lancamentos_ledger",
        editable=False,
        verbose_name=_("Referência do Pedido"),
        help_text=_("Secção 7.3: Pedido associado a este lançamento financeiro."),
    )

    # Secção 7.3 / Secção 11: Carimbo temporal imutável
    timestamp = models.DateTimeField(
        auto_now_add=True,
        editable=False,
        db_index=True,
        verbose_name=_("Data/Hora do Lançamento"),
        help_text=_("Secção 7.3: Carimbo temporal imutável do lançamento no livro razão."),
    )

    class Meta:
        db_table = "finance_livro_razao_ledger"
        verbose_name = _("Lançamento do Livro Razão (Ledger)")
        verbose_name_plural = _("Lançamentos do Livro Razão (Ledger)")
        ordering = ["timestamp"]
        indexes = [
            models.Index(fields=["referencia_pedido", "timestamp"], name="idx_fin_led_ped_ts"),
            models.Index(fields=["conta_origem", "timestamp"], name="idx_fin_led_org_ts"),
            models.Index(fields=["conta_destino", "timestamp"], name="idx_fin_led_dst_ts"),
        ]

    def clean(self) -> None:
        """
        Validação do princípio das partidas dobradas e regras da Secção 7.3:
        1. 'debito' e 'credito' têm de ser inteiros estritamente positivos.
        2. 'debito' tem de ser exatamente igual a 'credito' (debito == credito).
        3. A soma algébrica líquida da transação é zero (debito - credito == 0).
        4. 'conta_origem' e 'conta_destino' têm de ser distintas.
        """
        super().clean()

        if self.debito is None or self.credito is None:
            raise ValidationError(
                _("Secção 7.3: Os campos 'debito' e 'credito' são obrigatórios.")
            )

        if self.debito <= 0 or self.credito <= 0:
            raise ValidationError(
                _("Secção 7.3: Os valores de débito e crédito têm de ser inteiros estritamente positivos (maiores que zero).")
            )

        if self.debito != self.credito:
            raise ValidationError(
                _(
                    f"Secção 7.3 (Violação de Dupla Entrada Contábil): O valor a débito ({self.debito}) tem de ser "
                    f"rigorosamente igual ao valor a crédito ({self.credito}). Diferença: {abs(self.debito - self.credito)}."
                )
            )

        # Validação explícita da soma algébrica zero (Princípio de Partidas Dobradas)
        if (self.debito - self.credito) != 0:
            raise ValidationError(
                _("Secção 7.3: A soma algébrica líquida de débito e crédito tem de ser exatamente zero.")
            )

        if self.conta_origem and self.conta_destino and self.conta_origem == self.conta_destino:
            raise ValidationError(
                _("Secção 7.3: A conta de origem e a conta de destino não podem ser a mesma conta.")
            )

    def save(self, *args: Any, **kwargs: Any) -> None:
        """
        Sobrescrita do método save(*args, **kwargs).
        - Impede qualquer atualização de lançamentos existentes na base de dados (imutabilidade estrita).
        - Executa full_clean() antes da persistência para garantir validação de partidas dobradas.
        """
        if not self._state.adding or LivroRazaoLedger.objects.filter(pk=self.pk).exists():
            raise ValidationError(
                _(
                    "Secção 7.3 (Violação de Imutabilidade do Ledger): Lançamentos no livro razão são "
                    "estritamente imutáveis e não podem ser editados após a criação. Eventuais correções "
                    "devem ser efetuadas exclusivamente através de novos lançamentos de estorno/compensação."
                )
            )

        self.full_clean()
        super().save(*args, **kwargs)

    def delete(self, *args: Any, **kwargs: Any) -> tuple[int, dict[str, int]]:
        """
        Sobrescrita do método delete(*args, **kwargs).
        Proíbe categoricamente a eliminação física de registos do Livro Razão.
        """
        raise ValidationError(
            _(
                "Secção 7.3 (Violação de Imutabilidade do Ledger): É expressamente proibido eliminar "
                "registos do livro razão."
            )
        )

    @classmethod
    def validar_equilibrio_pedido(
        cls, pedido_id: uuid.UUID | str, raise_exception: bool = False
    ) -> bool:
        """
        Consulta o ledger para auditar que o somatório total de débitos é rigorosamente
        igual ao somatório total de créditos para um determinado pedido (Secção 7.3).

        Retorna True se equilibrado, False caso exista discrepância.
        Se raise_exception=True, levanta ValidationError caso haja discrepância contábil.
        Emite alerta crítico no logger em caso de inconsistência detectada.
        """
        agregado = cls.objects.filter(referencia_pedido_id=pedido_id).aggregate(
            total_debito=Sum("debito", default=0),
            total_credito=Sum("credito", default=0),
        )

        total_debito = int(agregado["total_debito"] or 0)
        total_credito = int(agregado["total_credito"] or 0)

        if total_debito != total_credito:
            diferenca = abs(total_debito - total_credito)
            mensagem_alerta = (
                f"ALERTA CRÍTICO DE AUDITORIA CONTÁBIL (Secção 7.3): Discrepância detetada no Pedido {pedido_id}! "
                f"Total de Débitos ({total_debito}) != Total de Créditos ({total_credito}). "
                f"Diferença residual não equilibrada: {diferenca}."
            )
            logger.critical(mensagem_alerta)

            if raise_exception:
                raise ValidationError(
                    _(
                        f"Secção 7.3 (Desequilíbrio Contabilístico): O somatório de débitos ({total_debito}) "
                        f"diverge do somatório de créditos ({total_credito}) para o Pedido {pedido_id}."
                    )
                )
            return False

        return True

    def __str__(self) -> str:
        ts = self.timestamp.isoformat() if self.timestamp else "NOVO"
        return (
            f"Ledger [{ts}] {self.conta_origem} (D:{self.debito}) -> "
            f"{self.conta_destino} (C:{self.credito}) | Pedido {self.referencia_pedido_id}"
        )

