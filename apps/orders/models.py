"""
Modelos de dados da aplicação 'orders' (OMS - Order Management System e Livro Razão / Ledger).
Implementa rigorosamente:
- Secção 5 (5.1 e 5.2): Máquina de estados do pedido (10 estados principais + 4 saídas excecionais)
  e histórico imutável de eventos.
- Regras RN-040 a RN-060: Composição do total (RN-050), limites de quantidade (RN-042), notas (RN-045),
  congelamento de preços no momento da cotação (RN-020, RN-043) e unidades mínimas inteiras (RN-059).
- Secção 7.3 e RN-150: Livro razão (Ledger) imutável de dupla entrada onde cada movimento valida
  o equilíbrio estrito entre débito e crédito (soma líquida zero).
- Secção 11 e 12.1: Modelo de dados conceptual e catálogo de eventos padronizados.
"""
import uuid
from typing import Any

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models
from django.db.models import Sum
from django.utils import timezone
from django.utils.translation import gettext_lazy as _


class Pedido(models.Model):
    """
    Entidade 1: Representa um Pedido (OMS) na plataforma (Secções 5, 6.4, 6.5 e 11).
    Todos os valores monetários são armazenados em unidades mínimas inteiras (RN-059).
    """

    class EstadoPedido(models.TextChoices):
        """
        Estados do ciclo de vida do pedido conforme Secção 5 (10 estados sequenciais
        principais + 4 estados de saída excecional da Tabela 5.1).
        """

        # 10 Estados Principais do Ciclo de Vida (Secção 5)
        CRIADO = "CRIADO", _("1. Criado (Carrinho Validado)")
        PAGAMENTO = "PAGAMENTO", _("2. Pagamento (Autorizado/Capturado)")
        AGUARDA_PARCEIRO = "AGUARDA_PARCEIRO", _("3. Aguarda Parceiro")
        ACEITE = "ACEITE", _("4. Aceite pelo Parceiro")
        EM_PREPARACAO = "EM_PREPARACAO", _("5. Preparação em Curso")
        PRONTO = "PRONTO", _("6. Pronto para Recolha")
        RECOLHIDO = "RECOLHIDO", _("7. Recolhido pelo Estafeta")
        EM_TRANSITO = "EM_TRANSITO", _("8. Em Trânsito (A Caminho)")
        ENTREGUE = "ENTREGUE", _("9. Entregue (PIN Confirmado)")
        CONCLUIDO = "CONCLUIDO", _("10. Concluído (Liquidação)")

        # Saídas Excecionais (Secção 5 / Tabela 5.1)
        REJEITADO = "REJEITADO", _("Excecional: Rejeitado pelo Parceiro/Timeout")
        CANCELADO = "CANCELADO", _("Excecional: Cancelado")
        FALHA_ENTREGA = "FALHA_ENTREGA", _("Excecional: Falha de Entrega")
        REEMBOLSADO = "REEMBOLSADO", _("Excecional: Reembolsado (Total ou Parcial)")

    class MetodoPagamento(models.TextChoices):
        """Meios de pagamento suportados pela plataforma (RN-065)."""

        CARTAO = "CARTAO", _("Cartão Bancário (Débito/Crédito)")
        CARTEIRA_DIGITAL = "CARTEIRA_DIGITAL", _("Carteira Digital / Mobile Money")
        REFERENCIA_TRANSFERENCIA = "REFERENCIA_TRANSFERENCIA", _("Referência Multibanco / Transferência")
        CARTEIRA_INTERNA = "CARTEIRA_INTERNA", _("Carteira Interna da Plataforma")
        NUMERARIO = "NUMERARIO", _("Numerário na Entrega")

    # Mapa de transições permitidas da máquina de estados (Secção 5.1)
    TRANSICOES_PERMITIDAS: dict[str, set[str]] = {
        EstadoPedido.CRIADO: {
            EstadoPedido.PAGAMENTO,
            EstadoPedido.CANCELADO,
        },
        EstadoPedido.PAGAMENTO: {
            EstadoPedido.AGUARDA_PARCEIRO,
            EstadoPedido.CANCELADO,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.AGUARDA_PARCEIRO: {
            EstadoPedido.ACEITE,
            EstadoPedido.REJEITADO,
            EstadoPedido.CANCELADO,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.ACEITE: {
            EstadoPedido.EM_PREPARACAO,
            EstadoPedido.CANCELADO,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.EM_PREPARACAO: {
            EstadoPedido.PRONTO,
            EstadoPedido.CANCELADO,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.PRONTO: {
            EstadoPedido.RECOLHIDO,
            EstadoPedido.CANCELADO,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.RECOLHIDO: {
            EstadoPedido.EM_TRANSITO,
            EstadoPedido.CANCELADO,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.EM_TRANSITO: {
            EstadoPedido.ENTREGUE,
            EstadoPedido.CANCELADO,
            EstadoPedido.FALHA_ENTREGA,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.ENTREGUE: {
            EstadoPedido.CONCLUIDO,
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.CONCLUIDO: {
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.REJEITADO: {
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.CANCELADO: {
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.FALHA_ENTREGA: {
            EstadoPedido.REEMBOLSADO,
        },
        EstadoPedido.REEMBOLSADO: set(),
    }

    # Secção 11: Identificador único universal (UUID v4) do pedido
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID do Pedido"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) do pedido."),
    )

    # Secção 11: Cliente autor do pedido (protegido contra eliminação física para retenção fiscal - RN-007)
    cliente = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="pedidos",
        verbose_name=_("Cliente"),
        help_text=_("Secção 11 / RN-007: Utilizador cliente que realizou o pedido."),
    )

    # Secção 11 / RN-040: Loja parceira onde o pedido foi efetuado (uma loja por carrinho)
    loja = models.ForeignKey(
        "catalog.ParceiroLoja",
        on_delete=models.PROTECT,
        related_name="pedidos",
        verbose_name=_("Parceiro / Loja"),
        help_text=_("Secção 11 / RN-040: Loja parceira responsável pela preparação do pedido."),
    )

    # Secção 5: Estado atual do pedido na máquina de estados
    estado = models.CharField(
        max_length=25,
        choices=EstadoPedido.choices,
        default=EstadoPedido.CRIADO,
        db_index=True,
        verbose_name=_("Estado do Pedido"),
        help_text=_("Secção 5: Estado atual do pedido no ciclo de vida do OMS."),
    )

    # RN-050 / RN-059: Soma do valor dos itens e opções antes de taxas e descontos (unidades mínimas inteiras)
    subtotal = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Subtotal dos Produtos (Inteiro)"),
        help_text=_(
            "RN-050 / RN-059: Soma dos produtos e opções em unidades mínimas inteiras (Cêntimos/Kwanza)."
        ),
    )

    # RN-050 / RN-051 / RN-059: Valor da taxa de entrega cobrada ao cliente (unidades mínimas inteiras)
    taxa_entrega = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Taxa de Entrega (Inteiro)"),
        help_text=_("RN-050 / RN-051 / RN-059: Valor da taxa de entrega em unidades mínimas inteiras."),
    )

    # RN-050 / RN-053 / RN-059: Taxa de serviço da plataforma sobre o subtotal (unidades mínimas inteiras)
    taxa_servico = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Taxa de Serviço (Inteiro)"),
        help_text=_("RN-050 / RN-053 / RN-059: Taxa de utilização da plataforma em unidades mínimas inteiras."),
    )

    # RN-041 / RN-050 / RN-059: Suplemento quando o subtotal é inferior ao pedido mínimo da loja
    taxa_pequeno_pedido = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Taxa de Pequeno Pedido (Inteiro)"),
        help_text=_(
            "RN-041 / RN-050 / RN-059: Suplemento cobrado quando o subtotal é inferior ao pedido mínimo."
        ),
    )

    # RN-050 / RN-058 / RN-059: Gorjeta opcional atribuída pelo cliente e transferida na íntegra ao estafeta
    gorjeta_estafeta = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Gorjeta ao Estafeta (Inteiro)"),
        help_text=_(
            "RN-050 / RN-058 / RN-059: Valor opcional de gorjeta para o estafeta em unidades mínimas inteiras."
        ),
    )

    # RN-050 / RN-055 / RN-056 / RN-059: Total de descontos promocionais ou cupões aplicados ao pedido
    descontos = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Total de Descontos (Inteiro)"),
        help_text=_(
            "RN-050 / RN-055 / RN-056 / RN-059: Montante total deduzido por cupões ou promoções em unidades mínimas inteiras."
        ),
    )

    # RN-050 / RN-059: Valor final cobrado ao cliente:
    # Total = Subtotal + Taxa de entrega + Taxa de serviço + Taxa de pequeno pedido + Gorjeta - Descontos
    total_cobrado = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Total Cobrado ao Cliente (Inteiro)"),
        help_text=_(
            "RN-050 / RN-059: Total = Subtotal + Taxa Entrega + Taxa Serviço + Taxa Pequeno Pedido + Gorjeta - Descontos."
        ),
    )

    # RN-065 / Secção 11: Método de pagamento selecionado no checkout
    metodo_pagamento = models.CharField(
        max_length=30,
        choices=MetodoPagamento.choices,
        verbose_name=_("Método de Pagamento"),
        help_text=_("RN-065 / Secção 11: Meio de pagamento utilizado pelo cliente no checkout."),
    )

    # RN-043: Limite temporal de validade da cotação de preços, taxas e cotação (TTL padrão de 15 minutos)
    cotacao_expira_em = models.DateTimeField(
        null=True,
        blank=True,
        db_index=True,
        verbose_name=_("Cotação Expira Em"),
        help_text=_("RN-043: Data e hora limite até à qual os valores cotados são garantidos antes de expiração."),
    )

    # Secção 11: Carimbo temporal de criação do pedido
    data_criacao = models.DateTimeField(
        auto_now_add=True,
        editable=False,
        db_index=True,
        verbose_name=_("Data de Criação"),
        help_text=_("Secção 11: Data e hora exatas em que o pedido foi criado."),
    )

    # Secção 11: Carimbo temporal da última transição/atualização do pedido
    data_atualizacao = models.DateTimeField(
        auto_now=True,
        verbose_name=_("Data de Atualização"),
        help_text=_("Secção 11: Data e hora da última atualização de estado do pedido."),
    )

    class Meta:
        db_table = "orders_pedido"
        verbose_name = _("Pedido")
        verbose_name_plural = _("Pedidos")
        ordering = ["-data_criacao"]
        indexes = [
            models.Index(fields=["cliente", "-data_criacao"], name="idx_pedido_cliente_data"),
            models.Index(fields=["loja", "estado", "-data_criacao"], name="idx_pedido_loja_estado"),
            models.Index(fields=["estado", "-data_criacao"], name="idx_pedido_estado_data"),
        ]

    def calcular_total_esperado(self) -> int:
        """
        RN-050: Calcula a fórmula canónica do total do pedido:
        Total = Subtotal + Taxa de entrega + Taxa de serviço + Taxa de pequeno pedido + Gorjeta - Descontos
        (nunca inferior a zero).
        """
        bruto = (
            self.subtotal
            + self.taxa_entrega
            + self.taxa_servico
            + self.taxa_pequeno_pedido
            + self.gorjeta_estafeta
        )
        return max(0, bruto - self.descontos)

    def clean(self) -> None:
        """
        RN-050: Valida que `total_cobrado` corresponde exatamente à fórmula da regra RN-050.
        """
        super().clean()
        esperado = self.calcular_total_esperado()
        if self.total_cobrado != esperado:
            raise ValidationError(
                _(
                    f"RN-050: O total_cobrado ({self.total_cobrado}) não coincide com o cálculo "
                    f"oficial dos componentes ({esperado})."
                )
            )

    def pode_transitar_para(self, novo_estado: str) -> bool:
        """
        Secção 5.1 e 5.2: Verifica se a transição do estado atual para `novo_estado` é permitida
        (suporta idempotência se `novo_estado == self.estado`).
        """
        if novo_estado == self.estado:
            return True
        return novo_estado in self.TRANSICOES_PERMITIDAS.get(self.estado, set())

    def __str__(self) -> str:
        return f"Pedido {self.id} [{self.estado}] - Total: {self.total_cobrado}"


class LinhaPedido(models.Model):
    """
    Entidade 2: Linha individual de produto dentro de um Pedido (Secção 11).
    Congela o preço unitário no momento da cotação/compra (RN-020, RN-043) e valida
    os limites de quantidade (RN-042) e notas ao parceiro (RN-045).
    """

    # Secção 11: Identificador único UUID v4 da linha de pedido
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Linha de Pedido"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) da linha do pedido."),
    )

    # Secção 11: Pedido ao qual esta linha pertence
    pedido = models.ForeignKey(
        Pedido,
        on_delete=models.CASCADE,
        related_name="linhas",
        verbose_name=_("Pedido"),
        help_text=_("Secção 11: Pedido em que esta linha de artigo está incluída."),
    )

    # Secção 11: Referência ao ItemMenu do catálogo
    item = models.ForeignKey(
        "catalog.ItemMenu",
        on_delete=models.PROTECT,
        related_name="linhas_pedido",
        verbose_name=_("Item do Menu"),
        help_text=_("Secção 11: Produto do catálogo selecionado pelo cliente."),
    )

    # RN-042: Quantidade de unidades do item (limite padrão configurável, ex.: máx. 20 unidades por item)
    quantidade = models.PositiveSmallIntegerField(
        default=1,
        validators=[MinValueValidator(1), MaxValueValidator(20)],
        verbose_name=_("Quantidade"),
        help_text=_("RN-042: Quantidade de unidades deste item (entre 1 e o limite máximo de 20)."),
    )

    # RN-020 / RN-043 / RN-059: Preço unitário do item congelado no momento da cotação (unidades mínimas inteiras)
    preco_unitario_historico = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Preço Unitário Histórico (Inteiro)"),
        help_text=_(
            "RN-016 / RN-020 / RN-043 / RN-059: Preço unitário do item congelado no instante da cotação "
            "em unidades mínimas inteiras."
        ),
    )
    preco_unitario_no_momento = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Preço Unitário no Momento (Inteiro)"),
        help_text=_("Campo de compatibilidade com o checkout OMS."),
    )

    # RN-045: Observações livres do cliente sobre a preparação deste item (sem alterar preço contratual)
    notas = models.TextField(
        null=True,
        blank=True,
        default="",
        verbose_name=_("Notas ao Item"),
        help_text=_(
            "RN-045: Notas de preparação deixadas pelo cliente ao parceiro (não alteram o preço)."
        ),
    )

    class Meta:
        db_table = "orders_linha_pedido"
        verbose_name = _("Linha de Pedido")
        verbose_name_plural = _("Linhas de Pedido")
        indexes = [
            models.Index(fields=["pedido"], name="idx_linhapedido_pedido"),
        ]

    def save(self, *args: Any, **kwargs: Any) -> None:
        """Sincroniza os campos de preço unitário histórico."""
        if not self.preco_unitario_historico and self.preco_unitario_no_momento:
            self.preco_unitario_historico = self.preco_unitario_no_momento
        elif not self.preco_unitario_no_momento and self.preco_unitario_historico:
            self.preco_unitario_no_momento = self.preco_unitario_historico
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.quantidade}x {self.item.nome} @ {self.preco_unitario_historico} (Pedido {self.pedido_id})"


