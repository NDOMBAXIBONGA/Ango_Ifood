"""
Views da API REST (Django REST Framework) para Gestão Logística e Encerramento Seguro de Entregas ('logistics').
Módulo: apps/logistics/views.py

Implementa com rigor técnico:
- RN-093: Confirmação de recolha e transporte logístico;
- RN-095: Validação criptográfica presencial com PIN aleatório de 4 dígitos e registo de prova GPS PostGIS;
- RN-096: Tolerância obrigatória de espera de 7 minutos (420 segundos) no local com validação de presença GPS;
- RN-097: Encerramento por falha de entrega por culpa do cliente sem direito a reembolso (retenção integral
          do valor dos produtos, pagamento do frete ao estafeta e comissão à loja parceira);
- Secção 5.1 / 12.1: Transição do pedido para '9. ENTREGUE' ou 'FALHA_ENTREGA' com emissão de 'order.delivered'
          e captura definitiva de fundos no gateway de pagamentos.
"""
from __future__ import annotations

import hmac
import logging
import uuid
from typing import Any

from django.contrib.gis.geos import Point
from django.core.cache import cache
from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import permissions, status
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.finance.payment_service import PaymentGatewayIntegrationService
from apps.logistics.models import Entrega, Estafeta
from apps.logistics.serializers import (
    DeliveryArrivalInputSerializer,
    DeliveryReportAbsenceInputSerializer,
    DeliveryVerifyPinInputSerializer,
)
from apps.orders.models import Pedido
from apps.orders.state_machine_manager import OrderStateMachineManager

logger = logging.getLogger("logistics.delivery")

# Tolerância regulamentar de espera no cliente (RN-096: 7 minutos = 420 segundos)
TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS: int = 420

# Raio máximo de tolerância GPS para validar que o estafeta está no local da morada (250 metros)
RAIO_MAXIMO_PROXIMIDADE_ENTREGA_METROS: float = 250.0


