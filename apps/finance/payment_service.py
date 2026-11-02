"""
Serviço Puro de Integração com Gateway de Pagamentos e Segurança PCI DSS ('finance').
Implementa rigorosamente:
- RN-065: Métodos de pagamento homologados (Cartão, Carteira Digital, Numerário);
- RN-066: Ciclo de vida transacional (Pré-autorização no checkout, Captura final na entrega
  e Cancelamento/Libertação imediata em caso de desistência);
- RN-067: Proteção contra fraude com bloqueio temporário após 3 tentativas falhadas consecutivas;
- RN-068: Conformidade estrita com o PCI DSS (tokenização opaca, proibição absoluta de persistir
  PAN, CVV ou dados sensíveis do cartão na base de dados relacional);
- RN-070: Estorno e libertação imediata de retenções bancárias;
- RN-073: Registo e estruturação de logs para reconciliação financeira diária.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import uuid
from datetime import timedelta
from decimal import Decimal
from typing import Any

from django.conf import settings
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.finance.models import EventoPedido
from apps.orders.models import Pedido
from apps.orders.state_machine_manager import OrderStateMachineManager

logger = logging.getLogger("finance.payment_gateway")


# =============================================================================
# EXCEÇÕES CUSTOMIZADAS DO SUBSISTEMA DE PAGAMENTOS
# =============================================================================

class PaymentGatewayException(Exception):
    """Exceção base para falhas operacionais ou de comunicação com o gateway."""

    def __init__(self, mensagem: str, codigo: str = "GATEWAY_ERROR", detalhes: dict[str, Any] | None = None) -> None:
        super().__init__(mensagem)
        self.mensagem = mensagem
        self.codigo = codigo
        self.detalhes = detalhes or {}


class PaymentMethodBlockedException(PaymentGatewayException):
    """RN-067: Lançada quando o método de pagamento/cartão é bloqueado após 3 falhas consecutivas."""

    def __init__(self, mensagem: str, detalhes: dict[str, Any] | None = None) -> None:
        super().__init__(mensagem, codigo="RN-067_PAYMENT_METHOD_BLOCKED", detalhes=detalhes)


class PaymentDeclinedException(PaymentGatewayException):
    """RN-066 / RN-067: Lançada quando a transação é recusada pelo emissor/gateway."""

    def __init__(self, mensagem: str, motivo_recusa: str, detalhes: dict[str, Any] | None = None) -> None:
        detalhes_completos = detalhes or {}
        detalhes_completos["motivo_recusa"] = motivo_recusa
        super().__init__(mensagem, codigo="PAYMENT_DECLINED", detalhes=detalhes_completos)


class PaymentTokenizationException(PaymentGatewayException):
    """RN-068: Lançada quando os dados de cartão fornecidos são inválidos para tokenização."""

    def __init__(self, mensagem: str, detalhes: dict[str, Any] | None = None) -> None:
        super().__init__(mensagem, codigo="RN-068_TOKENIZATION_ERROR", detalhes=detalhes)


class PaymentPreAuthorizationNotFoundException(PaymentGatewayException):
    """RN-066: Lançada quando não existe pré-autorização válida para efetuar a captura definitiva."""

    def __init__(self, mensagem: str, detalhes: dict[str, Any] | None = None) -> None:
        super().__init__(mensagem, codigo="PRE_AUTH_NOT_FOUND", detalhes=detalhes)


# =============================================================================
# SERVIÇO PRINCIPAL: PaymentGatewayIntegrationService
# =============================================================================

class PaymentGatewayIntegrationService:
    """
    Serviço centralizado de gestão do ciclo de vida transacional de pagamentos (PCI DSS, RN-065 a RN-073).
    Simula uma integração síncrona com API de gateway bancário internacional homologado.
    """

    # RN-067: Parâmetros de controlo de tentativas consecutivas de pagamento
    MAX_FAILED_ATTEMPTS: int = 3
    FAILED_ATTEMPTS_TTL_SECONDS: int = 3600      # 1 hora de janela de monitorização
    BLOCKED_METHOD_TTL_SECONDS: int = 7200       # 2 horas de bloqueio temporário após 3 falhas

    # Padrões de chaves Redis
    REDIS_KEY_FAILED_ATTEMPTS = "payment:failed_attempts:{user_id}:{token_hash}"
    REDIS_KEY_BLOCKED_METHOD = "payment:blocked_method:{user_id}:{token_hash}"
    REDIS_KEY_PRE_AUTH = "payment:pre_auth:{pedido_id}"

    # =========================================================================
    # 1. CONFORMIDADE TOKENIZADA PCI DSS (RN-068)
    # =========================================================================

    @classmethod
    def criar_token_cartao(cls, dados_cartao: dict[str, Any]) -> dict[str, Any]:
        """
        RN-068 e PCI DSS:
        Recebe dados brutos simulados do cartão de crédito, valida o formato e o algoritmo de Luhn,
        e retorna um identificador tokenizado opaco (`payment_token`).

        GARANTIA INEGOCIÁVEL DE SEGURANÇA:
        Os dados confidenciais (PAN completo, CVV) NUNCA são gravados em base de dados relacional.
        Apenas o token gerado, a máscara truncada dos últimos 4 dígitos e a data de validade
        podem ser utilizados pela plataforma.
        """
        numero_cartao = re.sub(r"\D", "", str(dados_cartao.get("numero_cartao", "")))
        nome_titular = str(dados_cartao.get("nome_titular", "")).strip()
        mes_exp = dados_cartao.get("mes_expiracao")
        ano_exp = dados_cartao.get("ano_expiracao")
        cvv = str(dados_cartao.get("cvv", "")).strip()

        # Validações estritas de conformidade
        if not numero_cartao or len(numero_cartao) < 13 or len(numero_cartao) > 19:
            raise PaymentTokenizationException(
                _("RN-068: O número do cartão deve conter entre 13 e 19 dígitos numéricos."),
                detalhes={"campo": "numero_cartao"},
            )

        if not cls._validar_algoritmo_luhn(numero_cartao):
            raise PaymentTokenizationException(
                _("RN-068: O número do cartão falhou na verificação de integridade (Luhn)."),
                detalhes={"campo": "numero_cartao"},
            )

        if not nome_titular or len(nome_titular) < 3:
            raise PaymentTokenizationException(
                _("RN-068: O nome do titular do cartão é obrigatório."),
                detalhes={"campo": "nome_titular"},
            )

        try:
            mes_int = int(mes_exp)
            ano_int = int(ano_exp)
        except (ValueError, TypeError) as exc:
            raise PaymentTokenizationException(
                _("RN-068: A data de expiração (mês/ano) contém formato numérico inválido."),
            ) from exc

        if mes_int < 1 or mes_int > 12:
            raise PaymentTokenizationException(_("RN-068: O mês de expiração deve estar entre 1 e 12."))

        agora = timezone.now()
        ano_atual = agora.year
        mes_atual = agora.month

        # Suporta anos fornecidos em 2 dígitos (ex: 26 -> 2026)
        if ano_int < 100:
            ano_int += 2000

        if ano_int < ano_atual or (ano_int == ano_atual and mes_int < mes_atual):
            raise PaymentTokenizationException(_("RN-068: O cartão encontra-se expirado."))

        if not re.match(r"^\d{3,4}$", cvv):
            raise PaymentTokenizationException(_("RN-068: O CVV/CVC deve conter 3 ou 4 dígitos numéricos."))

        bandeira = cls._detectar_bandeira(numero_cartao)
        ultimos_4 = numero_cartao[-4:]
        mascara = f"**** **** **** {ultimos_4}"

        # Gera o payment_token aleatório criptograficamente seguro com prefixo da bandeira
        token_uuid = uuid.uuid4().hex
        payment_token = f"tok_{bandeira.lower()}_{token_uuid}"

        # Registo de log para reconciliação financeira (RN-073) SEM dados sensíveis
        cls._registar_log_reconciliacao(
            tipo_operacao="TOKENIZE",
            pedido_id="N/A",
            gateway_tx_id=payment_token,
            valor_centimos=0,
            status="SUCCESS",
            detalhes={
                "bandeira": bandeira,
                "ultimos_4": ultimos_4,
                "mascara": mascara,
                "pci_dss_compliant": True,
            },
        )

        return {
            "payment_token": payment_token,
            "mascara": mascara,
            "ultimos_4": ultimos_4,
            "bandeira": bandeira,
            "mes_expiracao": mes_int,
            "ano_expiracao": ano_int,
            "status": "TOKENIZED",
            "criado_em": agora.isoformat(),
        }

    # =========================================================================
    # 2. FLUXO DE PRÉ-AUTORIZAÇÃO DE SALDO (RN-066, RN-067)
    # =========================================================================

    @classmethod
    def executar_pre_autorizacao(
        cls,
        pedido_id: str | uuid.UUID,
        payment_token: str,
        dados_adicionais: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """
        RN-066 e RN-067:
        Envia o valor total cobrado do pedido para o gateway para pré-autorização de fundos.
        Se aprovado:
        - Bloqueia os fundos no cartão do cliente com status 'AUTHORIZED';
        - Salva os metadados da transação em Redis;
        - Transita o pedido no Django para '2. PAGAMENTO' via `OrderStateMachineManager`;
        - Regista o evento de auditoria imutável `payment.authorized` (Secção 12.1);
        - Limpa o contador de tentativas falhadas no Redis.
        Se recusado:
        - Incrementa o contador de falhas (RN-067);
        - Se atingir 3 falhas consecutivas, bloqueia temporariamente o método e lança
          `PaymentMethodBlockedException`.
        """
        pedido_id_str = str(pedido_id)

        with transaction.atomic():
            try:
                pedido = Pedido.objects.select_for_update().get(pk=pedido_id)
            except Pedido.DoesNotExist:
                raise PaymentGatewayException(
                    f"Pedido {pedido_id_str} não encontrado para pré-autorização.",
                    codigo="ORDER_NOT_FOUND",
                )

            user_id = str(pedido.cliente_id)
            token_hash = cls._gerar_hash_token(payment_token)

            # RN-067: Verifica se o método de pagamento está temporariamente bloqueado
            if cls._is_metodo_bloqueado(user_id=user_id, token_hash=token_hash):
                ttl_restante = cls._obter_ttl_bloqueio(user_id=user_id, token_hash=token_hash)
                logger.warning(
                    "[RN-067] Tentativa de pagamento com método bloqueado: user=%s, pedido=%s, TTL=%ds",
                    user_id,
                    pedido_id_str,
                    ttl_restante,
                )
                raise PaymentMethodBlockedException(
                    _("RN-067: Este método de pagamento foi temporariamente bloqueado devido a 3 falhas "
                      "consecutivas. Por favor, tente novamente mais tarde ou selecione outro meio de pagamento."),
                    detalhes={
                        "user_id": user_id,
                        "bloqueado_durante_segundos": ttl_restante,
                        "regra": "RN-067",
                    },
                )

            montante_total = pedido.total_cobrado
            agora = timezone.now()

            # Simulação de comunicação síncrona com Gateway Internacional Homologado
            resposta_gateway = cls._simular_comunicacao_gateway(
                operacao="PRE_AUTHORIZE",
                montante=montante_total,
                token=payment_token,
                pedido_id=pedido_id_str,
            )

            # -----------------------------------------------------------------
            # CASO DE RECUSA DO GATEWAY (RN-067)
            # -----------------------------------------------------------------
            if not resposta_gateway["sucesso"]:
                motivo_recusa = resposta_gateway.get("motivo", "Saldo insuficiente ou autenticação recusada")
                falhas_acumuladas = cls._registar_falha_tentativa(user_id=user_id, token_hash=token_hash)

                cls._registar_log_reconciliacao(
                    tipo_operacao="PRE_AUTHORIZE",
                    pedido_id=pedido_id_str,
                    gateway_tx_id=resposta_gateway.get("gateway_transaction_id", "FAILED_AUTH"),
                    valor_centimos=montante_total,
                    status="DECLINED",
                    detalhes={
                        "motivo_recusa": motivo_recusa,
                        "falhas_acumuladas": falhas_acumuladas,
                        "limite_maximo": cls.MAX_FAILED_ATTEMPTS,
                    },
                )

                if falhas_acumuladas >= cls.MAX_FAILED_ATTEMPTS:
                    cls._bloquear_metodo_pagamento(user_id=user_id, token_hash=token_hash)
                    raise PaymentMethodBlockedException(
                        _(f"RN-067: O pagamento falhou {falhas_acumuladas} vezes consecutivas ({motivo_recusa}). "
                          f"O método de pagamento foi bloqueado temporariamente por 2 horas."),
                        detalhes={
                            "user_id": user_id,
                            "tentativas_falhadas": falhas_acumuladas,
                            "motivo_recusa": motivo_recusa,
                        },
                    )

                raise PaymentDeclinedException(
                    mensagem=_(f"O pagamento foi recusado pelo emissor: {motivo_recusa} (tentativa {falhas_acumuladas}/3)."),
                    motivo_recusa=motivo_recusa,
                    detalhes={"falhas_atuais": falhas_acumuladas, "restantes": cls.MAX_FAILED_ATTEMPTS - falhas_acumuladas},
                )

            # -----------------------------------------------------------------
            # CASO DE APROVAÇÃO DO GATEWAY (RN-066)
            # -----------------------------------------------------------------
            # Limpa qualquer histórico de falhas consecutivas deste método
            cls._limpar_falhas(user_id=user_id, token_hash=token_hash)

            gateway_tx_id = resposta_gateway["gateway_transaction_id"]
            codigo_autorizacao = resposta_gateway["codigo_autorizacao"]

            # Guarda o registo da pré-autorização ativa na cache Redis (validade 7 dias)
            chave_pre_auth = cls.REDIS_KEY_PRE_AUTH.format(pedido_id=pedido_id_str)
            dados_pre_auth = {
                "gateway_transaction_id": gateway_tx_id,
                "codigo_autorizacao": codigo_autorizacao,
                "pedido_id": pedido_id_str,
                "payment_token": payment_token,
                "valor_centimos": montante_total,
                "moeda": "KZ",
                "status": "AUTHORIZED",
                "autorizado_em": agora.isoformat(),
                "expira_em": (agora + timedelta(days=7)).isoformat(),
            }
            cache.set(chave_pre_auth, dados_pre_auth, timeout=7 * 86400)

            # Transição na Máquina de Estados OMS: CRIADO -> 2. PAGAMENTO
            if pedido.estado == Pedido.EstadoPedido.CRIADO:
                OrderStateMachineManager.transitar_estado(
                    pedido_id=pedido.id,
                    novo_estado=Pedido.EstadoPedido.PAGAMENTO,
                    ator="GATEWAY:PAGAMENTOS",
                    dados_adicionais={
                        "gateway_transaction_id": gateway_tx_id,
                        "codigo_autorizacao": codigo_autorizacao,
                        "status_gateway": "AUTHORIZED",
                        "valor_bloqueado": montante_total,
                        "regra": "RN-066",
                    },
                )

            # Emissão do evento de auditoria imutável payment.authorized (Secção 12.1)
            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.PAYMENT_AUTHORIZED,
                autor="GATEWAY:SISTEMA_PAGAMENTOS",
                dados_adicionais={
                    "gateway_transaction_id": gateway_tx_id,
                    "codigo_autorizacao": codigo_autorizacao,
                    "status": "AUTHORIZED",
                    "valor_bloqueado": montante_total,
                    "payment_token": payment_token,
                    "regra": "RN-066",
                },
            )

            # Registo nos logs de reconciliação financeira (RN-073)
            cls._registar_log_reconciliacao(
                tipo_operacao="PRE_AUTHORIZE",
                pedido_id=pedido_id_str,
                gateway_tx_id=gateway_tx_id,
                valor_centimos=montante_total,
                status="AUTHORIZED",
                detalhes={
                    "codigo_autorizacao": codigo_autorizacao,
                    "user_id": user_id,
                    "sucesso": True,
                },
            )

            logger.info(
                "[RN-066] Pré-autorização aprovada com sucesso para pedido %s: Tx=%s, Valor=%d cêntimos",
                pedido_id_str,
                gateway_tx_id,
                montante_total,
            )

            return {
                "status": "AUTHORIZED",
                "pedido_id": pedido_id_str,
                "gateway_transaction_id": gateway_tx_id,
                "codigo_autorizacao": codigo_autorizacao,
                "valor_autorizado": montante_total,
                "moeda": "KZ",
                "autorizado_em": agora.isoformat(),
            }

    # =========================================================================
    # 3. FLUXO DE CAPTURA DEFINITIVA (RN-066, RN-073)
    # =========================================================================

    @classmethod
    def capturar_pagamento_final(
        cls,
        pedido_id: str | uuid.UUID,
        valor_captura: int | None = None,
    ) -> dict[str, Any]:
        """
        RN-066 e RN-073:
        Efetua a liquidação e captura definitiva dos fundos pré-autorizados.
        Executado de forma automática assim que o pedido é entregue com PIN válido
        ou na transição para '10. CONCLUÍDO'.
        Transforma o status de 'AUTHORIZED' para 'CAPTURED', emitindo o evento
        imutável `payment.captured` e registando os dados de reconciliação financeira.
        """
        pedido_id_str = str(pedido_id)

        with transaction.atomic():
            try:
                pedido = Pedido.objects.select_for_update().get(pk=pedido_id)
            except Pedido.DoesNotExist:
                raise PaymentGatewayException(
                    f"Pedido {pedido_id_str} não encontrado para captura.",
                    codigo="ORDER_NOT_FOUND",
                )

            # Recupera a pré-autorização ativa na cache Redis
            chave_pre_auth = cls.REDIS_KEY_PRE_AUTH.format(pedido_id=pedido_id_str)
            dados_pre_auth: dict[str, Any] | None = cache.get(chave_pre_auth)

            if not dados_pre_auth:
                raise PaymentPreAuthorizationNotFoundException(
                    _(f"RN-066: Nenhuma pré-autorização ativa encontrada em cache para o pedido {pedido_id_str}."),
                    detalhes={"pedido_id": pedido_id_str},
                )

            if dados_pre_auth.get("status") == "CAPTURED":
                logger.info("[RN-066] O pedido %s já se encontra capturado (idempotência).", pedido_id_str)
                return {
                    "status": "ALREADY_CAPTURED",
                    "pedido_id": pedido_id_str,
                    "gateway_transaction_id": dados_pre_auth["gateway_transaction_id"],
                }

            if dados_pre_auth.get("status") != "AUTHORIZED":
                raise PaymentGatewayException(
                    _(f"RN-066: O estado da pré-autorização ({dados_pre_auth.get('status')}) "
                      f"não permite captura definitiva."),
                    codigo="INVALID_PRE_AUTH_STATE",
                )

            montante_captura = valor_captura or dados_pre_auth["valor_centimos"]
            gateway_auth_id = dados_pre_auth["gateway_transaction_id"]

            # Comunicação síncrona com o gateway para liquidação definitiva
            resposta_gateway = cls._simular_comunicacao_gateway(
                operacao="CAPTURE",
                montante=montante_captura,
                token=dados_pre_auth["payment_token"],
                pedido_id=pedido_id_str,
                gateway_tx_id=gateway_auth_id,
            )

            if not resposta_gateway["sucesso"]:
                raise PaymentGatewayException(
                    _(f"Falha na captura definitiva no gateway: {resposta_gateway.get('motivo')}."),
                    codigo="CAPTURE_FAILED",
                    detalhes=resposta_gateway,
                )

            agora = timezone.now()
            capture_tx_id = resposta_gateway.get("capture_transaction_id", f"gtw_cap_{uuid.uuid4().hex}")

            # Atualiza o estado da pré-autorização para CAPTURED
            dados_pre_auth["status"] = "CAPTURED"
            dados_pre_auth["capture_transaction_id"] = capture_tx_id
            dados_pre_auth["capturado_em"] = agora.isoformat()
            dados_pre_auth["valor_capturado"] = montante_captura
            cache.set(chave_pre_auth, dados_pre_auth, timeout=30 * 86400)

            # Emissão do evento de auditoria imutável payment.captured (Secção 12.1)
            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.PAYMENT_CAPTURED,
                autor="GATEWAY:SISTEMA_PAGAMENTOS",
                dados_adicionais={
                    "gateway_auth_id": gateway_auth_id,
                    "capture_transaction_id": capture_tx_id,
                    "status": "CAPTURED",
                    "valor_capturado": montante_captura,
                    "moeda": "KZ",
                    "regra": "RN-066",
                },
            )

            # Registo nos logs estruturados para reconciliação financeira diária (RN-073)
            cls._registar_log_reconciliacao(
                tipo_operacao="CAPTURE",
                pedido_id=pedido_id_str,
                gateway_tx_id=capture_tx_id,
                valor_centimos=montante_captura,
                status="CAPTURED",
                detalhes={
                    "gateway_auth_id": gateway_auth_id,
                    "user_id": str(pedido.cliente_id),
                    "sucesso": True,
                },
            )

            logger.info(
                "[RN-066] Captura definitiva concluída para pedido %s: Tx=%s, Valor=%d cêntimos",
                pedido_id_str,
                capture_tx_id,
                montante_captura,
            )

            return {
                "status": "CAPTURED",
                "pedido_id": pedido_id_str,
                "gateway_transaction_id": gateway_auth_id,
                "capture_transaction_id": capture_tx_id,
                "valor_capturado": montante_captura,
                "capturado_em": agora.isoformat(),
            }

    # =========================================================================
    # 4. LIBERTAÇÃO E CANCELAMENTO DE PRÉ-AUTORIZAÇÃO (RN-066, RN-070)
    # =========================================================================

    @classmethod
    def cancelar_pre_autorizacao(
        cls,
        pedido_id: str | uuid.UUID,
        motivo: str = "Cancelamento do pedido antes da preparação",
    ) -> dict[str, Any]:
        """
        RN-066 e RN-070:
        Desfaz imediatamente a retenção de saldo no cartão do cliente caso o pedido
        seja cancelado antes da preparação ou saída física da loja.
        Envia a instrução de void/cancel ao gateway, liberta os fundos do cliente e
        emite o registo de auditoria `payment.refunded`.
        """
        pedido_id_str = str(pedido_id)

        with transaction.atomic():
            try:
                pedido = Pedido.objects.select_for_update().get(pk=pedido_id)
            except Pedido.DoesNotExist:
                raise PaymentGatewayException(
                    f"Pedido {pedido_id_str} não encontrado para libertação de fundos.",
                    codigo="ORDER_NOT_FOUND",
                )

            chave_pre_auth = cls.REDIS_KEY_PRE_AUTH.format(pedido_id=pedido_id_str)
            dados_pre_auth: dict[str, Any] | None = cache.get(chave_pre_auth)

            agora = timezone.now()

            if not dados_pre_auth:
                logger.warning(
                    "[RN-070] Nenhuma pré-autorização encontrada em cache para o pedido %s. Cancelamento lógico.",
                    pedido_id_str,
                )
                return {"status": "NO_PRE_AUTH_RECORDED", "pedido_id": pedido_id_str}

            status_atual = dados_pre_auth.get("status")
            gateway_tx_id = dados_pre_auth.get("gateway_transaction_id", "")
            valor_centimos = dados_pre_auth.get("valor_centimos", pedido.total_cobrado)

            # Se já estava libertado ou reembolsado
            if status_atual in ("VOIDED", "CANCELLED", "REFUNDED"):
                logger.info("[RN-070] Pré-autorização do pedido %s já se encontrava %s.", pedido_id_str, status_atual)
                return {
                    "status": status_atual,
                    "pedido_id": pedido_id_str,
                    "gateway_transaction_id": gateway_tx_id,
                }

            # Simula comunicação com Gateway para desfazer a pré-autorização (Void)
            resposta_gateway = cls._simular_comunicacao_gateway(
                operacao="VOID",
                montante=valor_centimos,
                token=dados_pre_auth.get("payment_token", ""),
                pedido_id=pedido_id_str,
                gateway_tx_id=gateway_tx_id,
            )

            void_tx_id = resposta_gateway.get("void_transaction_id", f"gtw_void_{uuid.uuid4().hex}")

            # Atualiza o estado em cache Redis para VOIDED
            dados_pre_auth["status"] = "VOIDED"
            dados_pre_auth["void_transaction_id"] = void_tx_id
            dados_pre_auth["cancelado_em"] = agora.isoformat()
            dados_pre_auth["motivo_cancelamento"] = motivo
            cache.set(chave_pre_auth, dados_pre_auth, timeout=30 * 86400)

            # Emissão do evento de auditoria imutável payment.refunded (Secção 12.1)
            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.PAYMENT_REFUNDED,
                autor="GATEWAY:SISTEMA_PAGAMENTOS",
                dados_adicionais={
                    "gateway_transaction_id": gateway_tx_id,
                    "void_transaction_id": void_tx_id,
                    "status": "VOIDED",
                    "valor_estornado": valor_centimos,
                    "motivo": motivo,
                    "regra": "RN-066 / RN-070",
                },
            )

            # Registo nos logs de reconciliação financeira (RN-073)
            cls._registar_log_reconciliacao(
                tipo_operacao="VOID",
                pedido_id=pedido_id_str,
                gateway_tx_id=void_tx_id,
                valor_centimos=valor_centimos,
                status="VOIDED",
                detalhes={
                    "motivo": motivo,
                    "gateway_auth_id": gateway_tx_id,
                    "user_id": str(pedido.cliente_id),
                },
            )

            logger.info(
                "[RN-070] Pré-autorização libertada/anulada para pedido %s: VoidTx=%s, Valor=%d",
                pedido_id_str,
                void_tx_id,
                valor_centimos,
            )

            return {
                "status": "VOIDED",
                "pedido_id": pedido_id_str,
                "gateway_transaction_id": gateway_tx_id,
                "void_transaction_id": void_tx_id,
                "valor_libertado": valor_centimos,
                "cancelado_em": agora.isoformat(),
            }

    # =========================================================================
    # 5. MÉTODOS INTERNOS: GESTÃO DE BLOQUEIOS E TENTATIVAS (RN-067)
    # =========================================================================

    @classmethod
    def _gerar_hash_token(cls, payment_token: str) -> str:
        """Gera um hash SHA-256 do token para chaves de controlo em Redis."""
        return hashlib.sha256(str(payment_token).encode("utf-8")).hexdigest()[:16]

    @classmethod
    def _is_metodo_bloqueado(cls, user_id: str, token_hash: str) -> bool:
        """RN-067: Verifica se o método de pagamento está temporariamente bloqueado."""
        chave = cls.REDIS_KEY_BLOCKED_METHOD.format(user_id=user_id, token_hash=token_hash)
        return bool(cache.get(chave))

    @classmethod
    def _obter_ttl_bloqueio(cls, user_id: str, token_hash: str) -> int:
        """Obtém o tempo restante de bloqueio em segundos."""
        chave = cls.REDIS_KEY_BLOCKED_METHOD.format(user_id=user_id, token_hash=token_hash)
        # Fallback de aproximação se o Redis nativo TTL não estiver exposto
        return cls.BLOCKED_METHOD_TTL_SECONDS

    @classmethod
    def _bloquear_metodo_pagamento(cls, user_id: str, token_hash: str) -> None:
        """RN-067: Bloqueia o método de pagamento em cache Redis por 2 horas."""
        chave = cls.REDIS_KEY_BLOCKED_METHOD.format(user_id=user_id, token_hash=token_hash)
        cache.set(chave, True, timeout=cls.BLOCKED_METHOD_TTL_SECONDS)
        logger.error(
            "[RN-067] MÉTODO DE PAGAMENTO BLOQUEADO TEMPORARIAMENTE: user=%s, token_hash=%s (TTL: %ds)",
            user_id,
            token_hash,
            cls.BLOCKED_METHOD_TTL_SECONDS,
        )

    @classmethod
    def _registar_falha_tentativa(cls, user_id: str, token_hash: str) -> int:
        """
        RN-067: Incrementa o contador de tentativas falhadas no Redis.
        Retorna o total acumulado de falhas consecutivas.
        """
        chave = cls.REDIS_KEY_FAILED_ATTEMPTS.format(user_id=user_id, token_hash=token_hash)
        falhas_atuais = cache.get(chave) or 0
        novas_falhas = int(falhas_atuais) + 1
        cache.set(chave, novas_falhas, timeout=cls.FAILED_ATTEMPTS_TTL_SECONDS)
        return novas_falhas

    @classmethod
    def _limpar_falhas(cls, user_id: str, token_hash: str) -> None:
        """Limpa o contador de falhas e qualquer bloqueio após transação bem-sucedida."""
        chave_falhas = cls.REDIS_KEY_FAILED_ATTEMPTS.format(user_id=user_id, token_hash=token_hash)
        chave_bloqueio = cls.REDIS_KEY_BLOCKED_METHOD.format(user_id=user_id, token_hash=token_hash)
        cache.delete(chave_falhas)
        cache.delete(chave_bloqueio)

    # =========================================================================
    # 6. AUXILIARES: LUHN, BANDEIRA E LOG DE RECONCILIAÇÃO (RN-068, RN-073)
    # =========================================================================

    @staticmethod
    def _validar_algoritmo_luhn(numero: str) -> bool:
        """Valida o dígito de controlo pelo algoritmo de Luhn (Módulo 10)."""
        soma = 0
        par = False
        for digito in reversed(numero):
            d = int(digito)
            if par:
                d *= 2
                if d > 9:
                    d -= 9
            soma += d
            par = not par
        return (soma % 10) == 0

    @staticmethod
    def _detectar_bandeira(numero: str) -> str:
        """Deteta a bandeira do cartão com base nos prefixos IIN/BIN."""
        if numero.startswith("4"):
            return "VISA"
        elif re.match(r"^5[1-5]", numero) or re.match(r"^2(22[1-9]|2[3-9]\d|[3-6]\d{2}|7[01]\d|720)", numero):
            return "MASTERCARD"
        elif numero.startswith(("34", "37")):
            return "AMEX"
        elif numero.startswith("06"):
            return "MULTICAIXA"
        return "OUTRA"

    @classmethod
    def _simular_comunicacao_gateway(
        cls,
        operacao: str,
        montante: int,
        token: str,
        pedido_id: str,
        gateway_tx_id: str | None = None,
    ) -> dict[str, Any]:
        """
        Simula a resposta síncrona de um gateway bancário internacional homologado.
        Tokens contendo 'declined' ou 'recusado' simulam recusas por saldo insuficiente (para testes).
        """
        if "declined" in token.lower() or "recusado" in token.lower():
            return {
                "sucesso": False,
                "codigo_erro": "INSUFFICIENT_FUNDS",
                "motivo": "Saldo insuficiente na conta do cartão",
                "gateway_transaction_id": f"gtw_dec_{uuid.uuid4().hex[:12]}",
            }

        if operacao == "PRE_AUTHORIZE":
            return {
                "sucesso": True,
                "gateway_transaction_id": f"gtw_auth_{uuid.uuid4().hex[:16]}",
                "codigo_autorizacao": f"AUTH_{uuid.uuid4().hex[:6].upper()}",
                "status": "AUTHORIZED",
                "montante": montante,
            }
        elif operacao == "CAPTURE":
            return {
                "sucesso": True,
                "capture_transaction_id": f"gtw_cap_{uuid.uuid4().hex[:16]}",
                "status": "CAPTURED",
                "montante": montante,
            }
        elif operacao == "VOID":
            return {
                "sucesso": True,
                "void_transaction_id": f"gtw_void_{uuid.uuid4().hex[:16]}",
                "status": "VOIDED",
                "montante": montante,
            }

        return {"sucesso": True}

    @classmethod
    def _registar_log_reconciliacao(
        cls,
        tipo_operacao: str,
        pedido_id: str,
        gateway_tx_id: str,
        valor_centimos: int,
        status: str,
        detalhes: dict[str, Any],
    ) -> None:
        """
        RN-073: Regista uma entrada de log estruturada em formato JSON para fins
        de reconciliação financeira diária e auditoria bancária externa.
        """
        agora = timezone.now()
        registro_reconciliacao = {
            "timestamp": agora.isoformat(),
            "modulo": "PAYMENT_GATEWAY",
            "tipo_operacao": tipo_operacao,
            "pedido_id": str(pedido_id),
            "gateway_tx_id": str(gateway_tx_id),
            "valor_unidades_minimas": valor_centimos,
            "moeda": "KZ",
            "status": status,
            "detalhes": detalhes,
        }
        # Emite no canal de log estruturado para exportação a SIEM / ELK / CloudWatch
        logger.info("[RECONCILIACAO_FINANCEIRA_RN073] %s", json.dumps(registro_reconciliacao, default=str))

        # Também guarda em Redis por 24 horas para auditorias imediatas da sessão diária
        data_str = agora.strftime("%Y-%m-%d")
        cache_key_log = f"payment:reconciliation:{data_str}:{gateway_tx_id}"
        cache.set(cache_key_log, registro_reconciliacao, timeout=86400)
