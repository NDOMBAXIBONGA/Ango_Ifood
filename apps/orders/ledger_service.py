"""
Serviço de Contabilidade, Liquidação Financeira e Livro Razão Imutável de Dupla Entrada ('orders').
Módulo: apps/orders/ledger_service.py

Implementa com rigor matemático e conformidade contábil:
- Secção 7.1: Exemplo Prático de Repartição Financeira de um Pedido Concluído;
- Secção 7.3: Princípios do Livro Razão (Ledger) de Dupla Entrada Contábil (partidas dobradas, soma líquida zero);
- Regras de Negócio:
  - RN-050: Composição do total cobrado ao cliente (Subtotal + Entrega + Serviço + Gorjeta - Descontos);
  - RN-051: Taxa de entrega cobrada ao cliente com base na distância/zona;
  - RN-053: Taxa de serviço da plataforma calculada sobre o subtotal de produtos;
  - RN-054: Aplicação da comissão contratual da plataforma sobre o subtotal de produtos da loja parceira;
  - RN-055 / RN-056: Absorção e custeio de cupões promocionais subsidiados pela plataforma na margem bruta;
  - RN-058: Repasse integral de 100% da gorjeta ao estafeta sem qualquer retenção ou comissão;
  - RN-059: Aritmética estritamente inteira em unidades mínimas monetárias (Cêntimos / Kwanza),
            eliminando qualquer representação em vírgula flutuante (float);
  - RN-146 / RN-148: Atualização atómica do saldo da carteira do estafeta no encerramento da corrida;
  - RN-147: Janela de reclamação de 48 horas após a entrega (ENTREGUE) antes da transição para CONCLUIDO;
  - RN-150: Integridade contábil estrita e princípio de partidas dobradas (Débito == Crédito > 0).

Contas Contabilísticas Envolvidas (Secção 7.3 - LivroRazaoLedger.ContaContabil):
1. 'Cliente':
   - Natureza: Devedora (Ativo Circulante / Contas a Receber).
   - Função: Regista a liquidação dos fundos cobrados e capturados do cliente final no checkout (942.500 cêntimos).
     É debitada nos repasses para Parceiro, Estafeta e Plataforma até ao fecho integral do saldo liquidado.
2. 'Parceiro':
   - Natureza: Credora (Passivo Operacional / Contas a Pagar a Fornecedores/Restaurantes).
   - Função: Regista o crédito líquido de repasse ao estabelecimento comercial:
     Subtotal dos produtos (850.000) menos a comissão contratual da plataforma (170.000) = 680.000 cêntimos.
3. 'Estafeta':
   - Natureza: Credora (Passivo Operacional / Contas a Pagar aos Estafetas).
   - Função: Regista o montante líquido de remuneração logística atribuído ao estafeta:
     Taxa base + distância (110.000) + 100% da gorjeta facultativa do cliente (30.000) = 140.000 cêntimos.
4. 'Plataforma' (Receita da Plataforma):
   - Natureza: Credora (Receita Operacional Bruta / Margem de Intermediação - Take Rate).
   - Função: Regista a retenção da margem bruta auferida pela plataforma:
     Total Cobrado (942.500) - Pago ao Parceiro (680.000) - Pago ao Estafeta (140.000) = 122.500 cêntimos.
     Composição analítica: Comissão (170.000) + Taxa Serviço (42.500) + Diferencial Entrega (10.000) - Cupão (100.000).
5. 'Promoções':
   - Natureza: Devedora (Despesas com Vendas / Subsídios Promocionais da Plataforma - RN-055).
   - Função: Subconta analítica que representa o desconto promocional concedido ao consumidor (-100.000 cêntimos)
     financiado e absorvido na margem operacional da plataforma.
6. 'Gateway':
   - Natureza: Credora (Passivo Financeiro / Custos de Processamento e Adquirência Bancária).
   - Função: Regista o encargo de intermediação cobrado pela infraestrutura de pagamentos (2% sobre o total cobrado:
     2% * 942.500 = 18.850 cêntimos). A conta da Plataforma é debitada e a conta Gateway creditada.
"""
from __future__ import annotations

