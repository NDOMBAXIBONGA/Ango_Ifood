"""
Motor de Avaliação de Risco Antifraude e Segurança da Plataforma ('orders' / 'security').
Implementa rigorosamente a Secção 6.14 e as Regras de Negócio de Proteção de Risco:
- RN-130: Avaliação probabilística contínua de risco em transações antes do despacho aos parceiros.
- RN-131: Deteção de multicontas partilhando o mesmo hardware (`device_id`) ou cartão bancário (>3 contas).
- RN-132: Proteção contra abuso geocodificado de promoções de primeiro pedido e esquemas de referral (PostGIS).
- RN-133: Deteção de telemetria anómala, GPS falso (spoofing / mock location) e velocidades físicas impossíveis de estafetas.
- RN-134: Mitigação e acionamento de alertas em tempo real para o backoffice.
- RN-135: Suspensão automática de contas infratoras (RN-008) e inscrição em Lista de Bloqueio Imutável (Blacklist).
- RN-068: Total conformidade com PCI DSS (utilização exclusiva de fingerprints SHA-256 e tokens; sem dados sensíveis em claro).
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Callable, Optional

from django.conf import settings
from django.contrib.gis.measure import D
from django.core.cache import cache
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import transaction
from django.http import HttpRequest, HttpResponse, JsonResponse
from django.utils import timezone
from django.utils.translation import gettext_lazy as _

from apps.accounts.models import CustomUser, Morada
from apps.logistics.models import Estafeta
from apps.orders.fraud_models import (
    DispositivoUtilizador,
    ImpressaoDigitalCartao,
    ListaBloqueioImutavel,
    RegistoAlertaFraude,
)
from apps.orders.models import EventoPedido, Pedido

logger = logging.getLogger("security.fraud")
courier_logger = logging.getLogger("security.fraud.courier_gps")


# ==============================================================================
# ESTRUTURAS DE DADOS E EXCEÇÕES DE SEGURANÇA
# ==============================================================================

@dataclass
class FraudRiskResult:
    """Resultado circunstanciado da análise de risco antifraude de uma transação ou pedido."""

    score_total: int
    aprovado: bool
    bloqueado: bool
    motivos: list[str] = field(default_factory=list)
    evidencias: dict[str, Any] = field(default_factory=dict)
    nivel_risco: str = "BAIXO"  # BAIXO, MEDIO, ALTO, CRITICO

    def to_dict(self) -> dict[str, Any]:
        return {
            "score_total": self.score_total,
            "aprovado": self.aprovado,
            "bloqueado": self.bloqueado,
            "nivel_risco": self.nivel_risco,
            "motivos": self.motivos,
            "evidencias": self.evidencias,
        }


class FraudBlockedException(PermissionDenied):
    """
    Exceção de segurança lançada quando um pedido atinge ou ultrapassa o teto de risco antifraude (RN-135).
    Resulta no bloqueio da operação, cancelamento do pedido e suspensão imediata da conta do utilizador.
    """

    def __init__(self, resultado: FraudRiskResult, mensagem: str = "Transação bloqueada por suspeita de fraude.") -> None:
        self.resultado = resultado
        self.mensagem = mensagem
        super().__init__(self.mensagem)


# ==============================================================================
# MOTOR PRINCIPAL ANTIFRAUDE (CLASSE UTILITÁRIA E MIDDLEWARE DJANGO)
# ==============================================================================

class FraudRiskAssessmentEngine:
    """
    Motor Central de Avaliação de Risco Antifraude (Secção 6.14, RN-130 a RN-135).
    Pode ser utilizado como classe utilitária de domínio ou como Middleware HTTP no pipeline do Django.
    """

    # Parâmetros de Configuração da Secção 8 e Secção 6.14 (com fallbacks seguros)
    TETO_SCORE_BLOQUEIO: int = getattr(settings, "FRAUD_SCORE_THRESHOLD", 80)
    MAX_CONTAS_DISPOSITIVO: int = 3  # RN-131
    MAX_CONTAS_CARTAO: int = 3       # RN-131
    JANELA_DIAS_DISPOSITIVO: int = 7
    JANELA_DIAS_CARTAO: int = 30
    RAIO_MORADA_METROS: int = 30     # RN-132: Limite para mesma fração física PostGIS
    VELOCIDADE_MAX_URBANA_KMH: float = 120.0       # RN-133: Limite máximo aceitável para tráfego urbano
    VELOCIDADE_IMPOSSIVEL_SPOOFING_KMH: float = 180.0  # RN-133: Velocidade linear comprovadamente impossível

    def __init__(self, get_response: Optional[Callable[[HttpRequest], HttpResponse]] = None) -> None:
        """Suporte a inicialização como Django Middleware ou objeto autónomo de serviço."""
        self.get_response = get_response

    def __call__(self, request: HttpRequest) -> HttpResponse:
        """
        Interceção HTTP (Middleware) para bloquear antecipadamente utilizadores ou
        dispositivos presentes na Lista de Bloqueio Imutável (RN-135) antes de tocar nas views.
        """
        # Checagem preventiva rápida se for uma rota de checkout ou confirmação de pedido
        if request.path.startswith("/api/v1/orders/checkout/"):
            device_id = self._extrair_device_id(request)
            user = getattr(request, "user", None)

            if user and user.is_authenticated:
                if self._esta_em_lista_bloqueio(ListaBloqueioImutavel.TipoIdentificador.USER_ID, str(user.id)):
                    return JsonResponse(
                        {"erro": "Conta suspensa permanentemente por violação das regras de segurança (RN-008/RN-135)."},
                        status=403,
                    )

            if device_id and self._esta_em_lista_bloqueio(ListaBloqueioImutavel.TipoIdentificador.DEVICE_ID, device_id):
                return JsonResponse(
                    {"erro": "Dispositivo móvel bloqueado por histórico de atividades ilícitas (RN-135)."},
                    status=403,
                )

        if self.get_response:
            return self.get_response(request)
        return HttpResponse(status=200)

    # ==========================================================================
    # MÉTODO CORE: ANALISAR RISCO DO PEDIDO (ANTES DO ENVIO AO PARCEIRO)
    # ==========================================================================

    @classmethod
    def analisar_risco_pedido(
        cls,
        pedido: Pedido,
        request: Optional[HttpRequest] = None,
        dados_pagamento: Optional[dict[str, Any]] = None,
    ) -> FraudRiskResult:
        """
        Executa a verificação detalhada de risco antifraude imediatamente antes do envio
        do pedido ao parceiro comercial (antes da transição para `AGUARDA_PARCEIRO`).

        Checagens em código:
        1. Validação de Dispositivo e Cartões Múltiplos (RN-131).
        2. Abuso de Promoções e Descontos em Contas Múltiplas na Mesma Morada (RN-132).
        3. Verificação contra Lista de Bloqueio Imutável (RN-135).

        Se a pontuação total ultrapassar o teto configurado (`TETO_SCORE_BLOQUEIO`),
        altera automaticamente o estado da conta para Suspenso (RN-008), inscreve o infrator
        na Lista de Bloqueio Imutável (RN-135), cancela o pedido e lança `FraudBlockedException`.
        """
        cliente: CustomUser = pedido.cliente
        score_acumulado: int = 0
        motivos: list[str] = []
        evidencias: dict[str, Any] = {}

        logger.info(
            f"[ANTIFRAUDE-START] Iniciando auditoria do Pedido {pedido.id} "
            f"(Cliente: {cliente.id}, Total: {pedido.total_cobrado})"
        )

        # ----------------------------------------------------------------------
        # PASSO 0: Verificação de Identificadores na Lista de Bloqueio Imutável (RN-135)
        # ----------------------------------------------------------------------
        device_id = cls._extrair_device_id(request) if request else None
        card_fingerprint = cls._extrair_card_fingerprint(pedido, dados_pagamento)

        bloqueio_hit = cls._verificar_presenca_blacklist(
            user=cliente,
            device_id=device_id,
            card_fingerprint=card_fingerprint,
        )
        if bloqueio_hit:
            score_acumulado = 100
            motivos.append(f"Identificador presente na Lista de Bloqueio Imutável (RN-135): {bloqueio_hit}")
            evidencias["blacklist_hit"] = bloqueio_hit

            cls._executar_bloqueio_suspensao(
                pedido=pedido,
                cliente=cliente,
                score_final=score_acumulado,
                motivos=motivos,
                evidencias=evidencias,
                device_id=device_id,
                card_fingerprint=card_fingerprint,
            )
            resultado = FraudRiskResult(
                score_total=100,
                aprovado=False,
                bloqueado=True,
                motivos=motivos,
                evidencias=evidencias,
                nivel_risco="CRITICO",
            )
            raise FraudBlockedException(resultado, "Cliente ou dispositivo presente na lista negra permanente.")

        # ----------------------------------------------------------------------
        # PASSO 1: Validação de Dispositivo e Cartões Múltiplos (RN-131)
        # ----------------------------------------------------------------------
        # 1.1 Análise de Dispositivo Móvel (Hardware/App UUID)
        if device_id:
            cls._registar_ou_atualizar_dispositivo(cliente, device_id, request)
            contas_disp = cls._contar_contas_por_dispositivo(device_id)
            evidencias["contas_associadas_dispositivo"] = contas_disp

            if contas_disp > cls.MAX_CONTAS_DISPOSITIVO:
                pontos = 40 + (contas_disp - cls.MAX_CONTAS_DISPOSITIVO) * 10
                score_acumulado += pontos
                msg = (
                    f"RN-131: Dispositivo móvel ({device_id[:12]}...) partilhado por {contas_disp} contas "
                    f"distintas nos últimos {cls.JANELA_DIAS_DISPOSITIVO} dias (máx. permitido: {cls.MAX_CONTAS_DISPOSITIVO})."
                )
                motivos.append(msg)
                logger.warning(f"[ANTIFRAUDE-RN131] Pedido {pedido.id}: {msg}")

        # 1.2 Análise de Cartão Bancário Tokenizado (PCI DSS Fingerprint)
        if card_fingerprint:
            cls._registar_fingerprint_cartao(cliente, card_fingerprint, dados_pagamento)
            contas_card = cls._contar_contas_por_cartao(card_fingerprint)
            evidencias["contas_associadas_cartao"] = contas_card

            if contas_card > cls.MAX_CONTAS_CARTAO:
                pontos = 45 + (contas_card - cls.MAX_CONTAS_CARTAO) * 10
                score_acumulado += pontos
                msg = (
                    f"RN-131: O mesmo cartão de pagamento foi associado a {contas_card} contas "
                    f"distintas nos últimos {cls.JANELA_DIAS_CARTAO} dias (máx. permitido: {cls.MAX_CONTAS_CARTAO})."
                )
                motivos.append(msg)
                logger.warning(f"[ANTIFRAUDE-RN131] Pedido {pedido.id}: {msg}")

        # ----------------------------------------------------------------------
        # PASSO 2: Abuso de Promoções e Descontos em Contas Múltiplas na Mesma Morada (RN-132)
        # ----------------------------------------------------------------------
        if pedido.descontos > 0:
            tem_abuso_promo, detalhes_promo = cls._verificar_abuso_promocoes_morada(pedido)
            evidencias["auditoria_promocoes_morada"] = detalhes_promo

            if tem_abuso_promo:
                pontos = 40
                score_acumulado += pontos
                msg = (
                    f"RN-132: Deteção de contas múltiplas na mesma morada física geocodificada "
                    f"a usufruir repetidamente de cupões de primeiro pedido ou referral "
                    f"({detalhes_promo.get('pedidos_reincidentes', 0)} pedidos anteriores identificados)."
                )
                motivos.append(msg)
                logger.warning(f"[ANTIFRAUDE-RN132] Pedido {pedido.id}: {msg}")

        # ----------------------------------------------------------------------
        # PASSO 3: Classificação do Nível de Risco e Tomada de Ação
        # ----------------------------------------------------------------------
        nivel_risco = cls._classificar_nivel_risco(score_acumulado)
        aprovado = score_acumulado < cls.TETO_SCORE_BLOQUEIO
        bloqueado = not aprovado

        resultado = FraudRiskResult(
            score_total=score_acumulado,
            aprovado=aprovado,
            bloqueado=bloqueado,
            motivos=motivos,
            evidencias=evidencias,
            nivel_risco=nivel_risco,
        )

        # Registo do Evento de Auditoria no OMS
        cls._registar_alerta_auditoria(pedido, cliente, resultado)

        # Se ultrapassar o teto: Bloqueia e Suspende Conta (RN-008 e RN-135)
        if bloqueado:
            logger.error(
                f"[ANTIFRAUDE-BLOQUEIO] Pedido {pedido.id} REJEITADO. Score: {score_acumulado} >= {cls.TETO_SCORE_BLOQUEIO}. "
                f"Aplicando suspensão e inscrição imutável na Blacklist."
            )
            cls._executar_bloqueio_suspensao(
                pedido=pedido,
                cliente=cliente,
                score_final=score_acumulado,
                motivos=motivos,
                evidencias=evidencias,
                device_id=device_id,
                card_fingerprint=card_fingerprint,
            )
            raise FraudBlockedException(
                resultado=resultado,
                mensagem=f"Pedido cancelado e conta suspensa por ultrapassar o teto de risco antifraude (Score: {score_acumulado}).",
            )

        logger.info(
            f"[ANTIFRAUDE-APROVADO] Pedido {pedido.id} aprovado para envio ao parceiro. "
            f"Score de Risco: {score_acumulado}/{cls.TETO_SCORE_BLOQUEIO} (Nível: {nivel_risco})"
        )
        return resultado

    # ==========================================================================
    # MÉTODO ESPECIALIZADO: ANÁLISE DE GPS FALSO / ESTAFETA (RN-133)
    # ==========================================================================

    @classmethod
    def analisar_velocidade_gps_estafeta(
        cls,
        estafeta_id: Any,
        nova_latitude: float,
        nova_longitude: float,
        timestamp_atual: Optional[datetime] = None,
    ) -> dict[str, Any]:
        """
        RN-133: Deteção de telemetria anómala, emuladores de GPS falso (spoofing / mock location)
        e velocidades lineares fisicamente impossíveis nos pings de localização do estafeta.

        Se a velocidade linear calculada exceder limites urbanos plausíveis, dispara alerta crítico.
        Se exceder `VELOCIDADE_IMPOSSIVEL_SPOOFING_KMH` (>180 km/h), suspende imediatamente o estafeta
        e inscreve o seu identificador na Lista de Bloqueio Imutável (RN-135).
        """
        agora = timestamp_atual or timezone.now()
        cache_key = f"courier_telemetry:last_pos:{estafeta_id}"
        dados_anteriores = cache.get(cache_key)

        # Atualiza a cache com o ping atual
        dados_atuais = {
            "lat": nova_latitude,
            "lng": nova_longitude,
            "timestamp": agora.timestamp(),
        }
        cache.set(cache_key, dados_atuais, timeout=300)

        if not dados_anteriores:
            return {"status": "INICIALIZADO", "velocidade_kmh": 0.0}

        # Cálculo do Intervalo Temporal Delta T
        ts_anterior = datetime.fromtimestamp(dados_anteriores["timestamp"], tz=timezone.get_current_timezone())
        delta_segundos = max(1.0, (agora - ts_anterior).total_seconds())

        # Cálculo da Distância Linear via Haversine
        distancia_metros = cls._calcular_haversine(
            lat1=dados_anteriores["lat"],
            lon1=dados_anteriores["lng"],
            lat2=nova_latitude,
            lon2=nova_longitude,
        )

        velocidade_kmh = round((distancia_metros / 1000.0) / (delta_segundos / 3600.0), 2)

        # Registo de Log e Auditoria
        courier_logger.info(
            f"[ESTAFETA-GPS] Estafeta {estafeta_id}: Distância={distancia_metros:.1f}m em {delta_segundos:.1f}s -> "
            f"Velocidade={velocidade_kmh} km/h"
        )

        # 1. Alerta Crítico para Backoffice se ultrapassar limites de tráfego urbano (>120 km/h)
        if velocidade_kmh > cls.VELOCIDADE_MAX_URBANA_KMH:
            alerta_payload = {
                "estafeta_id": str(estafeta_id),
                "velocidade_kmh": velocidade_kmh,
                "distancia_metros": round(distancia_metros, 2),
                "delta_segundos": round(delta_segundos, 2),
                "ponto_anterior": [dados_anteriores["lat"], dados_anteriores["lng"]],
                "ponto_atual": [nova_latitude, nova_longitude],
                "horario": agora.isoformat(),
            }

            courier_logger.critical(
                f"ALERTA CRÍTICO DE SEGURANÇA (RN-133): Estafeta {estafeta_id} registou "
                f"velocidade linear improvável de {velocidade_kmh} km/h! Possível GPS Mock/Spoofing."
            )

            # Grava o alerta na base de dados para auditoria do backoffice
            RegistoAlertaFraude.objects.create(
                estafeta_id=estafeta_id,
                tipo_fraude=RegistoAlertaFraude.TipoFraude.GPS_FALSO_VELOCIDADE_IMPOSSIVEL,
                severidade=(
                    RegistoAlertaFraude.Severidade.CRITICA
                    if velocidade_kmh >= cls.VELOCIDADE_IMPOSSIVEL_SPOOFING_KMH
                    else RegistoAlertaFraude.Severidade.ALTA
                ),
                score_atribuido=90,
                detalhes=alerta_payload,
                acao_tomada=(
                    "SUSPENSAO_IMEDIATA_BLACKLIST_RN135"
                    if velocidade_kmh >= cls.VELOCIDADE_IMPOSSIVEL_SPOOFING_KMH
                    else "ALERTA_CRITICO_BACKOFFICE"
                ),
            )

            # 2. Se a velocidade for comprovadamente impossível (>180 km/h), suspende estafeta na hora (RN-135)
            if velocidade_kmh >= cls.VELOCIDADE_IMPOSSIVEL_SPOOFING_KMH:
                cls._executar_suspensao_estafeta_gps(estafeta_id, velocidade_kmh, alerta_payload)

            return {
                "status": "ALERTA_DISPARADO",
                "velocidade_kmh": velocidade_kmh,
                "anomalia": True,
                "detalhes": alerta_payload,
            }

        return {"status": "OK", "velocidade_kmh": velocidade_kmh, "anomalia": False}

    # ==========================================================================
    # ROTINAS DE BLOQUEIO, SUSPENSÃO E LISTA NEGRA (RN-008 e RN-135)
    # ==========================================================================

    @classmethod
    def _executar_bloqueio_suspensao(
        cls,
        pedido: Pedido,
        cliente: CustomUser,
        score_final: int,
        motivos: list[str],
        evidencias: dict[str, Any],
        device_id: Optional[str],
        card_fingerprint: Optional[str],
    ) -> None:
        """
        Executa em transação atómica:
        1. Alteração do estado do utilizador para Suspenso (`perfil_bloqueado` conforme RN-008).
        2. Inscrição de todos os identificadores conhecidos na Lista de Bloqueio Imutável (RN-135).
        3. Cancelamento automático do pedido no OMS com log de auditoria `order.fraud_blocked`.
        """
        with transaction.atomic():
            # 1. Suspensão da Conta do Utilizador (RN-008 / RN-006 / RN-007)
            cliente.estado = CustomUser.EstadoConta.SUSPENSO
            cliente.is_active = False
            cliente.save(update_fields=["estado", "is_active"])

            motivo_unificado = " | ".join(motivos)

            # 2. Inserção na Lista de Bloqueio Imutável (RN-135)
            # 2.1 Bloqueio do USER_ID
            cls._adicionar_blacklist_se_ausente(
                tipo=ListaBloqueioImutavel.TipoIdentificador.USER_ID,
                valor=str(cliente.id),
                motivo=motivo_unificado,
                score=score_final,
                evidencia=evidencias,
            )
            # 2.2 Bloqueio do Telemóvel
            cls._adicionar_blacklist_se_ausente(
                tipo=ListaBloqueioImutavel.TipoIdentificador.TELEMOVEL,
                valor=str(cliente.telemovel),
                motivo=motivo_unificado,
                score=score_final,
                evidencia=evidencias,
            )
            # 2.3 Bloqueio do Email
            cls._adicionar_blacklist_se_ausente(
                tipo=ListaBloqueioImutavel.TipoIdentificador.EMAIL,
                valor=str(cliente.email),
                motivo=motivo_unificado,
                score=score_final,
                evidencia=evidencias,
            )
            # 2.4 Bloqueio do Device ID (se conhecido)
            if device_id:
                cls._adicionar_blacklist_se_ausente(
                    tipo=ListaBloqueioImutavel.TipoIdentificador.DEVICE_ID,
                    valor=device_id,
                    motivo=motivo_unificado,
                    score=score_final,
                    evidencia=evidencias,
                )
            # 2.5 Bloqueio do Fingerprint do Cartão (se conhecido)
            if card_fingerprint:
                cls._adicionar_blacklist_se_ausente(
                    tipo=ListaBloqueioImutavel.TipoIdentificador.CARD_FINGERPRINT,
                    valor=card_fingerprint,
                    motivo=motivo_unificado,
                    score=score_final,
                    evidencia=evidencias,
                )

            # 3. Cancelamento do Pedido no OMS
            pedido.estado = Pedido.EstadoPedido.CANCELADO
            pedido.save(update_fields=["estado", "data_atualizacao"])

            # 4. Registo do Evento Imutável no Histórico do Pedido
            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento="order.fraud_blocked",
                autor=EventoPedido.TipoAutor.SISTEMA,
                detalhes={
                    "score_risco": score_final,
                    "teto_limite": cls.TETO_SCORE_BLOQUEIO,
                    "motivos": motivos,
                    "acao": "CONTA_SUSPENSA_E_BLACKLIST_RN135",
                },
            )

    @classmethod
    def _executar_suspensao_estafeta_gps(
        cls,
        estafeta_id: Any,
        velocidade_kmh: float,
        alerta_payload: dict[str, Any],
    ) -> None:
        """Suspende o estafeta e adiciona-o à Lista de Bloqueio Imutável por spoofing de GPS."""
        try:
            with transaction.atomic():
                estafeta = Estafeta.objects.select_related("utilizador").get(id=estafeta_id)
                estafeta.is_online = False
                estafeta.save(update_fields=["is_online"])

                user = estafeta.utilizador
                user.estado = CustomUser.EstadoConta.SUSPENSO
                user.is_active = False
                user.save(update_fields=["estado", "is_active"])

                motivo = f"RN-133/RN-135: Suspensão imediata por Spoofing/Mock de GPS comprovado ({velocidade_kmh} km/h)."

                cls._adicionar_blacklist_se_ausente(
                    tipo=ListaBloqueioImutavel.TipoIdentificador.ESTAFETA_ID,
                    valor=str(estafeta_id),
                    motivo=motivo,
                    score=100,
                    evidencia=alerta_payload,
                )
                cls._adicionar_blacklist_se_ausente(
                    tipo=ListaBloqueioImutavel.TipoIdentificador.USER_ID,
                    valor=str(user.id),
                    motivo=motivo,
                    score=100,
                    evidencia=alerta_payload,
                )

                courier_logger.critical(
                    f"[ESTAFETA-BLOQUEADO] Estafeta {estafeta_id} (User: {user.id}) foi suspenso "
                    f"e bloqueado permanentemente na Blacklist por fraude de GPS."
                )
        except Exception as exc:
            courier_logger.exception(f"Erro ao suspender estafeta {estafeta_id}: {exc}")

    @classmethod
    def _adicionar_blacklist_se_ausente(
        cls,
        tipo: str,
        valor: str,
        motivo: str,
        score: int,
        evidencia: dict[str, Any],
    ) -> None:
        """Insere de forma idempotente um identificador na Lista de Bloqueio Imutável."""
        if not valor:
            return
        if not ListaBloqueioImutavel.objects.filter(tipo_identificador=tipo, valor_identificador=valor).exists():
            ListaBloqueioImutavel.objects.create(
                tipo_identificador=tipo,
                valor_identificador=valor,
                motivo=motivo,
                score_risco=score,
                evidencia=evidencia,
                bloqueado_por="SISTEMA_ANTIFRAUDE",
                is_ativo=True,
            )

    # ==========================================================================
    # AUXILIARES DE CÁLCULO E QUERIES POSTGIS / BANCO DE DADOS
    # ==========================================================================

    @classmethod
    def _verificar_abuso_promocoes_morada(cls, pedido: Pedido) -> tuple[bool, dict[str, Any]]:
        """
        RN-132: Verifica se contas múltiplas com a mesma morada física geocodificada
        (PostGIS PointField num raio de 30 metros) utilizaram repetidamente cupões
        de primeiro pedido ou referral.
        """
        cliente = pedido.cliente

        # Obtém a morada de entrega do cliente associada ao pedido
        morada_cliente = Morada.objects.filter(utilizador=cliente).order_by("-id").first()
        if not morada_cliente or not morada_cliente.geolocalizacao:
            return False, {"motivo": "Sem coordenadas geográficas para análise espacial"}

        ponto_cliente = morada_cliente.geolocalizacao

        # Query Espacial PostGIS: Localiza outras moradas num raio de 30 metros
        moradas_vizinhas = (
            Morada.objects.filter(
                geolocalizacao__distance_lte=(ponto_cliente, D(m=cls.RAIO_MORADA_METROS))
            )
            .exclude(utilizador=cliente)
            .values_list("utilizador_id", flat=True)
            .distinct()
        )

        outros_utilizadores_ids = list(moradas_vizinhas)
        if not outros_utilizadores_ids:
            return False, {"moradas_vizinhas_detectadas": 0}

        # Pesquisa pedidos anteriores com cupões concluídos por outros utilizadores na mesma morada física
        pedidos_com_promo = (
            Pedido.objects.filter(
                cliente_id__in=outros_utilizadores_ids,
                descontos__gt=0,
                estado__in=[
                    Pedido.EstadoPedido.CONCLUIDO,
                    Pedido.EstadoPedido.ENTREGUE,
                    Pedido.EstadoPedido.EM_TRANSITO,
                    Pedido.EstadoPedido.EM_PREPARACAO,
                ],
            )
            .values("id", "cliente_id", "descontos", "data_criacao")
            .order_by("-data_criacao")[:10]
        )

        total_reincidentes = len(pedidos_com_promo)
        detalhes = {
            "moradas_vizinhas_detectadas": len(outros_utilizadores_ids),
            "pedidos_reincidentes": total_reincidentes,
            "raio_analisado_metros": cls.RAIO_MORADA_METROS,
            "amostra_pedidos": [str(p["id"]) for p in pedidos_com_promo[:3]],
        }

        # Se mais de 1 conta anterior utilizou cupão nesta morada física, configura abuso de promoções (RN-132)
        tem_abuso = total_reincidentes >= 1
        return tem_abuso, detalhes

    @classmethod
    def _contar_contas_por_dispositivo(cls, device_id: str) -> int:
        """RN-131: Conta quantas contas de utilizadores distintas acederam com este device_id nos últimos X dias."""
        limite_data = timezone.now() - timedelta(days=cls.JANELA_DIAS_DISPOSITIVO)
        return (
            DispositivoUtilizador.objects.filter(
                device_id=device_id,
                data_ultimo_acesso__gte=limite_data,
            )
            .values("utilizador")
            .distinct()
            .count()
        )

    @classmethod
    def _contar_contas_por_cartao(cls, card_fingerprint: str) -> int:
        """RN-131: Conta quantas contas distintas registaram o mesmo cartão nos últimos X dias."""
        limite_data = timezone.now() - timedelta(days=cls.JANELA_DIAS_CARTAO)
        return (
            ImpressaoDigitalCartao.objects.filter(
                card_fingerprint=card_fingerprint,
                data_associacao__gte=limite_data,
            )
            .values("utilizador")
            .distinct()
            .count()
        )

    @classmethod
    def _verificar_presenca_blacklist(
        cls,
        user: CustomUser,
        device_id: Optional[str],
        card_fingerprint: Optional[str],
    ) -> Optional[str]:
        """RN-135: Verifica se algum dos identificadores já está na lista de bloqueio imutável."""
        # Checagem de User ID
        if cls._esta_em_lista_bloqueio(ListaBloqueioImutavel.TipoIdentificador.USER_ID, str(user.id)):
            return f"USER_ID:{user.id}"
        # Checagem de Telemóvel
        if cls._esta_em_lista_bloqueio(ListaBloqueioImutavel.TipoIdentificador.TELEMOVEL, str(user.telemovel)):
            return f"TELEMOVEL:{user.telemovel}"
        # Checagem de Email
        if cls._esta_em_lista_bloqueio(ListaBloqueioImutavel.TipoIdentificador.EMAIL, str(user.email)):
            return f"EMAIL:{user.email}"
        # Checagem de Dispositivo
        if device_id and cls._esta_em_lista_bloqueio(ListaBloqueioImutavel.TipoIdentificador.DEVICE_ID, device_id):
            return f"DEVICE_ID:{device_id}"
        # Checagem de Cartão
        if card_fingerprint and cls._esta_em_lista_bloqueio(ListaBloqueioImutavel.TipoIdentificador.CARD_FINGERPRINT, card_fingerprint):
            return f"CARD_FINGERPRINT:{card_fingerprint}"

        return None

    @classmethod
    def _esta_em_lista_bloqueio(cls, tipo: str, valor: str) -> bool:
        """Verifica se existe uma entrada ativa para o identificador na lista de bloqueio imutável."""
        if not valor:
            return False
        return ListaBloqueioImutavel.objects.filter(
            tipo_identificador=tipo,
            valor_identificador=valor,
            is_ativo=True,
        ).exists()

    @classmethod
    def _registar_ou_atualizar_dispositivo(
        cls,
        user: CustomUser,
        device_id: str,
        request: Optional[HttpRequest],
    ) -> None:
        """Regista ou atualiza o timestamp de acesso do dispositivo do utilizador."""
        ip = cls._obter_ip_cliente(request) if request else None
        user_agent = request.META.get("HTTP_USER_AGENT", "")[:250] if request else ""

        DispositivoUtilizador.objects.update_or_create(
            utilizador=user,
            device_id=device_id,
            defaults={
                "ip_origem": ip,
                "user_agent": user_agent,
            },
        )

    @classmethod
    def _registar_fingerprint_cartao(
        cls,
        user: CustomUser,
        card_fingerprint: str,
        dados_pagamento: Optional[dict[str, Any]],
    ) -> None:
        """Regista o fingerprint criptográfico do cartão em total conformidade PCI DSS RN-068."""
        detalhes = dados_pagamento or {}
        ImpressaoDigitalCartao.objects.get_or_create(
            utilizador=user,
            card_fingerprint=card_fingerprint,
            defaults={
                "gateway_token": detalhes.get("token", "")[:128],
                "ultimos_quatro": detalhes.get("last4", "")[:4],
                "bandeira": detalhes.get("brand", "")[:30],
            },
        )

    @classmethod
    def _registar_alerta_auditoria(cls, pedido: Pedido, cliente: CustomUser, resultado: FraudRiskResult) -> None:
        """Persiste um registo de auditoria de segurança para a transação."""
        if resultado.score_total > 0:
            RegistoAlertaFraude.objects.create(
                pedido=pedido,
                utilizador=cliente,
                tipo_fraude=(
                    RegistoAlertaFraude.TipoFraude.PADRAO_SUSPEITO
                    if resultado.aprovado
                    else RegistoAlertaFraude.TipoFraude.BLACKLIST_HIT
                ),
                severidade=(
                    RegistoAlertaFraude.Severidade.CRITICA
                    if resultado.bloqueado
                    else (
                        RegistoAlertaFraude.Severidade.ALTA
                        if resultado.score_total >= 50
                        else RegistoAlertaFraude.Severidade.MEDIA
                    )
                ),
                score_atribuido=resultado.score_total,
                detalhes=resultado.to_dict(),
                acao_tomada="CONTA_SUSPENSA_BLACKLIST" if resultado.bloqueado else "TRANSACAO_APROVADA_COM_RISCO",
            )

    @classmethod
    def _extrair_device_id(cls, request: Optional[HttpRequest]) -> Optional[str]:
        """Extrai o device_id dos cabeçalhos HTTP ou parâmetros da requisição."""
        if not request:
            return None
        return (
            request.headers.get("X-Device-Id")
            or request.headers.get("X-Device-UUID")
            or request.META.get("HTTP_X_DEVICE_ID")
            or request.GET.get("device_id")
        )

    @classmethod
    def _extrair_card_fingerprint(
        cls,
        pedido: Pedido,
        dados_pagamento: Optional[dict[str, Any]],
    ) -> Optional[str]:
        """
        Extrai ou deriva o card_fingerprint criptográfico (SHA-256) garantindo conformidade PCI DSS (RN-068).
        """
        if dados_pagamento and dados_pagamento.get("card_fingerprint"):
            return str(dados_pagamento["card_fingerprint"])

        if dados_pagamento and dados_pagamento.get("token"):
            token = str(dados_pagamento["token"])
            return hashlib.sha256(token.encode("utf-8")).hexdigest()

        # Fallback caso já exista um cartão tokenizado para este utilizador
        ultimo_cartao = ImpressaoDigitalCartao.objects.filter(utilizador=pedido.cliente).order_by("-data_associacao").first()
        return ultimo_cartao.card_fingerprint if ultimo_cartao else None

    @classmethod
    def _obter_ip_cliente(cls, request: HttpRequest) -> str:
        """Extrai o endereço IP real do cliente através dos cabeçalhos de proxy reverso."""
        x_forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR")
        if x_forwarded_for:
            return x_forwarded_for.split(",")[0].strip()
        return request.META.get("REMOTE_ADDR", "127.0.0.1")

    @classmethod
    def _classificar_nivel_risco(cls, score: int) -> str:
        """Classifica o nível qualitativo de risco baseado na pontuação acumulada."""
        if score >= cls.TETO_SCORE_BLOQUEIO:
            return "CRITICO"
        if score >= 50:
            return "ALTO"
        if score >= 25:
            return "MEDIO"
        return "BAIXO"

    @classmethod
    def _calcular_haversine(cls, lat1: float, lon1: float, lat2: float, lon2: float) -> float:
        """
        Calcula a distância ortodrómica (em metros) entre dois pontos geográficos na Terra
        através da fórmula de Haversine.
        """
        raio_terra_metros = 6371000.0
        phi1 = math.radians(lat1)
        phi2 = math.radians(lat2)
        delta_phi = math.radians(lat2 - lat1)
        delta_lambda = math.radians(lon2 - lon1)

        a = (
            math.sin(delta_phi / 2.0) ** 2
            + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0) ** 2
        )
        c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
        return raio_terra_metros * c