class LinhaPedidoOpcaoSelecionada(models.Model):
    """
    Entidade 4: Opção ou extra selecionado pelo cliente para uma determinada LinhaPedido (Secção 11, RN-014).
    Congela o preço adicional da opção no momento da cotação (RN-020, RN-059).
    """

    # Identificador único UUID v4 da opção selecionada na linha
    id = models.UUIDField(
        primary_key=True,
        default=uuid.uuid4,
        editable=False,
        verbose_name=_("ID da Opção da Linha"),
        help_text=_("Secção 11: Identificador único universal (UUID v4) da opção selecionada na linha."),
    )

    # Linha de pedido à qual esta escolha de opção está associada
    linha_pedido = models.ForeignKey(
        LinhaPedido,
        on_delete=models.CASCADE,
        related_name="opcoes_selecionadas",
        verbose_name=_("Linha de Pedido"),
        help_text=_("Secção 11: Linha de pedido que contém esta opção personalizada."),
    )

    # Referência à OpcaoItem do catálogo
    opcao = models.ForeignKey(
        "catalog.OpcaoItem",
        on_delete=models.PROTECT,
        related_name="selecoes_pedido",
        verbose_name=_("Opção de Item"),
        help_text=_("RN-014 / Secção 11: Opção ou complemento escolhido pelo cliente."),
    )

    # RN-020 / RN-043 / RN-059: Preço adicional histórico da opção congelado na cotação
    preco_adicional_historico = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Preço Adicional Histórico (Inteiro)"),
        help_text=_(
            "RN-020 / RN-059: Preço adicional da opção congelado no momento do checkout em unidades mínimas inteiras."
        ),
    )
    preco_no_momento = models.PositiveBigIntegerField(
        default=0,
        validators=[MinValueValidator(0)],
        verbose_name=_("Preço da Opção no Momento (Inteiro)"),
        help_text=_("Campo de compatibilidade com o checkout OMS."),
    )

    class Meta:
        db_table = "orders_linha_pedido_opcao"
        verbose_name = _("Opção Selecionada na Linha de Pedido")
        verbose_name_plural = _("Opções Selecionadas nas Linhas de Pedido")

    def save(self, *args: Any, **kwargs: Any) -> None:
        """Sincroniza os campos de preço adicional histórico."""
        if not self.preco_adicional_historico and self.preco_no_momento:
            self.preco_adicional_historico = self.preco_no_momento
        elif not self.preco_no_momento and self.preco_adicional_historico:
            self.preco_no_momento = self.preco_adicional_historico
        super().save(*args, **kwargs)

    def __str__(self) -> str:
        return f"{self.opcao.nome} (+{self.preco_adicional_historico}) -> Linha {self.linha_pedido_id}"


# Alias retrocompatível para importações existentes
LinhaPedidoOpcao = LinhaPedidoOpcaoSelecionada

# Re-exportação canónica dos modelos de Auditoria e Contabilidade Imutável (Secções 5.2, 7.3 e 11)
from apps.finance.models import EventoPedido, LivroRazaoLedger  # noqa: E402, F401


# Importação dos modelos de Segurança, Controlo de Dispositivos e Antifraude (Secção 6.14, RN-130 a RN-135)
from apps.orders.fraud_models import (  # noqa: E402
    DispositivoUtilizador,
    ImpressaoDigitalCartao,
    ListaBloqueioImutavel,
    RegistoAlertaFraude,
)

# Re-exportação do modelo de Entrega Logística para conveniência transacional (Secção 11)
from apps.logistics.models import Entrega  # noqa: E402, F401