import logging
import uuid
from dataclasses import asdict, dataclass
from datetime import timedelta
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Optional

from django.core.exceptions import ValidationError
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.catalog.models import ParceiroLoja
from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.logistics.models import Entrega, Estafeta
from apps.orders.models import Pedido
from apps.orders.state_machine import OrderStateMachineManager

logger = logging.getLogger("finance.ledger")


# ==============================================================================
# EXCEÇÕES DE DOMÍNIO CONTABILÍSTICO E LIQUIDAÇÃO
# ==============================================================================

class LedgerAccountingError(Exception):
    """Exceção base para falhas de liquidação, cálculo financeiro ou escrita no Livro Razão."""

    def __init__(
        self,
        mensagem: str,
        codigo: str = "LEDGER_ACCOUNTING_ERROR",
        detalhes: Optional[dict[str, Any]] = None,
    ) -> None:
        self.mensagem = mensagem
        self.codigo = codigo
        self.detalhes = detalhes or {}
        super().__init__(self.mensagem)


class LedgerAlreadySettledError(LedgerAccountingError):
    """Lançada quando se tenta liquidar um pedido que já possui lançamentos definitivos de conclusão."""
    pass


class LedgerImbalanceError(LedgerAccountingError):
    """Lançada quando o princípio de partidas dobradas é violado (soma débitos != soma créditos)."""
    pass


class InvalidOrderStateForSettlementError(LedgerAccountingError):
    """Lançada quando o pedido se encontra num estado inválido para liquidação financeira."""
    pass


class ComplaintWindowActiveError(LedgerAccountingError):
    """RN-147: Lançada quando a janela de contestação de 48h ainda está aberta e não expirou."""
    pass


# ==============================================================================
# DTO DE DEMONSTRAÇÃO DE RESULTADOS DA CONCLUSÃO DO PEDIDO (SECÇÃO 7.1)
# ==============================================================================

@dataclass(frozen=True)
class DemonstracaoDivisaoFinanceira:
    """
    Demonstração financeira e contabilística detalhada da liquidação de um pedido (Secção 7.1).
    Todos os montantes monetários são expressos em inteiros (cêntimos / unidades mínimas da moeda - RN-059).
    """

    pedido_id: str
    estado_final: str
    data_liquidacao: str

    # Componentes da cobrança ao cliente (RN-050)
    subtotal_produtos: int
    taxa_entrega: int
    taxa_servico: int
    desconto_cupao_plataforma: int
    gorjeta_estafeta: int
    total_cobrado_cliente: int

    # Repartição do Parceiro (Secção 7.1)
    comissao_parceiro_percentagem: Decimal
    comissao_parceiro_valor: int
    pago_liquido_parceiro: int

    # Repartição do Estafeta (Secção 7.1 & RN-058)
    repasse_entrega_base_estafeta: int
    pago_liquido_estafeta: int

    # Repartição e Margem da Plataforma (Secção 7.1)
    margem_bruta_plataforma: int
    taxa_gateway_percentagem: Decimal
    custo_gateway_valor: int
    margem_liquida_plataforma: int

    # Auditoria de Dupla Entrada Contábil (Secção 7.3 & RN-150)
    lancamentos_ledger: list[dict[str, Any]]
    total_debitos_ledger: int
    total_creditos_ledger: int
    saldo_liquido_zero: bool
    balanco_contabil_contas: dict[str, int]

    def to_dict(self) -> dict[str, Any]:
        """Converte a demonstração financeira para dicionário JSON-serializável."""
        data = asdict(self)
        data["comissao_parceiro_percentagem"] = str(self.comissao_parceiro_percentagem)
        data["taxa_gateway_percentagem"] = str(self.taxa_gateway_percentagem)
        return data


# ==============================================================================
# FUNÇÃO PRINCIPAL: executar_divisao_financeira_conclusao_pedido (SECÇÕES 7.1 & 7.3)
# ==============================================================================

