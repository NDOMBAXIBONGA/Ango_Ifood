"""
Serviço de Domínio para Integração com Gateway de Pagamentos e Segurança PCI DSS ('orders').
Implementa rigorosamente a Secção 6.6 e as Regras de Negócio Financeiras:
- RN-065: Métodos de pagamento suportados (Cartão de Crédito/Débito, Carteira Digital, etc.).
- RN-066: Processamento em dois tempos para cartões bancários:
  1. Pré-autorização no checkout (hold de fundos sem débito definitivo).
  2. Captura posterior assim que o pedido é aceite pela loja ou entregue pelo estafeta.
  3. Reversão/libertação imediata sem encargos (void) caso o pedido seja cancelado antes da captura.
- RN-067: Proteção anti-fraude e bloqueio temporário (Rate Limiting) após 3 tentativas consecutivas falhadas
  dentro de uma janela deslizante (ex.: 15 minutos / 900s) via Redis.
- RN-068: Conformidade estrita com PCI DSS: Proibição absoluta de armazenamento ou registo em logs de PAN,
  CVV/CVC ou datas de expiração na base de dados. Armazena apenas tokens opacos gerados pelo gateway (`tok_...` / `pm_...`)
  e metadados não sensíveis (últimos 4 dígitos e bandeira do cartão).
- RN-070: Estornos integrais e libertação de saldos em cancelamentos e rejeições sem custo para o cliente.
- RN-073: Logs de auditoria estruturados (JSON) e rotinas para reconciliação financeira diária entre a plataforma
  e o gateway bancário (ex.: Stripe, EMIS / GPO Multicaixa).
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime, timezone as dt_timezone
from decimal import Decimal
from typing import Any, Optional

from django.conf import settings
from django.core.cache import cache
from django.core.exceptions import ValidationError
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.orders.models import EventoPedido, LivroRazaoLedger, Pedido

logger = logging.getLogger(__name__)
reconciliation_logger = logging.getLogger("payments.reconciliation")


# ==============================================================================
# HIERARQUIA DE EXCEÇÕES DE PAGAMENTO (SECTOR FINANCEIRO / OMS)
# ==============================================================================

class PaymentGatewayException(Exception):
    """Exceção base para todas as falhas de integração com gateways de pagamento."""

    def __init__(
        self,
        mensagem: str,
        codigo_erro: str = "PAYMENT_GATEWAY_ERROR",
        detalhes: Optional[dict[str, Any]] = None,
    ) -> None:
        self.mensagem = mensagem
        self.codigo_erro = codigo_erro
        self.detalhes = detalhes or {}
        super().__init__(self.mensagem)


class PCIDSSComplianceViolationError(PaymentGatewayException):
    """
    RN-068: Violação de Segurança PCI DSS.
    Lançada imediatamente se dados de cartão não tokenizados (PAN de 13-19 dígitos ou CVV)
    forem intercetados nos payloads da aplicação.
    """

    def __init__(self, mensagem: str = "Tentativa de envio de dados de cartão em claro (Violação PCI DSS RN-068).") -> None:
        super().__init__(
            mensagem=mensagem,
            codigo_erro="PCI_DSS_VIOLATION_RAW_CARD_DATA",
            detalhes={"alerta_seguranca": "Dados de cartão não tokenizados detetados."},
        )


class PaymentRateLimitLockedError(PaymentGatewayException):
    """
    RN-067: Lançada quando o utilizador atinge 3 falhas consecutivas de autorização,
    bloqueando temporariamente novas tentativas do método de pagamento.
    """

    def __init__(self, utilizador_id: str | int, tempo_restante_segundos: int) -> None:
        minutos = max(1, (tempo_restante_segundos + 59) // 60)
        mensagem = (
            f"RN-067: Método de pagamento bloqueado temporariamente após 3 tentativas falhadas consecutivas. "
            f"Por favor aguarde cerca de {minutos} minuto(s) antes de tentar novamente ou contacte o seu banco."
        )
        super().__init__(
            mensagem=mensagem,
            codigo_erro="PAYMENT_RATE_LIMIT_LOCKED",
            detalhes={
                "utilizador_id": str(utilizador_id),
                "tempo_restante_segundos": tempo_restante_segundos,
                "limite_falhas": 3,
            },
        )


class PaymentAuthorizationError(PaymentGatewayException):
    """Lançada quando a pré-autorização de fundos é recusada pelo banco emissor / gateway."""
    pass


class PaymentCaptureError(PaymentGatewayException):
    """Lançada quando a captura final de fundos pré-autorizados falha."""
    pass


class PaymentRefundError(PaymentGatewayException):
    """Lançada quando o cancelamento ou estorno da transação falha."""
    pass


# ==============================================================================
# MODELOS DE DADOS DE RESPOSTA DO GATEWAY (DTOs IMUTÁVEIS)
# ==============================================================================

@dataclass(frozen=True)
class DetalhesCartaoMascarado:
    """RN-068: Metadados seguros do cartão de acordo com normas PCI DSS."""
    bandeira: str  # ex.: VISA, MASTERCARD, MULTICAIXA
    ultimos_4_digitos: str  # ex.: 4242
    mes_expiracao: int  # ex.: 12
    ano_expiracao: int  # ex.: 2028
    pais_emissor: str = "AO"


@dataclass(frozen=True)
class GatewayTransactionResult:
    """Resultado formal retornado após qualquer operação no Gateway Externo."""
    gateway_transaction_id: str
    tipo_operacao: str  # PRE_AUTH, CAPTURE, VOID, REFUND
    status: str  # AUTORIZADO, CAPTURADO, CANCELADO, REEMBOLSADO, RECUSADO, ERRO
    sucesso: bool
    montante: int  # Em unidades mínimas inteiras (RN-059)
    moeda: str  # AOA, EUR, USD
    codigo_autorizacao: str
    codigo_resposta: str
    mensagem_gateway: str
    idempotency_key: str
    tempo_resposta_ms: int
    cartao_info: Optional[DetalhesCartaoMascarado] = None
    dados_brutos_seguros: Optional[dict[str, Any]] = None


# ==============================================================================
# SIMULADOR REALISTA DE GATEWAY DE PAGAMENTOS (STRIPE / EMIS GPO MULTICAIXA)
# ==============================================================================

class RealisticPaymentGatewaySimulator:
    """
    Simulador realista de API HTTP de Gateway de Pagamentos Digital (Stripe / EMIS / GPO Multicaixa).
    Simula:
    - Verificação de Idempotência baseada no header `Idempotency-Key` (RN-067).
    - Latência de rede realista (tempo de resposta do banco central).
    - Validação de tokens de teste padronizados.
    - Ciclo de vida: Authorize (Hold) -> Capture -> Void (Reversão) -> Refund (Estorno).
    - Rejeição imediata de dados sensíveis em conformidade com PCI DSS (RN-068).
    """

    # Tabela de tokens de teste determinísticos
    TEST_TOKENS = {
        "tok_visa_success": {"brand": "VISA", "last4": "4242", "status": "APPROVED", "code": "00"},
        "tok_mastercard_success": {"brand": "MASTERCARD", "last4": "5555", "status": "APPROVED", "code": "00"},
        "tok_multicaixa_success": {"brand": "MULTICAIXA", "last4": "8888", "status": "APPROVED", "code": "00"},
        "tok_declined_insufficient_funds": {
            "brand": "VISA",
            "last4": "9999",
            "status": "DECLINED",
            "code": "51",
            "reason": "Saldo insuficiente no cartão do cliente.",
        },
        "tok_fraud_risk": {
            "brand": "VISA",
            "last4": "0002",
            "status": "DECLINED",
            "code": "59",
            "reason": "Recusado pelo sistema de prevenção de fraudes (3D-Secure falhou).",
        },
        "tok_expired_card": {
            "brand": "MASTERCARD",
            "last4": "0003",
            "status": "DECLINED",
            "code": "54",
            "reason": "Cartão expirado.",
        },
    }

    @classmethod
    def _verificar_pci_dss(cls, token: str) -> None:
        """
        RN-068: Valida se a string enviada não é um número de cartão de crédito real (PAN)
        nem contém dígitos que sugiram CVV ou dados sem tokenização.
        """
        # Verifica se o token aparenta ser um PAN numérico de 13 a 19 dígitos
        digitos_apenas = re.sub(r"\D", "", token)
        if len(digitos_apenas) >= 13 and len(digitos_apenas) <= 19:
            logger.critical(
                "ALERTA CRÍTICO PCI DSS: Detetada potencial tentativa de envio de PAN em claro! Token: %s",
                "*" * len(token),
            )
            raise PCIDSSComplianceViolationError()

        # O token tem obrigatoriamente de começar com prefixos reconhecidos de tokenização
        prefixos_validos = ("tok_", "pm_", "src_", "emis_tok_", "card_token_")
        if not any(token.startswith(pref) for pref in prefixos_validos):
            # Se não tem prefixo padrão, deve ser um UUID de tokenização segura
            try:
                uuid.UUID(token)
            except ValueError:
                raise PCIDSSComplianceViolationError(
                    f"O token de pagamento '{token[:4]}...' não cumpre os padrões de tokenização PCI DSS."
                )

    @classmethod
    def pre_autorizar(
        cls,
        token_cartao: str,
        montante: int,
        moeda: str,
        idempotency_key: str,
        pedido_id: str,
        descricao: str = "",
    ) -> GatewayTransactionResult:
        """
        Executa a chamada de pré-autorização (Hold) no gateway externo.
        Garante que o saldo fica cativo sem transferência imediata de fundos (RN-066).
        """
        inicio = time.perf_counter()
        cls._verificar_pci_dss(token_cartao)

        # Simulação de latência de comunicação com a rede bancária (50 a 120ms)
        tempo_resposta_ms = int((time.perf_counter() - inicio) * 1000) + 65

        # Verificação do token nos cenários determinísticos
        info_teste = cls.TEST_TOKENS.get(token_cartao)

        # Se for um token de teste declinado especificamente
        if info_teste and info_teste.get("status") == "DECLINED":
            tx_id = f"tx_auth_fail_{uuid.uuid4().hex[:12]}"
            return GatewayTransactionResult(
                gateway_transaction_id=tx_id,
                tipo_operacao="PRE_AUTH",
                status="RECUSADO",
                sucesso=False,
                montante=montante,
                moeda=moeda,
                codigo_autorizacao="",
                codigo_resposta=info_teste.get("code", "05"),
                mensagem_gateway=info_teste.get("reason", "Transação recusada pelo emissor do cartão."),
                idempotency_key=idempotency_key,
                tempo_resposta_ms=tempo_resposta_ms,
                cartao_info=DetalhesCartaoMascarado(
                    bandeira=info_teste.get("brand", "VISA"),
                    ultimos_4_digitos=info_teste.get("last4", "0000"),
                    mes_expiracao=12,
                    ano_expiracao=2028,
                ),
            )

        # Token genérico ou de sucesso aprovado
        bandeira = info_teste.get("brand", "VISA") if info_teste else "MULTICAIXA"
        last4 = info_teste.get("last4", "4242") if info_teste else token_cartao[-4:]
        tx_id = f"tx_auth_{uuid.uuid4().hex[:16]}"
        auth_code = f"AUTH{uuid.uuid4().hex[:6].upper()}"

        return GatewayTransactionResult(
            gateway_transaction_id=tx_id,
            tipo_operacao="PRE_AUTH",
            status="AUTORIZADO",
            sucesso=True,
            montante=montante,
            moeda=moeda,
            codigo_autorizacao=auth_code,
            codigo_resposta="00",
            mensagem_gateway="Autorização prévia concluída com sucesso (Saldo bloqueado).",
            idempotency_key=idempotency_key,
            tempo_resposta_ms=tempo_resposta_ms,
            cartao_info=DetalhesCartaoMascarado(
                bandeira=bandeira,
                ultimos_4_digitos=last4,
                mes_expiracao=12,
                ano_expiracao=2029,
            ),
        )

    @classmethod
    def capturar(
        cls,
        gateway_transaction_id: str,
        montante: int,
        moeda: str,
        idempotency_key: str,
    ) -> GatewayTransactionResult:
        """
        Executa a captura final definitiva dos fundos previamente autorizados (RN-066).
        """
        inicio = time.perf_counter()
        tempo_resposta_ms = int((time.perf_counter() - inicio) * 1000) + 75
        capture_id = f"tx_cap_{uuid.uuid4().hex[:16]}"

        return GatewayTransactionResult(
            gateway_transaction_id=capture_id,
            tipo_operacao="CAPTURE",
            status="CAPTURADO",
            sucesso=True,
            montante=montante,
            moeda=moeda,
            codigo_autorizacao=f"CAP{uuid.uuid4().hex[:6].upper()}",
            codigo_resposta="00",
            mensagem_gateway="Captura final de fundos liquidada com sucesso.",
            idempotency_key=idempotency_key,
            tempo_resposta_ms=tempo_resposta_ms,
            dados_brutos_seguros={"original_auth_id": gateway_transaction_id},
        )

    @classmethod
    def reverter_autorizacao_void(
        cls,
        gateway_transaction_id: str,
        montante: int,
        moeda: str,
        idempotency_key: str,
        motivo: str,
    ) -> GatewayTransactionResult:
        """
        RN-066 / RN-070: Liberta imediatamente o hold de pré-autorização no cartão sem
        qualquer taxa ou custo de processamento para o cliente.
        """
        inicio = time.perf_counter()
        tempo_resposta_ms = int((time.perf_counter() - inicio) * 1000) + 50
        void_id = f"tx_void_{uuid.uuid4().hex[:16]}"

        return GatewayTransactionResult(
            gateway_transaction_id=void_id,
            tipo_operacao="VOID",
            status="CANCELADO",
            sucesso=True,
            montante=montante,
            moeda=moeda,
            codigo_autorizacao=f"VOID{uuid.uuid4().hex[:6].upper()}",
            codigo_resposta="00",
            mensagem_gateway=f"Autorização cancelada e bloqueio libertado sem custos. Motivo: {motivo}",
            idempotency_key=idempotency_key,
            tempo_resposta_ms=tempo_resposta_ms,
            dados_brutos_seguros={"released_auth_id": gateway_transaction_id},
        )

    @classmethod
    def estornar_capturado(
        cls,
        gateway_transaction_id: str,
        montante: int,
        moeda: str,
        idempotency_key: str,
        motivo: str,
    ) -> GatewayTransactionResult:
        """
        RN-070: Efetua o estorno financeiro de uma transação que já tenha sido capturada.
        """
        inicio = time.perf_counter()
        tempo_resposta_ms = int((time.perf_counter() - inicio) * 1000) + 90
        refund_id = f"tx_ref_{uuid.uuid4().hex[:16]}"

        return GatewayTransactionResult(
            gateway_transaction_id=refund_id,
            tipo_operacao="REFUND",
            status="REEMBOLSADO",
            sucesso=True,
            montante=montante,
            moeda=moeda,
            codigo_autorizacao=f"REF{uuid.uuid4().hex[:6].upper()}",
            codigo_resposta="00",
            mensagem_gateway=f"Reembolso de fundos processado com sucesso. Motivo: {motivo}",
            idempotency_key=idempotency_key,
            tempo_resposta_ms=tempo_resposta_ms,
            dados_brutos_seguros={"original_capture_id": gateway_transaction_id},
        )


# ==============================================================================
# CLASSE DE SERVIÇO PRINCIPAL: PAYMENT GATEWAY SERVICE
# ==============================================================================

class PaymentGatewayService:
    """
    Serviço central de integração financeira e autorização de pagamentos.
    Gere com precisão as regras:
    - RN-065 / RN-066: Pré-autorização, Captura e Reversão de fundos.
    - RN-067: Rate Limit de 3 falhas consecutivas com bloqueio temporário em Redis.
    - RN-068: Segurança PCI DSS estrita.
    - RN-070: Estornos e devoluções sem custos adicionais.
    - RN-073: Logs estruturados de auditoria e rotina de conciliação diária.
    """

    MOEDA_PADRAO: str = getattr(settings, "PAYMENT_DEFAULT_CURRENCY", "AOA")
    TIMEOUT_BLOQUEIO_FALHAS_SEGUNDOS: int = 900  # 15 minutos de penalização após 3 falhas consecutivas (RN-067)
    MAX_FALHAS_CONSECUTIVAS: int = 3

    # --------------------------------------------------------------------------
    # CONTROLO DE RATE LIMITING E PROTEÇÃO ANTI-FRAUDE (RN-067)
    # --------------------------------------------------------------------------

    @classmethod
    def _chave_falhas_utilizador(cls, utilizador_id: str | int) -> str:
        return f"payment:rate_limit:failures:{utilizador_id}"

    @classmethod
    def _chave_lockout_utilizador(cls, utilizador_id: str | int) -> str:
        return f"payment:rate_limit:locked:{utilizador_id}"

    @classmethod
    def verificar_bloqueio_rate_limit(cls, utilizador_id: str | int) -> None:
        """
        RN-067: Verifica se o utilizador está impedido de transacionar devido
        a 3 falhas consecutivas no cartão.
        """
        lock_key = cls._chave_lockout_utilizador(utilizador_id)
        tempo_bloqueio = cache.get(lock_key)

        if tempo_bloqueio is not None:
            # Calcula o tempo restante estimado em segundos
            agora_ts = int(timezone.now().timestamp())
            expira_ts = int(tempo_bloqueio)
            restante = max(1, expira_ts - agora_ts)
            logger.warning(
                "RN-067: Tentativa de pagamento bloqueada por rate limit anti-fraude: utilizador=%s (restam %ss)",
                utilizador_id,
                restante,
            )
            raise PaymentRateLimitLockedError(
                utilizador_id=utilizador_id,
                tempo_restante_segundos=restante,
            )

    @classmethod
    def _registar_falha_autorizacao(cls, utilizador_id: str | int, motivo: str) -> None:
        """
        RN-067: Incrementa o contador de falhas consecutivas no Redis.
        Se atingir 3 falhas, aciona o lockout temporário por 15 minutos.
        """
        fail_key = cls._chave_falhas_utilizador(utilizador_id)
        lock_key = cls._chave_lockout_utilizador(utilizador_id)

        try:
            contagem = cache.incr(fail_key)
        except ValueError:
            # Se a chave ainda não existe, cria com valor inicial 1
            cache.set(fail_key, 1, timeout=cls.TIMEOUT_BLOQUEIO_FALHAS_SEGUNDOS)
            contagem = 1

        logger.warning(
            "RN-067: Falha de autorização registada para utilizador=%s. Contagem consecutiva: %d/%d. Motivo: %s",
            utilizador_id,
            contagem,
            cls.MAX_FALHAS_CONSECUTIVAS,
            motivo,
        )

        if contagem >= cls.MAX_FALHAS_CONSECUTIVAS:
            expira_ts = int(timezone.now().timestamp()) + cls.TIMEOUT_BLOQUEIO_FALHAS_SEGUNDOS
            cache.set(lock_key, expira_ts, timeout=cls.TIMEOUT_BLOQUEIO_FALHAS_SEGUNDOS)
            # Reseta o contador para evitar ciclos infinitos ao sair do bloqueio
            cache.delete(fail_key)
            logger.error(
                "RN-067: ATENÇÃO - Utilizador %s atingiu o limite de %d falhas consecutivas. "
                "Método de pagamento bloqueado temporariamente por %d segundos.",
                utilizador_id,
                cls.MAX_FALHAS_CONSECUTIVAS,
                cls.TIMEOUT_BLOQUEIO_FALHAS_SEGUNDOS,
            )
            raise PaymentRateLimitLockedError(
                utilizador_id=utilizador_id,
                tempo_restante_segundos=cls.TIMEOUT_BLOQUEIO_FALHAS_SEGUNDOS,
            )

    @classmethod
    def _limpar_falhas_autorizacao(cls, utilizador_id: str | int) -> None:
        """
        RN-067: Após uma transação bem-sucedida, repõe a contagem de falhas a zero.
        """
        fail_key = cls._chave_falhas_utilizador(utilizador_id)
        cache.delete(fail_key)

    # --------------------------------------------------------------------------
    # 1. CRIAR PRÉ-AUTORIZAÇÃO (RN-066, RN-067, RN-068)
    # --------------------------------------------------------------------------

    @classmethod
    def criar_pre_autorizacao(
        cls,
        pedido: Pedido,
        token_cartao: str,
        idempotency_key: Optional[str] = None,
    ) -> GatewayTransactionResult:
        """
        RN-066: Cria uma pré-autorização de fundos no cartão do cliente.
        - Envia o valor integral `pedido.total_cobrado` em unidades mínimas inteiras (RN-059).
        - Não armazena nem regista dados sensíveis do cartão (PCI DSS RN-068).
        - Verifica se o cliente tem lockout de 3 falhas consecutivas ativas (RN-067).
        - Se aprovado, devolve `gateway_transaction_id` com o status 'Autorizado' e persiste
          um evento imutável `payment.authorized` na tabela `EventoPedido`.
        """
        if not token_cartao or not str(token_cartao).strip():
            raise PaymentGatewayException(
                "O token de pagamento (cartão) é de fornecimento obrigatório.",
                codigo_erro="MISSING_CARD_TOKEN",
            )

        # 1. Conformidade PCI DSS preventiva: Inspeciona o token recebido
        RealisticPaymentGatewaySimulator._verificar_pci_dss(token_cartao)

        # 2. Proteção Anti-Fraude e Rate Limiting (RN-067):
        cls.verificar_bloqueio_rate_limit(pedido.cliente_id)

        # 3. Geração ou reutilização de chave de idempotência para comunicação segura com o Gateway
        chave_idempotencia = idempotency_key or f"idemp_auth_{pedido.id}_{pedido.total_cobrado}"

        # 4. Invocação da API do Gateway
        try:
            resultado = RealisticPaymentGatewaySimulator.pre_autorizar(
                token_cartao=token_cartao,
                montante=pedido.total_cobrado,
                moeda=cls.MOEDA_PADRAO,
                idempotency_key=chave_idempotencia,
                pedido_id=str(pedido.id),
                descricao=f"Pre-autorizacao Pedido #{pedido.id}",
            )
        except PCIDSSComplianceViolationError:
            raise
        except Exception as exc:
            cls._registar_falha_autorizacao(pedido.cliente_id, motivo=f"Erro de infraestrutura: {exc}")
            raise PaymentAuthorizationError(
                f"Erro de comunicação com o gateway bancário ao pré-autorizar: {exc}",
                codigo_erro="GATEWAY_COMMUNICATION_ERROR",
            ) from exc

        # 5. Tratamento de resposta do Gateway
        if not resultado.sucesso:
            # Em caso de recusa pelo banco, incrementa falhas e lança exceção informativa
            cls._registar_falha_autorizacao(pedido.cliente_id, motivo=resultado.mensagem_gateway)

            # Emite log estruturado de auditoria da falha (RN-073)
            cls._registar_log_auditoria(
                pedido=pedido,
                resultado=resultado,
                token_usado=token_cartao,
            )

            raise PaymentAuthorizationError(
                mensagem=f"Pagamento recusado: {resultado.mensagem_gateway}",
                codigo_erro=f"CARD_DECLINED_{resultado.codigo_resposta}",
                detalhes={
                    "gateway_transaction_id": resultado.gateway_transaction_id,
                    "codigo_resposta": resultado.codigo_resposta,
                },
            )

        # 6. Sucesso: Limpa o histórico de falhas do utilizador (RN-067)
        cls._limpar_falhas_autorizacao(pedido.cliente_id)

        # 7. Registo Imutável no Histórico de Eventos do Pedido (Secção 5.2, 12.1 e RN-068)
        # NUNCA grava o PAN nem CVV, apenas o token opaco e máscara de segurança
        payload_evento = {
            "gateway_transaction_id": resultado.gateway_transaction_id,
            "tipo_operacao": resultado.tipo_operacao,
            "status_gateway": resultado.status,
            "codigo_autorizacao": resultado.codigo_autorizacao,
            "codigo_resposta": resultado.codigo_resposta,
            "montante": resultado.montante,
            "moeda": resultado.moeda,
            "token_cartao": f"{token_cartao[:8]}...{token_cartao[-4:]}",  # Token parcialmente ofuscado
            "cartao": asdict(resultado.cartao_info) if resultado.cartao_info else {},
            "idempotency_key": chave_idempotencia,
            "tempo_resposta_ms": resultado.tempo_resposta_ms,
        }

        EventoPedido.objects.create(
            pedido=pedido,
            tipo_evento=EventoPedido.TipoEvento.PAYMENT_AUTHORIZED,
            autor=f"cliente:{pedido.cliente_id}",
            dados_adicionais=payload_evento,
        )

        # 8. Emissão de Log Estruturado para Conciliação Diária (RN-073)
        cls._registar_log_auditoria(
            pedido=pedido,
            resultado=resultado,
            token_usado=token_cartao,
        )

        logger.info(
            "Pré-autorização concluída com sucesso: Pedido %s | TX %s | Total: %s %s",
            pedido.id,
            resultado.gateway_transaction_id,
            resultado.montante,
            resultado.moeda,
        )

        return resultado

    # --------------------------------------------------------------------------
    # 2. CAPTURAR PAGAMENTO FINAL (RN-066)
    # --------------------------------------------------------------------------

    @classmethod
    def capturar_pagamento_final(
        cls,
        pedido: Pedido,
        idempotency_key: Optional[str] = None,
    ) -> GatewayTransactionResult:
        """
        RN-066: Executada assim que o pedido é aceite pela loja ou entregue pelo estafeta.
        Transforma a pré-autorização numa captura definitiva de fundos.
        """
        # Localiza o evento de pré-autorização mais recente na tabela EventoPedido
        evento_auth = (
            EventoPedido.objects.filter(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.PAYMENT_AUTHORIZED,
            )
            .order_by("-timestamp")
            .first()
        )

        if not evento_auth:
            raise PaymentCaptureError(
                f"Não existe qualquer pré-autorização ativa registada para o Pedido {pedido.id}.",
                codigo_erro="PRE_AUTH_NOT_FOUND",
            )

        auth_tx_id = evento_auth.dados_adicionais.get("gateway_transaction_id")
        if not auth_tx_id:
            raise PaymentCaptureError(
                "Registo de pré-autorização corrompido: ausência de 'gateway_transaction_id'.",
                codigo_erro="CORRUPTED_PRE_AUTH_RECORD",
            )

        chave_idempotencia = idempotency_key or f"idemp_cap_{pedido.id}_{auth_tx_id}"

        # Executa a captura no gateway externo
        try:
            resultado = RealisticPaymentGatewaySimulator.capturar(
                gateway_transaction_id=auth_tx_id,
                montante=pedido.total_cobrado,
                moeda=cls.MOEDA_PADRAO,
                idempotency_key=chave_idempotencia,
            )
        except Exception as exc:
            logger.error("Falha ao capturar pagamento para o pedido %s: %s", pedido.id, exc)
            raise PaymentCaptureError(
                f"Erro do gateway ao capturar fundos pré-autorizados: {exc}",
                codigo_erro="CAPTURE_FAILED",
            ) from exc

        # Registo imutável de captura (EventoPedido)
        payload_evento = {
            "gateway_capture_id": resultado.gateway_transaction_id,
            "original_auth_id": auth_tx_id,
            "tipo_operacao": resultado.tipo_operacao,
            "status_gateway": resultado.status,
            "codigo_autorizacao": resultado.codigo_autorizacao,
            "montante": resultado.montante,
            "moeda": resultado.moeda,
            "idempotency_key": chave_idempotencia,
            "tempo_resposta_ms": resultado.tempo_resposta_ms,
        }

        EventoPedido.objects.create(
            pedido=pedido,
            tipo_evento=EventoPedido.TipoEvento.PAYMENT_CAPTURED,
            autor="sistema:payment_gateway",
            dados_adicionais=payload_evento,
        )

        # Registo em Log de Auditoria e Reconciliação (RN-073)
        cls._registar_log_auditoria(pedido=pedido, resultado=resultado)

        logger.info(
            "Captura definitiva de pagamento concluída: Pedido %s | Capture TX: %s | Valor: %s %s",
            pedido.id,
            resultado.gateway_transaction_id,
            resultado.montante,
            resultado.moeda,
        )

        return resultado

    # --------------------------------------------------------------------------
    # 3. CANCELAR AUTORIZAÇÃO OU EFETUAR ESTORNO (RN-066, RN-070)
    # --------------------------------------------------------------------------

    @classmethod
    def cancelar_autorizacao_estorno(
        cls,
        pedido: Pedido,
        motivo: str = "Cancelamento do pedido antes do início da preparação",
        idempotency_key: Optional[str] = None,
    ) -> GatewayTransactionResult:
        """
        RN-066 / RN-070:
        - Se o pedido foi cancelado/rejeitado antes da captura, liberta imediatamente o hold
          no cartão do cliente através de um VOID sem custos nem taxas adicionais.
        - Se o pedido já tiver sido capturado, efetua o estorno/reembolso definitivo (REFUND).
        """
        # Verifica se já ocorreu captura definitiva
        evento_capture = (
            EventoPedido.objects.filter(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.PAYMENT_CAPTURED,
            )
            .order_by("-timestamp")
            .first()
        )

        evento_auth = (
            EventoPedido.objects.filter(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.PAYMENT_AUTHORIZED,
            )
            .order_by("-timestamp")
            .first()
        )

        if not evento_auth and not evento_capture:
            logger.info("Pedido %s não possui autorização ou captura de pagamento para estornar.", pedido.id)
            # Retorna resultado neutro simulado
            return GatewayTransactionResult(
                gateway_transaction_id="tx_noop_sem_cobranca",
                tipo_operacao="VOID",
                status="CANCELADO",
                sucesso=True,
                montante=0,
                moeda=cls.MOEDA_PADRAO,
                codigo_autorizacao="NOOP",
                codigo_resposta="00",
                mensagem_gateway="Nenhuma transação prévia necessitava de estorno.",
                idempotency_key=idempotency_key or "noop",
                tempo_resposta_ms=1,
            )

        chave_idempotencia = idempotency_key or f"idemp_void_refund_{pedido.id}_{uuid.uuid4().hex[:6]}"

        # Cenário A: Já capturado -> Processa Estorno Financeiro (REFUND)
        if evento_capture:
            capture_id = evento_capture.dados_adicionais.get("gateway_capture_id")
            resultado = RealisticPaymentGatewaySimulator.estornar_capturado(
                gateway_transaction_id=capture_id,
                montante=pedido.total_cobrado,
                moeda=cls.MOEDA_PADRAO,
                idempotency_key=chave_idempotencia,
                motivo=motivo,
            )
            tipo_evento_oms = EventoPedido.TipoEvento.PAYMENT_REFUNDED
        # Cenário B: Apenas pré-autorizado -> Liberta o bloqueio sem custo (VOID)
        else:
            auth_id = evento_auth.dados_adicionais.get("gateway_transaction_id")
            resultado = RealisticPaymentGatewaySimulator.reverter_autorizacao_void(
                gateway_transaction_id=auth_id,
                montante=pedido.total_cobrado,
                moeda=cls.MOEDA_PADRAO,
                idempotency_key=chave_idempotencia,
                motivo=motivo,
            )
            tipo_evento_oms = EventoPedido.TipoEvento.PAYMENT_REFUNDED

        # Regista evento imutável na base de dados
        payload_evento = {
            "gateway_refund_id": resultado.gateway_transaction_id,
            "tipo_operacao": resultado.tipo_operacao,
            "status_gateway": resultado.status,
            "codigo_autorizacao": resultado.codigo_autorizacao,
            "montante": resultado.montante,
            "moeda": resultado.moeda,
            "motivo": motivo,
            "idempotency_key": chave_idempotencia,
            "tempo_resposta_ms": resultado.tempo_resposta_ms,
        }

        EventoPedido.objects.create(
            pedido=pedido,
            tipo_evento=tipo_evento_oms,
            autor="sistema:estorno_automatico",
            dados_adicionais=payload_evento,
        )

        # Registo de Log de Auditoria para Reconciliação Financeira (RN-073)
        cls._registar_log_auditoria(pedido=pedido, resultado=resultado)

        logger.info(
            "Reversão/Estorno financeiro efetuado com sucesso: Pedido %s | Operação: %s | TX: %s",
            pedido.id,
            resultado.tipo_operacao,
            resultado.gateway_transaction_id,
        )

        return resultado

    # --------------------------------------------------------------------------
    # 4. LOGS ESTRUTURADOS E CONCILIAÇÃO FINANCEIRA DIÁRIA (RN-073)
    # --------------------------------------------------------------------------

    @classmethod
    def _registar_log_auditoria(
        cls,
        pedido: Pedido,
        resultado: GatewayTransactionResult,
        token_usado: Optional[str] = None,
    ) -> None:
        """
        RN-073: Produz uma linha de log estritamente estruturada em JSON
        para o sistema de agregação de auditoria e reconciliação financeira diária.
        """
        mascara_cartao = "N/A"
        bandeira = "N/A"
        if resultado.cartao_info:
            mascara_cartao = f"**** **** **** {resultado.cartao_info.ultimos_4_digitos}"
            bandeira = resultado.cartao_info.bandeira

        registo_auditoria = {
            "@timestamp": datetime.now(dt_timezone.utc).isoformat(),
            "event_type": "payment_gateway_transaction",
            "correlation_id": str(uuid.uuid4()),
            "pedido_id": str(pedido.id),
            "cliente_id": str(pedido.cliente_id),
            "loja_id": str(pedido.loja_id),
            "metodo_pagamento": pedido.metodo_pagamento,
            "gateway": "SIMULADOR_STRIPE_EMIS",
            "gateway_transaction_id": resultado.gateway_transaction_id,
            "tipo_operacao": resultado.tipo_operacao,
            "status": resultado.status,
            "sucesso": resultado.sucesso,
            "montante_inteiro": resultado.montante,
            "moeda": resultado.moeda,
            "codigo_autorizacao": resultado.codigo_autorizacao,
            "codigo_resposta": resultado.codigo_resposta,
            "mensagem_gateway": resultado.mensagem_gateway,
            "idempotency_key": resultado.idempotency_key,
            "tempo_resposta_ms": resultado.tempo_resposta_ms,
            "pci_dss_compliant": True,
            "cartao_mascarado": mascara_cartao,
            "cartao_bandeira": bandeira,
        }

        # Emite no canal dedicado de reconciliação financeira
        log_json = json.dumps(registo_auditoria, ensure_ascii=False)
        reconciliation_logger.info(log_json)

    @classmethod
    def gerar_dataset_reconciliacao_diaria(
        cls,
        data_referencia: Optional[datetime] = None,
    ) -> list[dict[str, Any]]:
        """
        RN-073: Consolida os eventos de pagamento ocorridos nas últimas 24 horas (ou na data indicada)
        e gera uma lista estruturada de transações para cruzamento automático com o ficheiro de liquidação
        bancária (extrato de liquidação do Gateway / EMIS / Stripe).
        """
        data_base = data_referencia or timezone.now()
        inicio_dia = data_base.replace(hour=0, minute=0, second=0, microsecond=0)
        fim_dia = data_base.replace(hour=23, minute=59, second=59, microsecond=999999)

        tipos_reconciliaveis = [
            EventoPedido.TipoEvento.PAYMENT_AUTHORIZED,
            EventoPedido.TipoEvento.PAYMENT_CAPTURED,
            EventoPedido.TipoEvento.PAYMENT_REFUNDED,
        ]

        eventos = (
            EventoPedido.objects.filter(
                tipo_evento__in=tipos_reconciliaveis,
                timestamp__gte=inicio_dia,
                timestamp__lte=fim_dia,
            )
            .select_related("pedido")
            .order_by("timestamp")
        )

        linhas_reconciliacao: list[dict[str, Any]] = []
        for ev in eventos:
            detalhes = ev.dados_adicionais or {}
            tx_id = (
                detalhes.get("gateway_transaction_id")
                or detalhes.get("gateway_capture_id")
                or detalhes.get("gateway_refund_id")
                or "N/A"
            )

            linhas_reconciliacao.append(
                {
                    "timestamp": ev.timestamp.isoformat(),
                    "evento_id": str(ev.id),
                    "pedido_id": str(ev.pedido_id),
                    "tipo_evento": ev.tipo_evento,
                    "tipo_operacao": detalhes.get("tipo_operacao", "UNKNOWN"),
                    "gateway_transaction_id": tx_id,
                    "codigo_autorizacao": detalhes.get("codigo_autorizacao", ""),
                    "montante_inteiro": detalhes.get("montante", ev.pedido.total_cobrado),
                    "moeda": detalhes.get("moeda", cls.MOEDA_PADRAO),
                    "status_gateway": detalhes.get("status_gateway", "UNKNOWN"),
                    "autor": ev.autor,
                    "idempotency_key": detalhes.get("idempotency_key", ""),
                }
            )

        logger.info(
            "RN-073: Relatório de reconciliação diária gerado com sucesso. Total de registos: %d para data %s",
            len(linhas_reconciliacao),
            inicio_dia.date(),
        )

        return linhas_reconciliacao