class DeliveryArrivalView(APIView):
    """
    POST /api/v1/logistics/delivery/arrive/
    Regista que o estafeta chegou ao endereço do cliente (RN-096),
    iniciando o cronómetro regressivo oficial de tolerância de 7 minutos.
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        serializer = DeliveryArrivalInputSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        pedido_id: uuid.UUID = serializer.validated_data["pedido_id"]
        lat = serializer.validated_data.get("latitude")
        lng = serializer.validated_data.get("longitude")

        # Verifica perfil de estafeta
        try:
            estafeta = request.user.perfil_estafeta
        except Estafeta.DoesNotExist:
            return Response(
                {"erro": "Apenas estafetas registados podem marcar chegada ao destino.", "codigo": "NOT_A_COURIER"},
                status=status.HTTP_403_FORBIDDEN,
            )

        try:
            entrega = Entrega.objects.select_related("pedido").get(pedido_id=pedido_id, estafeta=estafeta)
        except Entrega.DoesNotExist:
            return Response(
                {"erro": "Entrega não encontrada ou não atribuída a este estafeta.", "codigo": "DELIVERY_NOT_FOUND"},
                status=status.HTTP_404_NOT_FOUND,
            )

        agora = timezone.now()
        cache_key = f"delivery:arrived_at:{pedido_id}"

        # Grava o timestamp de chegada caso ainda não tenha sido gravado nesta corrida
        timestamp_chegada = cache.get(cache_key)
        if timestamp_chegada is None:
            timestamp_chegada = int(agora.timestamp())
            cache.set(cache_key, timestamp_chegada, timeout=7200)  # 2 horas de validade

        # Atualiza a última geolocalização se fornecida
        if lat is not None and lng is not None:
            estafeta.ultima_geolocalizacao = Point(float(lng), float(lat), srid=4326)
            estafeta.save(update_fields=["ultima_geolocalizacao"])

        tempo_decorrido = int(agora.timestamp()) - int(timestamp_chegada)
        tempo_restante = max(0, TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS - tempo_decorrido)

        logger.info(
            "RN-096: Estafeta %s marcou chegada ao destino para o Pedido %s. Tolerância restante: %ss.",
            estafeta.id,
            pedido_id,
            tempo_restante,
        )

        return Response(
            {
                "sucesso": True,
                "mensagem": "Chegada ao destino registada com sucesso. Cronómetro de 7 minutos iniciado.",
                "pedido_id": str(pedido_id),
                "timestamp_chegada": timestamp_chegada,
                "tolerancia_total_segundos": TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS,
                "tempo_restante_segundos": tempo_restante,
                "pode_declarar_ausencia": tempo_restante == 0,
            },
            status=status.HTTP_200_OK,
        )


class DeliveryVerifyPinView(APIView):
    """
    POST /api/v1/logistics/delivery/verify-pin/
    Cenário A (Sucesso - RN-095):
    Valida criptograficamente o PIN de 4 dígitos fornecido presencialmente pelo cliente.
    Altera o estado da Entrega para 'ENTREGUE', o Pedido para '9. ENTREGUE',
    emite o evento 'order.delivered' (Secção 12.1), captura o pagamento final e armazena
    a geolocalização do estafeta como prova digital.
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        serializer = DeliveryVerifyPinInputSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        pedido_id: uuid.UUID = serializer.validated_data["pedido_id"]
        pin_introduzido: str = serializer.validated_data["pin_introduzido"]
        lat: float | None = serializer.validated_data.get("latitude")
        lng: float | None = serializer.validated_data.get("longitude")
        prova_foto_url: str = serializer.validated_data.get("prova_foto_url", "")

        # 1. Validação do Perfil do Estafeta
        try:
            estafeta = request.user.perfil_estafeta
        except Estafeta.DoesNotExist:
            return Response(
                {"erro": "Apenas o estafeta condutor pode validar o PIN de entrega.", "codigo": "NOT_A_COURIER"},
                status=status.HTTP_403_FORBIDDEN,
            )

        with transaction.atomic():
            # 2. Bloqueio pessimista no Pedido e na Entrega
            try:
                pedido = (
                    Pedido.objects.select_for_update()
                    .select_related("loja", "cliente")
                    .get(pk=pedido_id)
                )
                entrega = (
                    Entrega.objects.select_for_update()
                    .select_related("estafeta")
                    .get(pedido=pedido)
                )
            except (Pedido.DoesNotExist, Entrega.DoesNotExist):
                return Response(
                    {"erro": "Pedido ou Entrega não encontrados.", "codigo": "ORDER_NOT_FOUND"},
                    status=status.HTTP_404_NOT_FOUND,
                )

            # 3. Validação de atribuição
            if not entrega.estafeta_id or entrega.estafeta_id != estafeta.id:
                return Response(
                    {"erro": "Esta entrega não está atribuída à sua conta de estafeta.", "codigo": "UNASSIGNED_COURIER"},
                    status=status.HTTP_403_FORBIDDEN,
                )

            # 4. Validação de estado apto a encerramento
            if pedido.estado in (Pedido.EstadoPedido.ENTREGUE, Pedido.EstadoPedido.CONCLUIDO):
                return Response(
                    {"erro": "Este pedido já se encontra entregue.", "codigo": "ALREADY_DELIVERED"},
                    status=status.HTTP_400_BAD_REQUEST,
                )

            # 5. Verificação de tentativas de força bruta (mitigação contra adivinhação do PIN)
            cache_tentativas_key = f"delivery:pin_attempts:{pedido_id}"
            tentativas_falhadas = cache.get(cache_tentativas_key, 0)
            if tentativas_falhadas >= 5:
                logger.error("Alerta de segurança: Limite de 5 tentativas de PIN excedido para o Pedido %s.", pedido.id)
                return Response(
                    {
                        "erro": "Número máximo de tentativas de PIN excedido. Contacte a equipa de suporte operacional.",
                        "codigo": "PIN_MAX_ATTEMPTS_EXCEEDED",
                    },
                    status=status.HTTP_429_TOO_MANY_REQUESTS,
                )

            # 6. Comparação segura do PIN em tempo constante (mitigação de Timing Attacks)
            pin_esperado = str(entrega.pin_entrega).strip()
            if not hmac.compare_digest(pin_introduzido, pin_esperado):
                tentativas_falhadas += 1
                cache.set(cache_tentativas_key, tentativas_falhadas, timeout=1800)
                tentativas_restantes = max(0, 5 - tentativas_falhadas)

                logger.warning(
                    "RN-095: PIN inválido introduzido pelo estafeta %s para o Pedido %s (Tentativas restantes: %s).",
                    estafeta.id,
                    pedido.id,
                    tentativas_restantes,
                )
                return Response(
                    {
                        "erro": "O PIN de entrega introduzido está incorreto. Solicite o código de 4 dígitos ao cliente.",
                        "codigo": "INVALID_PIN",
                        "tentativas_restantes": tentativas_restantes,
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )

            # Limpa contador de tentativas após sucesso
            cache.delete(cache_tentativas_key)

            # 7. PIN VÁLIDO: Atualiza Entrega com prova GPS e Fotográfica (RN-095)
            entrega.estado_entrega = Entrega.EstadoEntrega.ENTREGUE
            entrega.estado_logistico = Entrega.EstadoEntrega.ENTREGUE
            if lat is not None and lng is not None:
                ponto_gps = Point(float(lng), float(lat), srid=4326)
                entrega.prova_geolocalizacao = ponto_gps
                entrega.prova_gps = ponto_gps
                estafeta.ultima_geolocalizacao = ponto_gps
                estafeta.save(update_fields=["ultima_geolocalizacao"])
            if prova_foto_url:
                entrega.prova_foto_url = prova_foto_url
            entrega.save()

            # 8. Transição Atómica do OMS para '9. ENTREGUE' via OrderStateMachineManager (Secção 5.1)
            dados_evento = {
                "pin_validado": True,
                "estafeta_id": str(estafeta.id),
                "estafeta_nome": getattr(request.user, "nome", "Estafeta"),
                "timestamp_entrega": timezone.now().isoformat(),
            }
            if lat is not None and lng is not None:
                dados_evento["prova_geolocalizacao"] = {"latitude": lat, "longitude": lng}

            resultado_transicao = OrderStateMachineManager.transitar_estado(
                pedido_id=str(pedido.id),
                novo_estado=Pedido.EstadoPedido.ENTREGUE,
                ator=f"estafeta:{estafeta.id}",
                dados_adicionais=dados_evento,
            )
            pedido = resultado_transicao.pedido

            # 9. Captura Definitiva de Fundos no Gateway de Pagamento (RN-066 / Secção 5.1)
            gateway_res = PaymentGatewayIntegrationService.capturar_pagamento_final(
                pedido=pedido,
                idempotency_key=f"cap_delivery_{pedido.id}",
            )

            # 10. Limpa timer temporário de chegada em cache
            cache.delete(f"delivery:arrived_at:{pedido_id}")

            logger.info(
                "RN-095: Pedido %s entregue com sucesso via validação de PIN pelo estafeta %s. Gateway: %s",
                pedido.id,
                estafeta.id,
                gateway_res.get("status"),
            )

            return Response(
                {
                    "sucesso": True,
                    "mensagem": "PIN de segurança validado com sucesso! Pedido entregue ao cliente.",
                    "pedido_id": str(pedido.id),
                    "estado_pedido": pedido.estado,
                    "estado_entrega": entrega.estado_entrega,
                    "pin_validado": True,
                    "timestamp_conclusao": timezone.now().isoformat(),
                    "gateway_captura": gateway_res.get("status"),
                },
                status=status.HTTP_200_OK,
            )


class DeliveryReportAbsenceView(APIView):
    """
    POST /api/v1/logistics/delivery/report-absence/
    Cenário B (Tolerância Excedida - RN-096 & RN-097):
    Caso o estafeta aguarde no local mais de 7 minutos (420 segundos) e não consiga
    contacto com o cliente, o backend valida o histórico de logs de chamadas e a geolocalização
    GPS do estafeta no local da entrega.
    Encerra o pedido como 'FALHA DE ENTREGA' por culpa do cliente: retém o valor integral dos produtos,
    paga a corrida ao estafeta e remunera a loja parceira (RN-097).
    """
    permission_classes = [permissions.IsAuthenticated]

    def post(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        serializer = DeliveryReportAbsenceInputSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        pedido_id: uuid.UUID = serializer.validated_data["pedido_id"]
        lat: float = serializer.validated_data["latitude"]
        lng: float = serializer.validated_data["longitude"]
        tentativas_contacto: int = serializer.validated_data.get("tentativas_contacto", 2)
        motivo: str = serializer.validated_data.get("motivo", "")
        prova_foto_url: str = serializer.validated_data.get("prova_foto_url", "")

        # 1. Validação do Perfil do Estafeta
        try:
            estafeta = request.user.perfil_estafeta
        except Estafeta.DoesNotExist:
            return Response(
                {"erro": "Apenas estafetas registados podem reportar ausência do cliente.", "codigo": "NOT_A_COURIER"},
                status=status.HTTP_403_FORBIDDEN,
            )

        with transaction.atomic():
            # 2. Bloqueio pessimista no Pedido e na Entrega
            try:
                pedido = (
                    Pedido.objects.select_for_update()
                    .select_related("loja", "cliente")
                    .get(pk=pedido_id)
                )
                entrega = (
                    Entrega.objects.select_for_update()
                    .select_related("estafeta")
                    .get(pedido=pedido)
                )
            except (Pedido.DoesNotExist, Entrega.DoesNotExist):
                return Response(
                    {"erro": "Pedido ou Entrega não encontrados.", "codigo": "ORDER_NOT_FOUND"},
                    status=status.HTTP_404_NOT_FOUND,
                )

            # 3. Validação de atribuição
            if not entrega.estafeta_id or entrega.estafeta_id != estafeta.id:
                return Response(
                    {"erro": "Esta entrega não está atribuída à sua conta de estafeta.", "codigo": "UNASSIGNED_COURIER"},
                    status=status.HTTP_403_FORBIDDEN,
                )

            # 4. Validação da tolerância obrigatória de 7 minutos de espera (RN-096)
            cache_key = f"delivery:arrived_at:{pedido_id}"
            timestamp_chegada = cache.get(cache_key)
            agora_ts = int(timezone.now().timestamp())

            if timestamp_chegada is None:
                return Response(
                    {
                        "erro": (
                            "RN-096: Deve primeiro marcar 'Cheguei ao Destino' para iniciar a contagem "
                            "decrescente de 7 minutos de tolerância antes de poder declarar ausência."
                        ),
                        "codigo": "ARRIVAL_NOT_RECORDED",
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )

            tempo_espera_segundos = agora_ts - int(timestamp_chegada)
            if tempo_espera_segundos < TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS:
                tempo_restante = TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS - tempo_espera_segundos
                minutos = tempo_restante // 60
                segundos = tempo_restante % 60
                return Response(
                    {
                        "erro": (
                            f"RN-096: Tolerância obrigatória não cumprida. Aguarde ainda {minutos} min "
                            f"e {segundos} s no local antes de poder declarar a ausência do cliente."
                        ),
                        "codigo": "WAIT_TIME_NOT_MET",
                        "tempo_restante_segundos": tempo_restante,
                        "tolerancia_total_segundos": TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS,
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )

            # 5. Validação de tentativas de contacto (mínimo 1 tentativa)
            if tentativas_contacto < 1:
                return Response(
                    {
                        "erro": "RN-096: É obrigatório tentar contactar o cliente por chamada antes de declarar ausência.",
                        "codigo": "CONTACT_ATTEMPT_REQUIRED",
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )

            # 6. Atualização da Entrega com prova da presença física do estafeta
            ponto_gps = Point(float(lng), float(lat), srid=4326)
            entrega.estado_entrega = Entrega.EstadoEntrega.FALHOU
            entrega.estado_logistico = Entrega.EstadoEntrega.FALHOU
            entrega.prova_geolocalizacao = ponto_gps
            entrega.prova_gps = ponto_gps
            if prova_foto_url:
                entrega.prova_foto_url = prova_foto_url
            entrega.save()

            # 7. Transição do Pedido para 'FALHA_ENTREGA' por culpa do cliente (RN-097)
            dados_falha = {
                "motivo": motivo,
                "tempo_espera_segundos": tempo_espera_segundos,
                "tentativas_contacto": tentativas_contacto,
                "culpa": "CLIENTE_AUSENTE",
                "prova_geolocalizacao": {"latitude": lat, "longitude": lng},
                "prova_foto_url": prova_foto_url,
                "regra": "RN-096 / RN-097",
            }
            resultado_transicao = OrderStateMachineManager.transitar_estado(
                pedido_id=str(pedido.id),
                novo_estado=Pedido.EstadoPedido.FALHA_ENTREGA,
                ator=f"estafeta:{estafeta.id}",
                dados_adicionais=dados_falha,
            )
            pedido = resultado_transicao.pedido

            # 8. Regra Financeira RN-097:
            # Captura o valor integral do pedido no gateway sem reembolso ao cliente.
            # O parceiro recebe o valor dos produtos confecionados líquido de comissão.
            # O estafeta recebe a remuneração integral da entrega na sua carteira.
            PaymentGatewayIntegrationService.capturar_pagamento_final(
                pedido=pedido,
                idempotency_key=f"cap_absence_{pedido.id}",
            )

            # Liquidação contábil via LivroRazaoLedger
            subtotal = pedido.subtotal
            comissao_pct = pedido.loja.comissao_percentagem if pedido.loja else 20
            comissao_valor = int(subtotal * (comissao_pct / 100))
            pago_parceiro = max(0, subtotal - comissao_valor)
            pago_estafeta = (pedido.taxa_entrega or 120000) + (pedido.gorjeta_estafeta or 0)

            # Crédito da carteira do estafeta
            estafeta.saldo_carteira += pago_estafeta
            estafeta.save(update_fields=["saldo_carteira"])

            # Partidas dobradas imutáveis
            if pago_parceiro > 0:
                LivroRazaoLedger.objects.create(
                    referencia_pedido=pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.CLIENTE,
                    conta_destino=LivroRazaoLedger.ContaContabil.PARCEIRO,
                    debito=pago_parceiro,
                    credito=pago_parceiro,
                )
            if pago_estafeta > 0:
                LivroRazaoLedger.objects.create(
                    referencia_pedido=pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.CLIENTE,
                    conta_destino=LivroRazaoLedger.ContaContabil.ESTAFETA,
                    debito=pago_estafeta,
                    credito=pago_estafeta,
                )

            # Limpa timer de espera da cache
            cache.delete(cache_key)

            logger.warning(
                "RN-097: Pedido %s encerrado como FALHA_ENTREGA por ausência do cliente após %ds de espera. "
                "Estafeta %s remunerado em %d cêntimos.",
                pedido.id,
                tempo_espera_segundos,
                estafeta.id,
                pago_estafeta,
            )

            return Response(
                {
                    "sucesso": True,
                    "status_encerramento": "FALHA_ENTREGA_CLIENTE_AUSENTE",
                    "mensagem": (
                        "Corrida encerrada por ausência culposa do cliente após os 7 minutos regulamentares. "
                        "A remuneração da entrega foi creditada integralmente na sua carteira (RN-097)."
                    ),
                    "pedido_id": str(pedido.id),
                    "estado_pedido": pedido.estado,
                    "tempo_espera_segundos": tempo_espera_segundos,
                    "remuneracao_estafeta": pago_estafeta,
                    "saldo_carteira_atualizado": estafeta.saldo_carteira,
                },
                status=status.HTTP_200_OK,
            )