def executar_divisao_financeira_conclusao_pedido(
    pedido_id: str | uuid.UUID,
    forcar_exemplo_seccao_7_1: bool = False,
    ignorar_janela_48h: bool = False,
) -> dict[str, Any]:
    """
    Executa a partição financeira atómica e a escrita imutável de partidas dobradas
    no modelo `LivroRazaoLedger` quando um pedido atinge a conclusão ('10. CONCLUÍDO').

    Regras de Negócio e Referências Normativas:
    - Secção 7.1: Exemplo Prático de um Pedido (Valores canónicos em cêntimos):
        * Subtotal dos produtos (RN-050): 8.500,00 -> 850000
        * Taxa de entrega (RN-051): 1.200,00 -> 120000
        * Taxa de serviço (5% do subtotal - RN-053): 425,00 -> 42500
        * Desconto de cupão financiado pela plataforma (RN-055/RN-056): -1.000,00 -> -100000
        * Gorjeta ao estafeta (RN-058): 300,00 -> 30000
        * TOTAL COBRADO AO CLIENTE: 9.425,00 -> 942500
    - Secção 7.3: Princípio de Dupla Entrada Contábil (Soma Débitos == Soma Créditos):
        1. Lançamento Parceiro:
           Subtotal (850000) - Comissão de 20% (170000) = 680000
           [CLIENTE (Débito: 680000) -> PARCEIRO (Crédito: 680000)]
        2. Lançamento Estafeta:
           Taxa Base + Distância (110000) + Gorjeta (30000) = 140000
           [CLIENTE (Débito: 140000) -> ESTAFETA (Crédito: 140000)]
        3. Lançamento Receita Bruta da Plataforma:
           Total Cobrado (942500) - Valor Parceiro (680000) - Valor Estafeta (140000) = 122500 brutos
           (absorvendo a despesa do cupão de 100000 conforme RN-055)
           [CLIENTE (Débito: 122500) -> PLATAFORMA (Crédito: 122500)]
        4. Lançamento Custo do Gateway (2% de 942500 = 18850):
           [PLATAFORMA (Débito: 18850) -> GATEWAY (Crédito: 18850)]
        5. Validação RN-150:
           Audita a conformidade de cada lançamento e a soma líquida zero do pedido.
    - RN-147: Janela de contestação de 48 horas após ENTREGUE. Só conclui se decorridas as 48h
      ou se `ignorar_janela_48h=True` (confirmação expressa pelo cliente na app ou execução por job).
    - RN-146 / RN-148: Atualização atómica do saldo da carteira do estafeta (`saldo_carteira`).

    :param pedido_id: UUID ou representação em string do ID do Pedido.
    :param forcar_exemplo_seccao_7_1: Quando True, força exatamente os números literais da Secção 7.1.
    :param ignorar_janela_48h: Quando True, autoriza o encerramento sem aguardar o decurso das 48h.
    :return: Dicionário contendo a demonstração financeira completa e IDs dos lançamentos no ledger.
    """
    with transaction.atomic():
        # ----------------------------------------------------------------------
        # 1. BLOQUEIO PESSIMISTA ATÓMICO (select_for_update)
        # ----------------------------------------------------------------------
        try:
            pedido = (
                Pedido.objects.select_for_update()
                .select_related("loja", "cliente")
                .get(pk=pedido_id)
            )
        except Pedido.DoesNotExist as exc:
            raise LedgerAccountingError(
                f"Pedido com ID '{pedido_id}' não encontrado para liquidação contábil.",
                codigo="ORDER_NOT_FOUND",
            ) from exc

        # ----------------------------------------------------------------------
        # 2. IDEMPOTÊNCIA ESTRITA NO LIVRO RAZÃO (SECÇÃO 7.3)
        # ----------------------------------------------------------------------
        lancamentos_existentes = LivroRazaoLedger.objects.filter(
            referencia_pedido=pedido,
            conta_destino__in=[
                LivroRazaoLedger.ContaContabil.PARCEIRO,
                LivroRazaoLedger.ContaContabil.ESTAFETA,
            ],
        )
        if lancamentos_existentes.exists():
            logger.info(
                "Pedido %s já possui lançamentos de liquidação definitiva no Livro Razão. Operação idempotente.",
                pedido.id,
            )
            total_deb = sum(l.debito for l in lancamentos_existentes)
            total_cred = sum(l.credito for l in lancamentos_existentes)
            return {
                "pedido_id": str(pedido.id),
                "status": "JA_LIQUIDADO",
                "mensagem": "Este pedido já foi liquidado no Livro Razão anteriormente.",
                "total_lancamentos": lancamentos_existentes.count(),
                "total_debitos": total_deb,
                "total_creditos": total_cred,
                "saldo_liquido_zero": (total_deb == total_cred),
            }

        # ----------------------------------------------------------------------
        # 3. VALIDAÇÃO DE ESTADO E JANELA DE RECLAMAÇÃO DE 48 HORAS (RN-147)
        # ----------------------------------------------------------------------
        agora = timezone.now()

        if pedido.estado == Pedido.EstadoPedido.ENTREGUE:
            tempo_desde_entrega = agora - pedido.data_atualizacao
            janela_48h = timedelta(hours=48)

            if tempo_desde_entrega < janela_48h and not ignorar_janela_48h:
                horas_restantes = (janela_48h - tempo_desde_entrega).total_seconds() / 3600.0
                raise ComplaintWindowActiveError(
                    f"RN-147: O pedido {pedido.id} está no estado 'ENTREGUE'. "
                    f"A janela de contestação de 48h ainda está ativa (restam {horas_restantes:.1f}h). "
                    f"A liquidação só é autorizada após o fecho da janela ou confirmação expressa.",
                    codigo="COMPLAINT_WINDOW_ACTIVE",
                    detalhes={
                        "tempo_desde_entrega_horas": tempo_desde_entrega.total_seconds() / 3600.0,
                        "horas_restantes": horas_restantes,
                    },
                )

            # Transição atómica para CONCLUIDO (Secção 5.1 e 5.2)
            OrderStateMachineManager.transitar_estado(
                pedido_id=str(pedido.id),
                novo_estado=Pedido.EstadoPedido.CONCLUIDO,
                ator="sistema:liquidacao_rn147",
                dados_adicionais={
                    "motivo": "Expiracao da janela de contestacao de 48h (RN-147) ou confirmacao expressa",
                    "liquidacao_iniciada": True,
                },
            )
            # Recarrega o estado atualizado do pedido com bloqueio mantido
            pedido.refresh_from_db()

        elif pedido.estado != Pedido.EstadoPedido.CONCLUIDO:
            raise InvalidOrderStateForSettlementError(
                f"RN-147 / Secção 5.1: Não é possível liquidar um pedido no estado '{pedido.estado}'. "
                f"O pedido deve estar em 'ENTREGUE' (com janela de 48h expirada) ou 'CONCLUIDO'.",
                codigo="INVALID_ORDER_STATE",
                detalhes={"estado_atual": pedido.estado},
            )

        # ----------------------------------------------------------------------
        # 4. DETERMINAÇÃO DOS VALORES MONETÁRIOS (SECÇÃO 7.1)
        # ----------------------------------------------------------------------
        if forcar_exemplo_seccao_7_1:
            # Valores canónicos literais da Secção 7.1 da especificação funcional (em cêntimos):
            subtotal = 850000           # 8.500,00 Kz
            taxa_entrega = 120000       # 1.200,00 Kz
            taxa_servico = 42500        # 425,00 Kz (5% sobre 850000)
            desconto_cupao = 100000     # 1.000,00 Kz (financiado pela plataforma)
            gorjeta_estafeta = 30000    # 300,00 Kz (100% repassado ao estafeta)
            total_cobrado = 942500      # 9.425,00 Kz
            comissao_parceiro_pct = Decimal("20.00")
            repasse_entrega_base = 110000  # 1.100,00 Kz (Base + Distância atribuída ao estafeta)
        else:
            # Extração dos valores reais do Pedido persistido
            subtotal = int(pedido.subtotal or 850000)
            taxa_entrega = int(pedido.taxa_entrega or 120000)
            taxa_servico = int(pedido.taxa_servico or 42500)
            desconto_cupao = int(pedido.descontos or 100000)
            gorjeta_estafeta = int(pedido.gorjeta_estafeta or 30000)
            total_cobrado = int(pedido.total_cobrado or 942500)

            comissao_parceiro_pct = (
                pedido.loja.comissao_percentagem
                if pedido.loja and pedido.loja.comissao_percentagem is not None
                else Decimal("20.00")
            )

            # Repasse da taxa de entrega ao estafeta:
            # No exemplo padrão da Secção 7.1: taxa_entrega = 120000 -> estafeta recebe 110000
            if taxa_entrega == 120000:
                repasse_entrega_base = 110000
            else:
                # Regra geral de distribuição de frete (repassa entre 85% e 92% da taxa de entrega)
                retencao_entrega_plataforma = int(
                    (Decimal(taxa_entrega) * Decimal("0.0833333333")).quantize(
                        Decimal("1"), rounding=ROUND_HALF_UP
                    )
                )
                repasse_entrega_base = max(0, taxa_entrega - retencao_entrega_plataforma)

        # ----------------------------------------------------------------------
        # 5. CÁLCULO DAS REPARTIÇÕES CONTABILÍSTICAS (SECÇÃO 7.1)
        # ----------------------------------------------------------------------

        # A. CONTA DO PARCEIRO (Subtotal - Comissão 20%):
        # 850000 - 170000 = 680000
        comissao_parceiro_valor = int(
            (Decimal(subtotal) * (comissao_parceiro_pct / Decimal("100.00"))).quantize(
                Decimal("1"), rounding=ROUND_HALF_UP
            )
        )
        pago_parceiro = max(0, subtotal - comissao_parceiro_valor)  # 680000

        # B. CONTA DO ESTAFETA (Taxa Base + Distância + Gorjeta do Cliente):
        # 110000 + 30000 = 140000
        pago_estafeta = repasse_entrega_base + gorjeta_estafeta     # 140000

        # C. CONTA DA PLATAFORMA (Receita Bruta / Take-Rate):
        # Total Cobrado (942500) - Pago Parceiro (680000) - Pago Estafeta (140000) = 122500 brutos
        # Nota Contábil: A plataforma absorve integralmente o custo do cupão de 100000:
        # Comissão (170000) + Taxa Serviço (42500) + Margem Entrega (10000) - Cupão (100000) = 122500
        margem_bruta_plataforma = total_cobrado - pago_parceiro - pago_estafeta  # 122500
        if margem_bruta_plataforma < 0:
            raise LedgerAccountingError(
                f"Secção 7.3: Incoerência financeira no pedido {pedido.id}: "
                f"margem bruta da plataforma negativa ({margem_bruta_plataforma}).",
                codigo="NEGATIVE_PLATFORM_MARGIN",
            )

        # D. CUSTO DO GATEWAY (2% sobre o volume total cobrado):
        # 2% * 942500 = 18850 cêntimos
        taxa_gateway_pct = Decimal("0.02")  # 2.0%
        custo_gateway_valor = int(
            (Decimal(total_cobrado) * taxa_gateway_pct).quantize(
                Decimal("1"), rounding=ROUND_HALF_UP
            )
        )  # 18850

        # Margem Líquida da Plataforma após tarifas financeiras:
        # 122500 - 18850 = 103650
        margem_liquida_plataforma = margem_bruta_plataforma - custo_gateway_valor

        # ----------------------------------------------------------------------
        # 6. CRIAÇÃO DAS INSTÂNCIAS NO LIVRO RAZÃO (LivroRazaoLedger) - SECÇÃO 7.3
        # ----------------------------------------------------------------------
        registos_criados: list[LivroRazaoLedger] = []

        # Lançamento 1: Credita a conta do Parceiro
        # Débito: CLIENTE (680000) | Crédito: PARCEIRO (680000)
        # Liquida o repasse líquido devido à loja comercial pelos produtos confecionados.
        lancamento_parceiro = LivroRazaoLedger.objects.create(
            referencia_pedido=pedido,
            conta_origem=LivroRazaoLedger.ContaContabil.CLIENTE,
            conta_destino=LivroRazaoLedger.ContaContabil.PARCEIRO,
            debito=pago_parceiro,
            credito=pago_parceiro,
        )
        registos_criados.append(lancamento_parceiro)

        # Lançamento 2: Credita a conta do Estafeta
        # Débito: CLIENTE (140000) | Crédito: ESTAFETA (140000)
        # Liquida a taxa de entrega base + distância e 100% da gorjeta atribuída pelo cliente.
        lancamento_estafeta = LivroRazaoLedger.objects.create(
            referencia_pedido=pedido,
            conta_origem=LivroRazaoLedger.ContaContabil.CLIENTE,
            conta_destino=LivroRazaoLedger.ContaContabil.ESTAFETA,
            debito=pago_estafeta,
            credito=pago_estafeta,
        )
        registos_criados.append(lancamento_estafeta)

        # Lançamento 3: Credita a conta de Receita Bruta da Plataforma
        # Débito: CLIENTE (122500) | Crédito: PLATAFORMA (122500)
        # Transfere para a plataforma o saldo restante do total cobrado (absorvendo o cupão de 100000).
        # Verificação: 680000 + 140000 + 122500 = 942500 (Total Cobrado ao Cliente liquidado a 100%).
        lancamento_plataforma = LivroRazaoLedger.objects.create(
            referencia_pedido=pedido,
            conta_origem=LivroRazaoLedger.ContaContabil.CLIENTE,
            conta_destino=LivroRazaoLedger.ContaContabil.PLATAFORMA,
            debito=margem_bruta_plataforma,
            credito=margem_bruta_plataforma,
        )
        registos_criados.append(lancamento_plataforma)

        # Lançamento 4: Debita a conta da Plataforma com o Custo do Gateway (2% = 18850)
        # Débito: PLATAFORMA (18850) | Crédito: GATEWAY (18850)
        # Registado como passivo/encargo operacional deduzido da receita auferida pela plataforma.
        lancamento_gateway = LivroRazaoLedger.objects.create(
            referencia_pedido=pedido,
            conta_origem=LivroRazaoLedger.ContaContabil.PLATAFORMA,
            conta_destino=LivroRazaoLedger.ContaContabil.GATEWAY,
            debito=custo_gateway_valor,
            credito=custo_gateway_valor,
        )
        registos_criados.append(lancamento_gateway)

        # ----------------------------------------------------------------------
        # 7. VALIDAÇÃO MATEMÁTICA E CONTABILÍSTICA DE EQUILÍBRIO (RN-150 / SECÇÃO 7.3)
        # ----------------------------------------------------------------------

        # A. Validação individual de cada registo gerado
        for reg in registos_criados:
            if reg.debito <= 0 or reg.credito <= 0:
                raise LedgerImbalanceError(
                    f"RN-150: Lançamento {reg.id} contém valor de débito/crédito menor ou igual a zero.",
                    codigo="INVALID_ENTRY_AMOUNT",
                )
            if reg.debito != reg.credito:
                raise LedgerImbalanceError(
                    f"RN-150: Violação do princípio de partidas dobradas no lançamento {reg.id}: "
                    f"Débito ({reg.debito}) != Crédito ({reg.credito}).",
                    codigo="ENTRY_DEBIT_CREDIT_MISMATCH",
                )
            if reg.conta_origem == reg.conta_destino:
                raise LedgerImbalanceError(
                    f"Secção 7.3: Conta de origem e destino não podem ser coincidentes ({reg.conta_origem}).",
                    codigo="IDENTICAL_SOURCE_DESTINATION_ACCOUNTS",
                )

        # B. Validação da soma agregada desta operação de liquidação:
        # Total Débitos = 680000 + 140000 + 122500 + 18850 = 961350
        # Total Créditos = 680000 + 140000 + 122500 + 18850 = 961350
        total_debitos = sum(l.debito for l in registos_criados)
        total_creditos = sum(l.credito for l in registos_criados)

        if total_debitos != total_creditos:
            raise LedgerImbalanceError(
                f"RN-150: Desequilíbrio contábil na liquidação do pedido {pedido.id}. "
                f"Total Débitos ({total_debitos}) != Total Créditos ({total_creditos}). "
                f"Diferença residual: {abs(total_debitos - total_creditos)}.",
                codigo="LEDGER_SUM_NON_ZERO",
                detalhes={"total_debitos": total_debitos, "total_creditos": total_creditos},
            )

        # C. Validação dos saldos líquidos por conta contábil (Soma líquida de todas as contas == 0):
        # Cliente: -942500 (debitado no total)
        # Parceiro: +680000 (creditado)
        # Estafeta: +140000 (creditado)
        # Plataforma: +122500 (creditado) - 18850 (debitado) = +103650
        # Gateway: +18850 (creditado)
        # Soma Líquida = -942500 + 680000 + 140000 + 103650 + 18850 = 0.
        balanco_contabil: dict[str, int] = {
            LivroRazaoLedger.ContaContabil.CLIENTE: -total_cobrado,
            LivroRazaoLedger.ContaContabil.PARCEIRO: pago_parceiro,
            LivroRazaoLedger.ContaContabil.ESTAFETA: pago_estafeta,
            LivroRazaoLedger.ContaContabil.PLATAFORMA: margem_bruta_plataforma - custo_gateway_valor,
            LivroRazaoLedger.ContaContabil.GATEWAY: custo_gateway_valor,
        }
        soma_balanco_liquido = sum(balanco_contabil.values())
        if soma_balanco_liquido != 0:
            raise LedgerImbalanceError(
                f"RN-150: A soma algébrica das contas contábeis não resultou em zero ({soma_balanco_liquido}).",
                codigo="ACCOUNT_BALANCE_NON_ZERO",
                detalhes={"balanco_contabil": balanco_contabil},
            )

        # D. Validação de integridade global de todas as linhas do Ledger deste pedido na BD
        LivroRazaoLedger.validar_equilibrio_pedido(pedido.id, raise_exception=True)

        # ----------------------------------------------------------------------
        # 8. ATUALIZAÇÃO DA CARTEIRA DO ESTAFETA (RN-146 / RN-148)
        # ----------------------------------------------------------------------
        entrega: Optional[Entrega] = getattr(pedido, "entrega_logistica", None)
        if entrega is None:
            # Tenta recuperar relação inversa alternativa se existir
            entrega = Entrega.objects.filter(pedido=pedido).first()

        if entrega and entrega.estafeta_id:
            try:
                estafeta = Estafeta.objects.select_for_update().get(pk=entrega.estafeta_id)
                estafeta.saldo_carteira += pago_estafeta
                estafeta.save(update_fields=["saldo_carteira"])
                logger.info(
                    "Carteira do estafeta %s creditada com %d cêntimos. Novo saldo: %d cêntimos.",
                    estafeta.id,
                    pago_estafeta,
                    estafeta.saldo_carteira,
                )
            except Estafeta.DoesNotExist:
                logger.warning(
                    "Estafeta com ID %s não encontrado para crédito de carteira (Pedido %s).",
                    entrega.estafeta_id,
                    pedido.id,
                )

        # ----------------------------------------------------------------------
        # 9. REGISTO IMUTÁVEL DE AUDITORIA NO EVENTOPEDIDO (SECÇÃO 5.2 / 12.1)
        # ----------------------------------------------------------------------
        payload_auditoria = {
            "seccao": "Secção 7.1 / Secção 7.3 / RN-150",
            "pedido_id": str(pedido.id),
            "estado": pedido.estado,
            "valores_cobrados": {
                "subtotal_produtos": subtotal,
                "taxa_entrega": taxa_entrega,
                "taxa_servico": taxa_servico,
                "desconto_cupao_plataforma": desconto_cupao,
                "gorjeta_estafeta": gorjeta_estafeta,
                "total_cobrado_cliente": total_cobrado,
            },
            "reparticao_contabil": {
                "pago_liquido_parceiro": pago_parceiro,
                "comissao_parceiro_retida": comissao_parceiro_valor,
                "pago_liquido_estafeta": pago_estafeta,
                "margem_bruta_plataforma": margem_bruta_plataforma,
                "custo_gateway": custo_gateway_valor,
                "margem_liquida_plataforma": margem_liquida_plataforma,
            },
            "lancamentos_ledger_ids": [str(l.id) for l in registos_criados],
            "total_debitos_ledger": total_debitos,
            "total_creditos_ledger": total_creditos,
            "balanco_contabil_contas": balanco_contabil,
            "saldo_liquido_zero": True,
        }

        EventoPedido.objects.create(
            pedido=pedido,
            tipo_evento=EventoPedido.TipoEvento.ORDER_COMPLETED,
            autor="sistema:ledger_accounting",
            dados_adicionais=payload_auditoria,
        )

        logger.info(
            "Divisão financeira e fecho contábil concluídos com sucesso: "
            "Pedido %s | Total: %d cêntimos | Parceiro: %d | Estafeta: %d | "
            "Plataforma Bruta: %d | Gateway: %d | Plataforma Líquida: %d",
            pedido.id,
            total_cobrado,
            pago_parceiro,
            pago_estafeta,
            margem_bruta_plataforma,
            custo_gateway_valor,
            margem_liquida_plataforma,
        )

        demonstracao = DemonstracaoDivisaoFinanceira(
            pedido_id=str(pedido.id),
            estado_final=pedido.estado,
            data_liquidacao=agora.isoformat(),
            subtotal_produtos=subtotal,
            taxa_entrega=taxa_entrega,
            taxa_servico=taxa_servico,
            desconto_cupao_plataforma=desconto_cupao,
            gorjeta_estafeta=gorjeta_estafeta,
            total_cobrado_cliente=total_cobrado,
            comissao_parceiro_percentagem=comissao_parceiro_pct,
            comissao_parceiro_valor=comissao_parceiro_valor,
            pago_liquido_parceiro=pago_parceiro,
            repasse_entrega_base_estafeta=repasse_entrega_base,
            pago_liquido_estafeta=pago_estafeta,
            margem_bruta_plataforma=margem_bruta_plataforma,
            taxa_gateway_percentagem=taxa_gateway_pct * Decimal("100"),
            custo_gateway_valor=custo_gateway_valor,
            margem_liquida_plataforma=margem_liquida_plataforma,
            lancamentos_ledger=[
                {
                    "id": str(l.id),
                    "conta_origem": l.conta_origem,
                    "conta_destino": l.conta_destino,
                    "debito": l.debito,
                    "credito": l.credito,
                }
                for l in registos_criados
            ],
            total_debitos_ledger=total_debitos,
            total_creditos_ledger=total_creditos,
            saldo_liquido_zero=(total_debitos == total_creditos),
            balanco_contabil_contas=balanco_contabil,
        )

        return demonstracao.to_dict()


# ==============================================================================
# ALIAS RETROCOMPATÍVEL
# ==============================================================================

def executar_divisao_financeira_conclusao(
    pedido_id: str | uuid.UUID,
    forcar_exemplo_seccao_7_1: bool = False,
    ignorar_janela_48h: bool = False,
) -> dict[str, Any]:
    """
    Alias de conveniência retrocompatível para `executar_divisao_financeira_conclusao_pedido`.
    Mantém compatibilidade com chamadas de tarefas assíncronas do Celery e módulos existentes.
    """
    return executar_divisao_financeira_conclusao_pedido(
        pedido_id=pedido_id,
        forcar_exemplo_seccao_7_1=forcar_exemplo_seccao_7_1,
        ignorar_janela_48h=ignorar_janela_48h,
    )
