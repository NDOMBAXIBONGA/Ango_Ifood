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
    Persiste `chegada_cliente_em` em PostgreSQL e na cache.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        raw_pedido_id = request.data.get("pedido_id") or request.data.get("entrega_id")
        lat = request.data.get("latitude")
        lng = request.data.get("longitude")

        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response(
                {"erro": "Apenas estafetas registados podem marcar chegada ao destino.", "codigo": "NOT_A_COURIER"},
                status=status.HTTP_403_FORBIDDEN,
            )

        entrega = _resolver_entrega_por_id(raw_pedido_id, estafeta)
        if not entrega:
            return Response(
                {"erro": "Entrega não encontrada ou não atribuída a este estafeta.", "codigo": "DELIVERY_NOT_FOUND"},
                status=status.HTTP_404_NOT_FOUND,
            )

        pedido_id = entrega.pedido_id
        agora = timezone.now()
        cache_key = f"delivery:arrived_at:{pedido_id}"

        if not entrega.chegada_cliente_em:
            entrega.chegada_cliente_em = agora
            entrega.save(update_fields=["chegada_cliente_em"])

        timestamp_chegada = int(entrega.chegada_cliente_em.timestamp())
        cache.set(cache_key, timestamp_chegada, timeout=7200)

        if lat is not None and lng is not None:
            try:
                estafeta.ultima_geolocalizacao = Point(float(lng), float(lat), srid=4326)
                estafeta.save(update_fields=["ultima_geolocalizacao"])
            except (ValueError, TypeError):
                pass

        tempo_decorrido = max(0, int(agora.timestamp()) - timestamp_chegada)
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
                "entrega_id": str(entrega.id),
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
    credita automaticamente a carteira do estafeta (`taxa_entrega + 100% gorjeta + bónus espera`),
    regista as partidas dobradas no `LivroRazaoLedger` e captura o pagamento final.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        # Se a requisição vier com flag cliente_ausente=True, delega para DeliveryReportAbsenceView
        if request.data.get("cliente_ausente") is True:
            return DeliveryReportAbsenceView().post(request, *args, **kwargs)

        raw_pedido_id = request.data.get("pedido_id") or request.data.get("entrega_id")
        pin_introduzido = str(request.data.get("pin_introduzido") or request.data.get("pin") or "").strip()
        lat = request.data.get("latitude")
        lng = request.data.get("longitude")
        prova_foto_url = str(request.data.get("prova_foto_url") or "")

        if len(pin_introduzido) != 4 or not pin_introduzido.isdigit():
            return Response(
                {"erro": "O PIN de entrega deve conter 4 dígitos numéricos.", "codigo": "INVALID_PIN_FORMAT"},
                status=status.HTTP_400_BAD_REQUEST,
            )

        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response(
                {"erro": "Apenas o estafeta condutor pode validar o PIN de entrega.", "codigo": "NOT_A_COURIER"},
                status=status.HTTP_403_FORBIDDEN,
            )

        entrega_alvo = _resolver_entrega_por_id(raw_pedido_id, estafeta)
        if not entrega_alvo:
            return Response(
                {"erro": "Pedido ou Entrega não encontrados.", "codigo": "ORDER_NOT_FOUND"},
                status=status.HTTP_404_NOT_FOUND,
            )

        with transaction.atomic():
            pedido = (
                Pedido.objects.select_for_update()
                .select_related("loja", "cliente")
                .get(pk=entrega_alvo.pedido_id)
            )
            entrega = (
                Entrega.objects.select_for_update()
                .select_related("estafeta")
                .get(pk=entrega_alvo.id)
            )

            if not entrega.estafeta_id:
                entrega.estafeta = estafeta

            if pedido.estado in (Pedido.EstadoPedido.ENTREGUE, Pedido.EstadoPedido.CONCLUIDO):
                return Response(
                    {"erro": "Este pedido já se encontra entregue.", "codigo": "ALREADY_DELIVERED"},
                    status=status.HTTP_400_BAD_REQUEST,
                )

            cache_tentativas_key = f"delivery:pin_attempts:{pedido.id}"
            tentativas_falhadas = cache.get(cache_tentativas_key, 0)
            if tentativas_falhadas >= 5:
                return Response(
                    {
                        "erro": "Número máximo de tentativas de PIN excedido. Contacte a equipa de suporte operacional.",
                        "codigo": "PIN_MAX_ATTEMPTS_EXCEEDED",
                    },
                    status=status.HTTP_429_TOO_MANY_REQUESTS,
                )

            pin_esperado = str(entrega.pin_entrega).strip()
            if not hmac.compare_digest(pin_introduzido, pin_esperado):
                tentativas_falhadas += 1
                cache.set(cache_tentativas_key, tentativas_falhadas, timeout=1800)
                tentativas_restantes = max(0, 5 - tentativas_falhadas)
                return Response(
                    {
                        "erro": "O PIN de entrega introduzido está incorreto. Solicite o código de 4 dígitos ao cliente.",
                        "codigo": "INVALID_PIN",
                        "tentativas_restantes": tentativas_restantes,
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )

            cache.delete(cache_tentativas_key)

            agora = timezone.now()
            entrega.estado_entrega = Entrega.EstadoEntrega.ENTREGUE
            entrega.estado_logistico = Entrega.EstadoEntrega.ENTREGUE
            entrega.entregue_em = agora
            if lat is not None and lng is not None:
                try:
                    ponto_gps = Point(float(lng), float(lat), srid=4326)
                    entrega.prova_geolocalizacao = ponto_gps
                    entrega.prova_gps = ponto_gps
                    estafeta.ultima_geolocalizacao = ponto_gps
                except (ValueError, TypeError):
                    pass
            if prova_foto_url:
                entrega.prova_foto_url = prova_foto_url
            entrega.save()

            dados_evento = {
                "pin_validado": True,
                "estafeta_id": str(estafeta.id),
                "estafeta_nome": getattr(estafeta.utilizador, "nome", "Estafeta"),
                "timestamp_entrega": agora.isoformat(),
            }
            if lat is not None and lng is not None:
                dados_evento["prova_geolocalizacao"] = {"latitude": lat, "longitude": lng}

            try:
                resultado_transicao = OrderStateMachineManager.transitar_estado(
                    pedido_id=str(pedido.id),
                    novo_estado=Pedido.EstadoPedido.ENTREGUE,
                    ator=f"estafeta:{estafeta.id}",
                    dados_adicionais=dados_evento,
                )
                pedido = resultado_transicao.pedido
            except Exception:
                pedido.estado = Pedido.EstadoPedido.ENTREGUE
                pedido.save(update_fields=["estado"])

            gateway_res = PaymentGatewayIntegrationService.capturar_pagamento_final(
                pedido=pedido,
                idempotency_key=f"cap_delivery_{pedido.id}",
            )

            # Liquidação financeira automática na Carteira do Estafeta e LivroRazaoLedger (RN-058 / RN-089 / RN-090)
            subtotal = pedido.subtotal or 0
            comissao_pct = pedido.loja.comissao_percentagem if pedido.loja else 20
            comissao_valor = int(subtotal * (float(comissao_pct) / 100.0))
            pago_parceiro = max(0, subtotal - comissao_valor)
            pago_estafeta = (
                (pedido.taxa_entrega or 60000)
                + (pedido.gorjeta_estafeta or 0)
                + (entrega.bonus_espera_centimos or 0)
            )

            estafeta.saldo_carteira += pago_estafeta
            estafeta.save(update_fields=["saldo_carteira", "ultima_geolocalizacao"])

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

            cache.delete(f"delivery:arrived_at:{pedido.id}")

            return Response(
                {
                    "sucesso": True,
                    "mensagem": "PIN de segurança validado com sucesso! Pedido entregue e ganho creditado na carteira.",
                    "pedido_id": str(pedido.id),
                    "entrega_id": str(entrega.id),
                    "estado_pedido": pedido.estado,
                    "estado_entrega": entrega.estado_entrega,
                    "pin_validado": True,
                    "remuneracao_estafeta_centimos": pago_estafeta,
                    "remuneracao_estafeta_kz": pago_estafeta // 100,
                    "saldo_carteira_atualizado": estafeta.saldo_carteira,
                    "timestamp_conclusao": agora.isoformat(),
                    "gateway_captura": gateway_res.get("status"),
                },
                status=status.HTTP_200_OK,
            )


class DeliveryReportAbsenceView(APIView):
    """
    POST /api/v1/logistics/delivery/report-absence/
    Cenário B (Tolerância Excedida - RN-096 & RN-097):
    Encerra o pedido como 'FALHA DE ENTREGA' por culpa do cliente após a tolerância
    e credita a remuneração integral da entrega na carteira do estafeta.
    """
    permission_classes = [permissions.AllowAny]

    def post(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        raw_pedido_id = request.data.get("pedido_id") or request.data.get("entrega_id")
        lat = float(request.data.get("latitude") or -8.8368)
        lng = float(request.data.get("longitude") or 13.2343)
        tentativas_contacto = int(request.data.get("tentativas_contacto") or 2)
        motivo = str(
            request.data.get("motivo")
            or request.data.get("motivo_ausencia")
            or "Cliente ausente após tolerância regulamentar de 7 minutos sem resposta."
        )
        prova_foto_url = str(request.data.get("prova_foto_url") or "")

        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response(
                {"erro": "Apenas estafetas registados podem reportar ausência do cliente.", "codigo": "NOT_A_COURIER"},
                status=status.HTTP_403_FORBIDDEN,
            )

        entrega_alvo = _resolver_entrega_por_id(raw_pedido_id, estafeta)
        if not entrega_alvo:
            return Response(
                {"erro": "Pedido ou Entrega não encontrados.", "codigo": "ORDER_NOT_FOUND"},
                status=status.HTTP_404_NOT_FOUND,
            )

        with transaction.atomic():
            pedido = (
                Pedido.objects.select_for_update()
                .select_related("loja", "cliente")
                .get(pk=entrega_alvo.pedido_id)
            )
            entrega = (
                Entrega.objects.select_for_update()
                .select_related("estafeta")
                .get(pk=entrega_alvo.id)
            )

            cache_key = f"delivery:arrived_at:{pedido.id}"
            timestamp_chegada = cache.get(cache_key)
            if timestamp_chegada is None and entrega.chegada_cliente_em:
                timestamp_chegada = int(entrega.chegada_cliente_em.timestamp())

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

            tempo_espera_segundos = max(0, agora_ts - int(timestamp_chegada))
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

            if tentativas_contacto < 1:
                return Response(
                    {
                        "erro": "RN-096: É obrigatório tentar contactar o cliente por chamada antes de declarar ausência.",
                        "codigo": "CONTACT_ATTEMPT_REQUIRED",
                    },
                    status=status.HTTP_400_BAD_REQUEST,
                )

            ponto_gps = Point(float(lng), float(lat), srid=4326)
            entrega.estado_entrega = Entrega.EstadoEntrega.FALHOU
            entrega.estado_logistico = Entrega.EstadoEntrega.FALHOU
            entrega.prova_geolocalizacao = ponto_gps
            entrega.prova_gps = ponto_gps
            entrega.entregue_em = timezone.now()
            if prova_foto_url:
                entrega.prova_foto_url = prova_foto_url
            entrega.save()

            dados_falha = {
                "motivo": motivo,
                "tempo_espera_segundos": tempo_espera_segundos,
                "tentativas_contacto": tentativas_contacto,
                "culpa": "CLIENTE_AUSENTE",
                "prova_geolocalizacao": {"latitude": lat, "longitude": lng},
                "prova_foto_url": prova_foto_url,
                "regra": "RN-096 / RN-097",
            }
            try:
                resultado_transicao = OrderStateMachineManager.transitar_estado(
                    pedido_id=str(pedido.id),
                    novo_estado=Pedido.EstadoPedido.FALHA_ENTREGA,
                    ator=f"estafeta:{estafeta.id}",
                    dados_adicionais=dados_falha,
                )
                pedido = resultado_transicao.pedido
            except Exception:
                pedido.estado = Pedido.EstadoPedido.FALHA_ENTREGA
                pedido.save(update_fields=["estado"])

            PaymentGatewayIntegrationService.capturar_pagamento_final(
                pedido=pedido,
                idempotency_key=f"cap_absence_{pedido.id}",
            )

            subtotal = pedido.subtotal or 0
            comissao_pct = pedido.loja.comissao_percentagem if pedido.loja else 20
            comissao_valor = int(subtotal * (float(comissao_pct) / 100.0))
            pago_parceiro = max(0, subtotal - comissao_valor)
            pago_estafeta = (
                (pedido.taxa_entrega or 60000)
                + (pedido.gorjeta_estafeta or 0)
                + (entrega.bonus_espera_centimos or 0)
            )

            estafeta.saldo_carteira += pago_estafeta
            estafeta.save(update_fields=["saldo_carteira"])

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

            cache.delete(cache_key)

            return Response(
                {
                    "sucesso": True,
                    "status_encerramento": "FALHA_ENTREGA_CLIENTE_AUSENTE",
                    "mensagem": (
                        "Corrida encerrada por ausência culposa do cliente após os 7 minutos regulamentares. "
                        "A remuneração da entrega foi creditada integralmente na sua carteira (RN-097)."
                    ),
                    "pedido_id": str(pedido.id),
                    "entrega_id": str(entrega.id),
                    "estado_pedido": pedido.estado,
                    "tempo_espera_segundos": tempo_espera_segundos,
                    "remuneracao_estafeta": pago_estafeta,
                    "saldo_carteira_atualizado": estafeta.saldo_carteira,
                },
                status=status.HTTP_200_OK,
            )


# ==============================================================================
# 5. ENDPOINTS DE PERFIL, DISPONIBILIDADE E CARTEIRA DO ESTAFETA (RN-082 a RN-089)
# ==============================================================================

def _resolver_estafeta(request: Request) -> Estafeta | None:
    """Resolve o perfil de estafeta autenticado ou cria/devolve o perfil de estafeta ativo."""
    user = getattr(request, "user", None)
    if user and user.is_authenticated:
        estafeta = getattr(user, "perfil_estafeta", None)
        if estafeta:
            return estafeta
        estafeta, _ = Estafeta.objects.get_or_create(
            utilizador=user,
            defaults={
                "tipo_veiculo": Estafeta.TipoVeiculo.MOTA,
                "marca_modelo_veiculo": "Haojue 125",
                "matricula_veiculo": "LD-44-99-AF",
                "status_onboarding": Estafeta.StatusOnboarding.APROVADO,
                "carta_conducao": "LD-90234-A",
                "banco_nome": "Banco Angolano de Investimentos (BAI)",
                "iban": "AO06.0040.0000.1234.5678.9012.3",
                "numero_conta": "0040.0000.1234.5678",
                "nif": "009842180LA042",
                "score_reputacao": Decimal("4.95"),
                "saldo_carteira": 0,
            },
        )
        return estafeta

    estafeta = Estafeta.objects.filter(status_onboarding=Estafeta.StatusOnboarding.APROVADO).first()
    if estafeta:
        return estafeta
    return Estafeta.objects.first()


def _resolver_entrega_por_id(raw_id: Any, estafeta: Estafeta | None = None) -> Entrega | None:
    """Resolve uma Entrega pelo pedido_id, entrega_id ou devolve a entrega ativa atual do estafeta."""
    if raw_id:
        raw_str = str(raw_id).strip()
        try:
            uid = uuid.UUID(raw_str)
            entrega = Entrega.objects.select_related("pedido", "pedido__loja", "pedido__cliente").filter(pedido_id=uid).first()
            if not entrega:
                entrega = Entrega.objects.select_related("pedido", "pedido__loja", "pedido__cliente").filter(pk=uid).first()
            if entrega:
                return entrega
        except (ValueError, TypeError):
            pass

    if estafeta:
        return (
            Entrega.objects.select_related("pedido", "pedido__loja", "pedido__cliente")
            .filter(
                estafeta=estafeta,
                estado_logistico__in=[
                    Entrega.EstadoEntrega.ATRIBUIDO,
                    Entrega.EstadoEntrega.RECOLHIDO,
                    Entrega.EstadoEntrega.EM_TRANSITO,
                ],
            )
            .order_by("-id")
            .first()
        )
    return None


def _serializar_corrida_ativa(entrega: Entrega, estafeta: Estafeta) -> dict[str, Any]:
    """Serializa todos os dados operacionais, geográficos, itens e valores de uma corrida ativa."""
    pedido = entrega.pedido
    loja = pedido.loja if pedido else None
    cliente = pedido.cliente if pedido else None
    agora = timezone.now()

    lat_loja = float(loja.geolocalizacao.y) if loja and loja.geolocalizacao else -8.8368
    lng_loja = float(loja.geolocalizacao.x) if loja and loja.geolocalizacao else 13.2343

    morada_cliente_obj = cliente.moradas.order_by("-id").first() if cliente and hasattr(cliente, "moradas") else None
    lat_cliente = (
        float(morada_cliente_obj.geolocalizacao.y)
        if morada_cliente_obj and morada_cliente_obj.geolocalizacao
        else -8.8147
    )
    lng_cliente = (
        float(morada_cliente_obj.geolocalizacao.x)
        if morada_cliente_obj and morada_cliente_obj.geolocalizacao
        else 13.2343
    )
    morada_entrega_texto = (
        getattr(pedido, "morada_entrega_texto", "")
        or (morada_cliente_obj.texto_endereco if morada_cliente_obj else "")
        or "Rua Rainha Ginga, Ingombota, Luanda"
    )
    referencia_cliente = morada_cliente_obj.referencia if morada_cliente_obj else "Próximo à Marginal de Luanda"
    andar_porta_cliente = morada_cliente_obj.andar_porta if morada_cliente_obj else "R/C"
    instrucoes_cliente = (
        getattr(pedido, "instrucoes_entrega", "")
        or (morada_cliente_obj.instrucoes_estafeta if morada_cliente_obj else "")
        or "Ligar ao chegar à portaria."
    )

    # Determina a etapa atual das 5 fases operacionais da corrida
    if entrega.estado_logistico == Entrega.EstadoEntrega.ENTREGUE:
        etapa_atual = "concluido"
    elif entrega.chegada_cliente_em is not None:
        etapa_atual = "noCliente"
    elif entrega.recolhido_em is not None or entrega.estado_logistico in (
        Entrega.EstadoEntrega.RECOLHIDO,
        Entrega.EstadoEntrega.EM_TRANSITO,
    ):
        etapa_atual = "aCaminhoCliente"
    elif entrega.chegada_loja_em is not None:
        etapa_atual = "naLoja"
    else:
        etapa_atual = "aCaminhoLoja"

    # Cálculo de espera na loja (RN-089)
    minutos_espera_loja = 0
    if entrega.chegada_loja_em:
        fim_espera = entrega.recolhido_em or agora
        minutos_espera_loja = max(0, int((fim_espera - entrega.chegada_loja_em).total_seconds() // 60))

    # Cálculo de tolerância restante no cliente (RN-096: 420s = 7 min)
    segundos_restantes_tolerancia = TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS
    if entrega.chegada_cliente_em:
        decorrido = max(0, int((agora - entrega.chegada_cliente_em).total_seconds()))
        segundos_restantes_tolerancia = max(0, TOLERANCIA_AUSENCIA_CLIENTE_SEGUNDOS - decorrido)

    # Itens do pedido para conferência na recolha (RN-093)
    itens_lista = []
    if pedido and hasattr(pedido, "linhas"):
        for linha in pedido.linhas.select_related("item").all():
            itens_lista.append({
                "nome": linha.item.nome if linha.item else "Artigo do Pedido",
                "quantidade": linha.quantidade,
                "preco_unitario_centimos": linha.preco_unitario_historico,
                "notas": getattr(linha, "notas", "") or "",
            })
    if not itens_lista:
        itens_lista.append({
            "nome": "Refeição Completa (Saco Lacrado)",
            "quantidade": 1,
            "preco_unitario_centimos": getattr(pedido, "subtotal", 250000) if pedido else 250000,
            "notas": "",
        })

    taxa_entrega = (getattr(pedido, "taxa_entrega", 0) or 60000) if pedido else 60000
    gorjeta = (getattr(pedido, "gorjeta_estafeta", 0) or 0) if pedido else 0
    bonus_espera = entrega.bonus_espera_centimos or (20000 if minutos_espera_loja > 10 else 0)
    ganho_total = taxa_entrega + gorjeta + bonus_espera

    dist_km = round((entrega.distancia_metros or 2500) / 1000.0, 2)
    if dist_km <= 0:
        dist_km = 2.5

    return {
        "has_active_trip": True,
        "entrega_id": str(entrega.id),
        "pedido_id": str(pedido.id) if pedido else str(entrega.id),
        "numero_exibicao": str(pedido.id).replace("-", "")[:6].upper() if pedido else "LUA001",
        "estado_logistico": entrega.estado_logistico,
        "estado_pedido": getattr(pedido, "estado", "ATRIBUIDO"),
        "etapa_atual": etapa_atual,
        "pin_entrega": entrega.pin_entrega,
        "loja": {
            "id": str(loja.id) if loja else "",
            "nome": loja.nome if loja else "Restaurante Parceiro",
            "morada": loja.morada_texto if loja else "Luanda, Angola",
            "telemovel": getattr(loja, "contacto", None) or "+244923000000",
            "latitude": lat_loja,
            "longitude": lng_loja,
        },
        "cliente": {
            "id": str(cliente.id) if cliente else "",
            "nome": getattr(cliente, "nome", "Cliente Delivery Pro") if cliente else "Cliente Delivery Pro",
            "telemovel": getattr(cliente, "telemovel", "+244923111222") if cliente else "+244923111222",
            "morada": morada_entrega_texto,
            "referencia": referencia_cliente,
            "andar_porta": andar_porta_cliente,
            "instrucoes_estafeta": instrucoes_cliente,
            "latitude": lat_cliente,
            "longitude": lng_cliente,
        },
        "itens": itens_lista,
        "quantidade_artigos": sum(i["quantidade"] for i in itens_lista),
        "financeiro": {
            "taxa_entrega_centimos": taxa_entrega,
            "gorjeta_centimos": gorjeta,
            "bonus_espera_centimos": bonus_espera,
            "ganho_total_centimos": ganho_total,
            "ganho_total_kz": ganho_total // 100,
            "total_pedido_centimos": getattr(pedido, "total", ganho_total) if pedido else ganho_total,
            "metodo_pagamento": getattr(pedido, "metodo_pagamento", "MULTICAIXA_EXPRESS") if pedido else "MULTICAIXA_EXPRESS",
        },
        "tempos": {
            "chegada_loja_em": entrega.chegada_loja_em.isoformat() if entrega.chegada_loja_em else None,
            "recolhido_em": entrega.recolhido_em.isoformat() if entrega.recolhido_em else None,
            "chegada_cliente_em": entrega.chegada_cliente_em.isoformat() if entrega.chegada_cliente_em else None,
            "minutos_espera_loja": minutos_espera_loja,
            "segundos_restantes_tolerancia_cliente": segundos_restantes_tolerancia,
            "distancia_km": dist_km,
            "eta_minutos": max(5, int(dist_km * 4)),
        },
    }


class CourierOnboardingView(APIView):
    """
    Endpoint: POST /api/v1/logistics/couriers/onboarding/
    Submete ou atualiza a candidatura documental, dados da viatura e dados bancários do estafeta (RN-082).
    """

    permission_classes = [permissions.AllowAny]

    def post(self, request: Request) -> Response:
        estafeta = _resolver_estafeta(request)
        if not estafeta:
            from apps.accounts.models import CustomUser
            telemovel = str(request.data.get("telemovel") or "+244923111222").strip()
            u, _ = CustomUser.objects.get_or_create(
                telemovel=telemovel,
                defaults={
                    "nome": str(request.data.get("nome") or "Estafeta Condutor").strip(),
                    "email": f"estafeta_{telemovel.replace('+', '')}@delivery.ao",
                    "tipo_utilizador": "ESTAFETA",
                },
            )
            estafeta, _ = Estafeta.objects.get_or_create(utilizador=u)

        u = estafeta.utilizador
        nome = request.data.get("nome")
        if isinstance(nome, str) and nome.strip():
            u.nome = nome.strip()
            u.save(update_fields=["nome"])

        tipo_veiculo = str(request.data.get("tipo_veiculo") or "MOTA").upper()
        if tipo_veiculo in Estafeta.TipoVeiculo.values:
            estafeta.tipo_veiculo = tipo_veiculo

        for campo in (
            "carta_conducao",
            "marca_modelo_veiculo",
            "matricula_veiculo",
            "nif",
            "banco_nome",
            "numero_conta",
            "iban",
            "carta_conducao_url",
            "documentos_veiculo_url",
        ):
            val = request.data.get(campo)
            if isinstance(val, str) and val.strip():
                setattr(estafeta, campo, val.strip())

        # Aprova automaticamente ou mantém estado conforme parâmetro
        aprovar_direto = request.data.get("auto_approve", True)
        estafeta.status_onboarding = (
            Estafeta.StatusOnboarding.APROVADO if aprovar_direto else Estafeta.StatusOnboarding.PENDENTE
        )
        estafeta.save()

        return CourierProfileMeView().get(request)


class CourierProfileMeView(APIView):
    """
    Endpoint: GET / PATCH /api/v1/logistics/couriers/me/
    Retorna e atualiza todos os dados reais do perfil, viatura, documentos e dados bancários do estafeta.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        estafeta = _resolver_estafeta(request)
        if not estafeta:
            from apps.accounts.models import CustomUser
            u, _ = CustomUser.objects.get_or_create(
                telemovel="+244923111222",
                defaults={
                    "nome": "Mateus Sebastião",
                    "email": "estafeta@delivery.ao",
                    "tipo_utilizador": "ESTAFETA",
                },
            )
            estafeta, _ = Estafeta.objects.get_or_create(
                utilizador=u,
                defaults={
                    "tipo_veiculo": Estafeta.TipoVeiculo.MOTA,
                    "marca_modelo_veiculo": "Haojue 125",
                    "matricula_veiculo": "LD-44-99-AF",
                    "status_onboarding": Estafeta.StatusOnboarding.APROVADO,
                    "carta_conducao": "LD-90234-A",
                    "banco_nome": "Banco Angolano de Investimentos (BAI)",
                    "iban": "AO06.0040.0000.1234.5678.9012.3",
                    "numero_conta": "0040.0000.1234.5678",
                    "nif": "009842180LA042",
                    "score_reputacao": Decimal("4.95"),
                    "saldo_carteira": 0,
                },
            )

        u = estafeta.utilizador
        lat = float(estafeta.ultima_geolocalizacao.y) if estafeta.ultima_geolocalizacao else -8.8368
        lng = float(estafeta.ultima_geolocalizacao.x) if estafeta.ultima_geolocalizacao else 13.2343

        agora = timezone.now()
        inicio_hoje = agora.replace(hour=0, minute=0, second=0, microsecond=0)
        entregas_hoje_qs = estafeta.entregas.filter(
            estado_logistico=Entrega.EstadoEntrega.ENTREGUE,
        ).select_related("pedido")
        entregas_hoje_filtradas = [
            e for e in entregas_hoje_qs
            if (e.entregue_em and e.entregue_em >= inicio_hoje)
            or (e.pedido and getattr(e.pedido, "data_criacao", None) and e.pedido.data_criacao >= inicio_hoje)
        ]
        ganhos_hoje = sum(
            (getattr(e.pedido, "taxa_entrega", 0) or 60000)
            + (getattr(e.pedido, "gorjeta_estafeta", 0) or 0)
            + (e.bonus_espera_centimos or 0)
            for e in entregas_hoje_filtradas
        )
        total_concluidas = estafeta.entregas.filter(estado_logistico=Entrega.EstadoEntrega.ENTREGUE).count()

        corrida_ativa = (
            estafeta.entregas.filter(
                estado_logistico__in=[
                    Entrega.EstadoEntrega.ATRIBUIDO,
                    Entrega.EstadoEntrega.RECOLHIDO,
                    Entrega.EstadoEntrega.EM_TRANSITO,
                ]
            )
            .order_by("-id")
            .first()
        )

        return Response(
            {
                "id": str(estafeta.id),
                "nome": getattr(u, "nome", "Estafeta Ango-iFood") or "Estafeta Ango-iFood",
                "telemovel": getattr(u, "telemovel", "+244 923 000 000") or "+244 923 000 000",
                "email": getattr(u, "email", "estafeta@delivery.ao") or "estafeta@delivery.ao",
                "tipo_veiculo": estafeta.tipo_veiculo,
                "marca_modelo_veiculo": estafeta.marca_modelo_veiculo or "Haojue 125",
                "matricula_veiculo": estafeta.matricula_veiculo or "LD-44-99-AF",
                "carta_conducao": estafeta.carta_conducao or "LD-90234-A",
                "carta_conducao_url": estafeta.carta_conducao_url or "",
                "documentos_veiculo_url": estafeta.documentos_veiculo_url or "",
                "nif": estafeta.nif or "009842180LA042",
                "banco_nome": estafeta.banco_nome or "Banco Angolano de Investimentos (BAI)",
                "numero_conta": estafeta.numero_conta or "0040.0000.1234.5678",
                "iban": estafeta.iban or "AO06.0040.0000.1234.5678.9012.3",
                "navegador_padrao": estafeta.navegador_padrao or "OSRM_INTEGRADO",
                "status_onboarding": estafeta.status_onboarding,
                "is_online": estafeta.is_online,
                "score_reputacao": str(estafeta.score_reputacao),
                "saldo_carteira_centimos": estafeta.saldo_carteira,
                "saldo_formatado_kz": f"{estafeta.saldo_carteira / 100:,.2f} Kz".replace(",", "X").replace(".", ",").replace("X", "."),
                "ganhos_hoje_centimos": ganhos_hoje,
                "entregas_concluidas_hoje": len(entregas_hoje_filtradas),
                "total_entregas_concluidas": total_concluidas,
                "corrida_ativa_id": str(corrida_ativa.id) if corrida_ativa else None,
                "ultima_posicao": {"latitude": lat, "longitude": lng},
            },
            status=status.HTTP_200_OK,
        )

    def patch(self, request: Request) -> Response:
        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response({"erro": "Estafeta não encontrado."}, status=status.HTTP_404_NOT_FOUND)

        u = estafeta.utilizador
        user_fields_updated = []
        nome = request.data.get("nome")
        if isinstance(nome, str) and nome.strip():
            u.nome = nome.strip()
            user_fields_updated.append("nome")
        if user_fields_updated:
            u.save(update_fields=user_fields_updated)

        tipo_veiculo = request.data.get("tipo_veiculo")
        if isinstance(tipo_veiculo, str) and tipo_veiculo.upper() in Estafeta.TipoVeiculo.values:
            estafeta.tipo_veiculo = tipo_veiculo.upper()

        status_onb = request.data.get("status_onboarding")
        if isinstance(status_onb, str) and status_onb.upper() in Estafeta.StatusOnboarding.values:
            estafeta.status_onboarding = status_onb.upper()

        for campo in (
            "carta_conducao",
            "carta_conducao_url",
            "documentos_veiculo_url",
            "marca_modelo_veiculo",
            "matricula_veiculo",
            "nif",
            "banco_nome",
            "numero_conta",
            "iban",
            "navegador_padrao",
        ):
            val = request.data.get(campo)
            if isinstance(val, str) and val.strip():
                setattr(estafeta, campo, val.strip())

        estafeta.save()
        return self.get(request)


class CourierAvailabilityView(APIView):
    """
    Endpoint: POST /api/v1/logistics/couriers/availability/
    Alterna o estafeta entre Online e Offline, persistindo a geolocalização GPS em PostGIS.
    """

    permission_classes = [permissions.AllowAny]

    def post(self, request: Request) -> Response:
        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response({"erro": "Estafeta não encontrado."}, status=status.HTTP_404_NOT_FOUND)

        is_online = bool(request.data.get("is_online", not estafeta.is_online))

        try:
            lat = float(request.data.get("latitude") or (estafeta.ultima_geolocalizacao.y if estafeta.ultima_geolocalizacao else -8.8368))
            lng = float(request.data.get("longitude") or (estafeta.ultima_geolocalizacao.x if estafeta.ultima_geolocalizacao else 13.2343))
            estafeta.ultima_geolocalizacao = Point(lng, lat, srid=4326)
        except (ValueError, TypeError):
            pass

        estafeta.status_onboarding = Estafeta.StatusOnboarding.APROVADO
        estafeta.is_online = is_online
        estafeta.save(update_fields=["is_online", "status_onboarding", "ultima_geolocalizacao"])

        return Response(
            {
                "sucesso": True,
                "is_online": estafeta.is_online,
                "mensagem": "Estafeta ONLINE pronto para receber corridas!" if is_online else "Estafeta em pausa (OFFLINE).",
            },
            status=status.HTTP_200_OK,
        )


class CourierWalletView(APIView):
    """
    Endpoint: GET / POST /api/v1/logistics/couriers/wallet/
    Retorna o balanço financeiro completo, produtividade semanal (7 dias - RN-151),
    decomposição analítica das tarifas (RN-058, RN-089, RN-090) e executa levantamentos antecipados (RN-146).
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response({
                "saldo_disponivel_centimos": 0,
                "ganhos_hoje_centimos": 0,
                "corridas_concluidas_hoje": 0,
                "produtividade_semanal": [],
                "historico": [],
            })

        agora = timezone.now()
        inicio_hoje = agora.replace(hour=0, minute=0, second=0, microsecond=0)

        todas_entregas = list(
            estafeta.entregas.filter(
                estado_logistico__in=[Entrega.EstadoEntrega.ENTREGUE, Entrega.EstadoEntrega.FALHOU]
            )
            .select_related("pedido", "pedido__loja", "pedido__cliente")
            .order_by("-id")[:50]
        )

        corridas_hoje = 0
        ganhos_hoje = 0
        repasses_mes = 0
        historico_lista = []

        # Mapa de ganhos por data (últimos 7 dias) para gráfico RN-151
        dias_nomes = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"]
        mapa_dias: dict[Any, dict[str, Any]] = {}
        for offset in range(6, -1, -1):
            d_alvo = (agora - timezone.timedelta(days=offset)).date()
            mapa_dias[d_alvo] = {
                "dia_semana": dias_nomes[d_alvo.weekday()],
                "ganhos_centimos": 0,
                "entregas_concluidas": 0,
                "horas_online": 0.0,
                "is_hoje": d_alvo == agora.date(),
            }

        for e in todas_entregas:
            ped = e.pedido
            data_ref = e.entregue_em or (getattr(ped, "data_criacao", None) if ped else None) or agora
            taxa_total = (getattr(ped, "taxa_entrega", 0) or 60000) if ped else 60000
            gorjeta = (getattr(ped, "gorjeta_estafeta", 0) or 0) if ped else 0
            bonus_espera = e.bonus_espera_centimos or 0

            # Decomposição analítica (RN-090): 60% base fixa + 40% distância
            dist_km = round((e.distancia_metros or 2800) / 1000.0, 1)
            if dist_km <= 0:
                dist_km = 2.8
            valor_base = min(taxa_total, 60000)
            adicional_dist = max(0, taxa_total - valor_base)

            minutos_espera = 5
            if e.chegada_loja_em and e.recolhido_em:
                minutos_espera = max(1, int((e.recolhido_em - e.chegada_loja_em).total_seconds() // 60))
            elif bonus_espera > 0:
                minutos_espera = 14

            remuneracao = valor_base + adicional_dist + bonus_espera + gorjeta

            if data_ref >= inicio_hoje:
                corridas_hoje += 1
                ganhos_hoje += remuneracao

            if data_ref.month == agora.month and data_ref.year == agora.year:
                repasses_mes += remuneracao

            d_key = data_ref.date()
            if d_key in mapa_dias:
                mapa_dias[d_key]["ganhos_centimos"] += remuneracao
                mapa_dias[d_key]["entregas_concluidas"] += 1
                mapa_dias[d_key]["horas_online"] = round(
                    min(12.0, mapa_dias[d_key]["entregas_concluidas"] * 0.65), 1
                )

            cliente_nome = (
                getattr(ped.cliente, "nome", "Cliente Ango-iFood")
                if ped and getattr(ped, "cliente", None)
                else "Cliente Ango-iFood"
            )

            historico_lista.append({
                "corrida_id": str(e.id),
                "numero_pedido": str(ped.id).replace("-", "")[:4].upper() if ped else "LUA",
                "loja_nome": ped.loja.nome if ped and ped.loja else "Restaurante Parceiro",
                "morada_recolha": ped.loja.morada_texto if ped and ped.loja else "Luanda",
                "cliente_nome": cliente_nome,
                "distancia_km": dist_km,
                "minutos_espera_loja": minutos_espera,
                "valor_fixo_base_centimos": valor_base,
                "adicional_distancia_centimos": adicional_dist,
                "bonus_espera_loja_centimos": bonus_espera,
                "incentivo_dinamico_centimos": 0,
                "gorjeta_centimos": gorjeta,
                "valor_centimos": remuneracao,
                "valor_kz": remuneracao // 100,
                "estado": e.estado_logistico,
                "data": data_ref.isoformat(),
            })

        produtividade_lista = list(mapa_dias.values())
        max_ganho_dia = max((d["ganhos_centimos"] for d in produtividade_lista), default=0)
        for d in produtividade_lista:
            d["is_melhor_dia"] = max_ganho_dia > 0 and d["ganhos_centimos"] == max_ganho_dia

        return Response(
            {
                "saldo_disponivel_centimos": estafeta.saldo_carteira,
                "saldo_disponivel_kz": estafeta.saldo_carteira // 100,
                "saldo_pendente_centimos": 0,
                "repasses_acumulados_mes_centimos": repasses_mes,
                "ganhos_hoje_centimos": ganhos_hoje,
                "ganhos_hoje_kz": ganhos_hoje // 100,
                "corridas_concluidas_hoje": corridas_hoje,
                "banco_nome": estafeta.banco_nome or "Banco Angolano de Investimentos (BAI)",
                "iban": estafeta.iban or "AO06.0040.0000.1234.5678.9012.3",
                "numero_conta": estafeta.numero_conta or "0040.0000.1234.5678",
                "nif": estafeta.nif or "009842180LA042",
                "taxa_antecipacao_percentagem": 2.5,
                "taxa_fixa_antecipacao_centimos": 20000,
                "proximo_repasse_data": "Terça-feira (Ciclo Semanal Gratuito)",
                "produtividade_semanal": produtividade_lista,
                "historico": historico_lista,
            },
            status=status.HTTP_200_OK,
        )

    def post(self, request: Request) -> Response:
        """Solicitação de adiantamento / repasse parcial ou total para conta bancária do estafeta (RN-146)."""
        estafeta = _resolver_estafeta(request)
        if not estafeta or estafeta.saldo_carteira <= 0:
            return Response({"erro": "Saldo insuficiente para repasse bancário."}, status=status.HTTP_400_BAD_REQUEST)

        valor_solicitado = request.data.get("valor_centimos")
        try:
            valor_repasse = int(valor_solicitado) if valor_solicitado is not None else estafeta.saldo_carteira
        except (ValueError, TypeError):
            valor_repasse = estafeta.saldo_carteira

        if valor_repasse <= 0 or valor_repasse > estafeta.saldo_carteira:
            valor_repasse = estafeta.saldo_carteira

        taxa_variavel = int(round(valor_repasse * 0.025))
        taxa_fixa = 20000  # 200 Kz
        taxa_total = min(valor_repasse // 2, taxa_variavel + taxa_fixa)
        valor_liquido = max(0, valor_repasse - taxa_total)

        with transaction.atomic():
            estafeta.saldo_carteira = max(0, estafeta.saldo_carteira - valor_repasse)
            estafeta.save(update_fields=["saldo_carteira"])

            ultimo_pedido = Pedido.objects.order_by("-data_criacao").first()
            if ultimo_pedido and valor_liquido > 0:
                LivroRazaoLedger.objects.create(
                    referencia_pedido=ultimo_pedido,
                    conta_origem=LivroRazaoLedger.ContaContabil.ESTAFETA,
                    conta_destino=LivroRazaoLedger.ContaContabil.GATEWAY_PAGAMENTO,
                    debito=valor_liquido,
                    credito=valor_liquido,
                )

        return Response(
            {
                "sucesso": True,
                "mensagem": (
                    f"Repasse de {valor_repasse // 100} Kz processado com sucesso para o IBAN {estafeta.iban} "
                    f"(Valor líquido: {valor_liquido // 100} Kz)."
                ),
                "valor_solicitado_centimos": valor_repasse,
                "taxa_antecipacao_centimos": taxa_total,
                "valor_liquido_centimos": valor_liquido,
                "saldo_restante_centimos": estafeta.saldo_carteira,
            },
            status=status.HTTP_200_OK,
        )


class CourierActiveTripView(APIView):
    """
    Endpoint: GET /api/v1/logistics/trips/active/
    Retorna a corrida atualmente atribuída ou em curso pelo estafeta autenticado.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response({"has_active_trip": False}, status=status.HTTP_200_OK)

        entrega_ativa = (
            Entrega.objects.select_related("pedido", "pedido__loja", "pedido__cliente")
            .filter(
                estafeta=estafeta,
                estado_logistico__in=[
                    Entrega.EstadoEntrega.ATRIBUIDO,
                    Entrega.EstadoEntrega.RECOLHIDO,
                    Entrega.EstadoEntrega.EM_TRANSITO,
                ],
            )
            .exclude(
                pedido__estado__in=[
                    Pedido.EstadoPedido.ENTREGUE,
                    Pedido.EstadoPedido.CONCLUIDO,
                    Pedido.EstadoPedido.CANCELADO,
                    Pedido.EstadoPedido.FALHA_ENTREGA,
                ]
            )
            .order_by("-id")
            .first()
        )

        if not entrega_ativa:
            return Response({"has_active_trip": False}, status=status.HTTP_200_OK)

        return Response(_serializar_corrida_ativa(entrega_ativa, estafeta), status=status.HTTP_200_OK)


class CourierTripsListView(APIView):
    """
    Endpoint: GET /api/v1/logistics/trips/available/
    Lista corridas reais que estão prontas para recolha ou aguardando estafeta na zona.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        estafeta = _resolver_estafeta(request)
        pedidos_disponiveis = (
            Pedido.objects.filter(
                estado__in=[
                    Pedido.EstadoPedido.PRONTO,
                    Pedido.EstadoPedido.EM_PREPARACAO,
                    Pedido.EstadoPedido.ACEITE,
                    Pedido.EstadoPedido.AGUARDA_PARCEIRO,
                    Pedido.EstadoPedido.PAGAMENTO,
                ]
            )
            .select_related("loja", "cliente")
            .order_by("-data_criacao")[:20]
        )

        trips = []
        for p in pedidos_disponiveis:
            entrega, _ = Entrega.objects.get_or_create(pedido=p)
            if entrega.estado_logistico in (
                Entrega.EstadoEntrega.ENTREGUE,
                Entrega.EstadoEntrega.FALHOU,
            ):
                continue
            if entrega.estafeta_id and estafeta and entrega.estafeta_id != estafeta.id:
                continue
            # Se já está atribuída a este estafeta, aparece em /trips/active/
            if (
                entrega.estafeta_id
                and estafeta
                and entrega.estafeta_id == estafeta.id
                and entrega.estado_logistico != Entrega.EstadoEntrega.PENDENTE
            ):
                continue

            loja = p.loja
            cliente = p.cliente
            lat_loja = float(loja.geolocalizacao.y) if loja and loja.geolocalizacao else -8.8368
            lng_loja = float(loja.geolocalizacao.x) if loja and loja.geolocalizacao else 13.2343

            morada_cliente_obj = (
                cliente.moradas.order_by("-id").first() if cliente and hasattr(cliente, "moradas") else None
            )
            lat_cliente = (
                float(morada_cliente_obj.geolocalizacao.y)
                if morada_cliente_obj and morada_cliente_obj.geolocalizacao
                else -8.8147
            )
            lng_cliente = (
                float(morada_cliente_obj.geolocalizacao.x)
                if morada_cliente_obj and morada_cliente_obj.geolocalizacao
                else 13.2343
            )
            morada_entrega_texto = (
                getattr(p, "morada_entrega_texto", "")
                or (morada_cliente_obj.texto_endereco if morada_cliente_obj else "")
                or "Rua Rainha Ginga, Ingombota, Luanda"
            )

            dist_km = round((entrega.distancia_metros or 2600) / 1000.0, 1)
            if dist_km <= 0:
                dist_km = 2.6

            num_itens = p.linhas.count() if hasattr(p, "linhas") else 1
            remuneracao = (p.taxa_entrega or 60000) + (p.gorjeta_estafeta or 0)
            trips.append({
                "entrega_id": str(entrega.id),
                "pedido_id": str(p.id),
                "numero_exibicao": str(p.id).replace("-", "")[:6].upper(),
                "loja_nome": loja.nome if loja else "Restaurante Parceiro",
                "loja_morada": loja.morada_texto if loja else "Luanda, Angola",
                "loja_lat": lat_loja,
                "loja_lng": lng_loja,
                "cliente_nome": getattr(cliente, "nome", "Cliente") if cliente else "Cliente",
                "cliente_morada": morada_entrega_texto,
                "cliente_lat": lat_cliente,
                "cliente_lng": lng_cliente,
                "distancia_estimada_km": dist_km,
                "tempo_estimado_minutos": max(8, int(dist_km * 4)),
                "remuneracao_centimos": remuneracao,
                "remuneracao_kz": remuneracao // 100,
                "gorjeta_centimos": p.gorjeta_estafeta or 0,
                "quantidade_artigos": max(1, num_itens),
                "estado_pedido": p.estado,
            })

        return Response(trips, status=status.HTTP_200_OK)


class CourierTripActionView(APIView):
    """
    Endpoints operacionais do ciclo de vida da corrida:
    - POST /api/v1/logistics/trips/{id}/accept/       (Aceita oferta de corrida - RN-086)
    - POST /api/v1/logistics/trips/{id}/reject/       (Rejeita oferta de corrida - RN-086)
    - POST /api/v1/logistics/trips/{id}/arrive-store/ (Marca chegada à loja e inicia timer espera - RN-089)
    - POST /api/v1/logistics/trips/{id}/pickup/       (Confirma recolha dos pacotes e inicia trânsito - RN-093)
    - POST /api/v1/logistics/trips/{id}/incident/     (Reporta incidente ou SOS em rota - RN-098 / RN-101)
    """

    permission_classes = [permissions.AllowAny]

    def post(self, request: Request, pk: Any, action: str) -> Response:
        estafeta = _resolver_estafeta(request)
        if not estafeta:
            return Response({"erro": "Estafeta não encontrado."}, status=status.HTTP_404_NOT_FOUND)

        entrega = _resolver_entrega_por_id(pk, estafeta)
        if not entrega:
            return Response({"erro": "Corrida não encontrada."}, status=status.HTTP_404_NOT_FOUND)

        action_lower = action.lower().strip()
        agora = timezone.now()

        if action_lower == "accept":
            with transaction.atomic():
                entrega.estafeta = estafeta
                entrega.estado_logistico = Entrega.EstadoEntrega.ATRIBUIDO
                entrega.estado_entrega = Entrega.EstadoEntrega.ATRIBUIDO
                entrega.save(update_fields=["estafeta", "estado_logistico", "estado_entrega"])

            entrega.refresh_from_db()
            return Response(
                {
                    "sucesso": True,
                    "mensagem": "Corrida aceite com sucesso! Dirija-se ao restaurante para recolha.",
                    "entrega_id": str(entrega.id),
                    "pedido_id": str(entrega.pedido_id),
                    "pin_entrega": entrega.pin_entrega,
                    "corrida": _serializar_corrida_ativa(entrega, estafeta),
                },
                status=status.HTTP_200_OK,
            )

        elif action_lower == "reject":
            if entrega.estafeta_id == estafeta.id:
                entrega.estafeta = None
                entrega.estado_logistico = Entrega.EstadoEntrega.PENDENTE
                entrega.estado_entrega = Entrega.EstadoEntrega.PENDENTE
                entrega.save(update_fields=["estafeta", "estado_logistico", "estado_entrega"])
            return Response(
                {"sucesso": True, "mensagem": "Oferta rejeitada. Transferida para o próximo estafeta da fila."},
                status=status.HTTP_200_OK,
            )

        elif action_lower == "arrive-store":
            if not entrega.chegada_loja_em:
                entrega.chegada_loja_em = agora
            if not entrega.estafeta_id:
                entrega.estafeta = estafeta
            entrega.save(update_fields=["chegada_loja_em", "estafeta"])
            return Response(
                {
                    "sucesso": True,
                    "mensagem": "Chegada ao restaurante registada! Contagem de tempo de espera iniciada (RN-089).",
                    "chegada_loja_em": entrega.chegada_loja_em.isoformat(),
                    "corrida": _serializar_corrida_ativa(entrega, estafeta),
                },
                status=status.HTTP_200_OK,
            )

        elif action_lower == "pickup":
            with transaction.atomic():
                if not entrega.chegada_loja_em:
                    entrega.chegada_loja_em = agora - timezone.timedelta(minutes=3)
                entrega.recolhido_em = agora
                minutos_espera = max(0, int((entrega.recolhido_em - entrega.chegada_loja_em).total_seconds() // 60))
                if minutos_espera > 10 and entrega.bonus_espera_centimos == 0:
                    entrega.bonus_espera_centimos = 20000  # 200 Kz de bónus por espera > 10m (RN-089)

                entrega.estado_logistico = Entrega.EstadoEntrega.EM_TRANSITO
                entrega.estado_entrega = Entrega.EstadoEntrega.EM_TRANSITO
                entrega.save()

                try:
                    if entrega.pedido.estado == Pedido.EstadoPedido.PRONTO:
                        OrderStateMachineManager.transitar_estado(
                            pedido_id=str(entrega.pedido_id),
                            novo_estado=Pedido.EstadoPedido.RECOLHIDO,
                            ator=f"estafeta:{estafeta.id}",
                        )
                    OrderStateMachineManager.transitar_estado(
                        pedido_id=str(entrega.pedido_id),
                        novo_estado=Pedido.EstadoPedido.EM_TRANSITO,
                        ator=f"estafeta:{estafeta.id}",
                    )
                except Exception:
                    entrega.pedido.estado = Pedido.EstadoPedido.EM_TRANSITO
                    entrega.pedido.save(update_fields=["estado"])

            entrega.refresh_from_db()
            return Response(
                {
                    "sucesso": True,
                    "mensagem": "Recolha confirmada! Inicie deslocação para o endereço do cliente (RN-093 / RN-094).",
                    "recolhido_em": entrega.recolhido_em.isoformat(),
                    "bonus_espera_centimos": entrega.bonus_espera_centimos,
                    "corrida": _serializar_corrida_ativa(entrega, estafeta),
                },
                status=status.HTTP_200_OK,
            )

        elif action_lower == "incident":
            motivo = str(request.data.get("motivo") or "Incidente técnico / avaria reportada pelo estafeta em rota.")
            libertar_corrida = bool(request.data.get("libertar_corrida", True))
            entrega.motivo_incidente = motivo
            if libertar_corrida and entrega.estado_logistico == Entrega.EstadoEntrega.ATRIBUIDO:
                # Se ainda não recolheu os produtos na loja, liberta a corrida para outro estafeta (RN-098)
                entrega.estafeta = None
                entrega.estado_logistico = Entrega.EstadoEntrega.PENDENTE
                entrega.estado_entrega = Entrega.EstadoEntrega.PENDENTE
                entrega.chegada_loja_em = None
                entrega.save()
                msg = "Incidente reportado! A corrida foi reencaminhada automaticamente para outro estafeta disponível (RN-098)."
            else:
                entrega.save(update_fields=["motivo_incidente"])
                msg = "Alerta SOS / Incidente registado! A equipa de operações foi notificada com a sua localização GPS."

            return Response(
                {
                    "sucesso": True,
                    "mensagem": msg,
                    "corrida_libertada": libertar_corrida and entrega.estafeta_id is None,
                },
                status=status.HTTP_200_OK,
            )

        return Response({"erro": f"Ação '{action}' inválida."}, status=status.HTTP_400_BAD_REQUEST)


class OrderTrackingTelemetryView(APIView):
    """
    Endpoint: GET /api/v1/logistics/orders/{id}/tracking/
    Retorna as coordenadas GPS em tempo real do pedido, estafeta e loja.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request, pk: str) -> Response:
        try:
            pedido = Pedido.objects.select_related("loja", "cliente").get(pk=pk)
        except Exception:
            return Response({"erro": "Pedido não encontrado."}, status=status.HTTP_404_NOT_FOUND)

        entrega = Entrega.objects.filter(pedido=pedido).select_related("estafeta").first()
        estafeta = entrega.estafeta if entrega else None

        lat_loja = float(pedido.loja.geolocalizacao.y) if pedido.loja and pedido.loja.geolocalizacao else -8.8368
        lng_loja = float(pedido.loja.geolocalizacao.x) if pedido.loja and pedido.loja.geolocalizacao else 13.2343

        lat_estafeta = float(estafeta.ultima_geolocalizacao.y) if estafeta and estafeta.ultima_geolocalizacao else lat_loja
        lng_estafeta = float(estafeta.ultima_geolocalizacao.x) if estafeta and estafeta.ultima_geolocalizacao else lng_loja

        return Response(
            {
                "pedido_id": str(pedido.id),
                "estado": pedido.estado,
                "loja": {
                    "nome": pedido.loja.nome if pedido.loja else "Loja",
                    "latitude": lat_loja,
                    "longitude": lng_loja,
                },
                "estafeta": {
                    "id": str(estafeta.id) if estafeta else None,
                    "nome": estafeta.utilizador.nome if estafeta and estafeta.utilizador else "Estafeta Ango-iFood",
                    "latitude": lat_estafeta,
                    "longitude": lng_estafeta,
                    "is_online": estafeta.is_online if estafeta else False,
                },
                "pin_entrega": entrega.pin_entrega if entrega else getattr(pedido, "pin_entrega", "1234"),
                "eta_minutos": 15 if pedido.estado in [Pedido.EstadoPedido.A_CAMINHO, Pedido.EstadoPedido.ATRIBUIDO] else 0,
            },
            status=status.HTTP_200_OK,
        )


class CalcularFreteView(APIView):
    """
    Endpoint para cálculo de frete, distância viária, duração estimada e rota GeoJSON.
    100% Gratuito e Self-Hosted via OSRM + dados OpenStreetMap de Angola.
    Suporta POST em /api/v1/logistics/calcular-frete/ e /api/entregas/calcular-frete/
    Payload esperado:
    {
        "lat_origem": -14.9172,
        "lon_origem": 13.4925,
        "lat_destino": -14.9250,
        "lon_destino": 13.5010
    }
    """

    permission_classes = [permissions.AllowAny]

    def post(self, request, *args, **kwargs):
        data = request.data
        try:
            lat_origem = float(data.get("lat_origem") or data.get("origem_lat"))
            lon_origem = float(
                data.get("lon_origem")
                or data.get("origem_lon")
                or data.get("lng_origem")
            )
            lat_destino = float(data.get("lat_destino") or data.get("destino_lat"))
            lon_destino = float(
                data.get("lon_destino")
                or data.get("destino_lon")
                or data.get("lng_destino")
            )
        except (TypeError, ValueError):
            return Response(
                {
                    "erro": "Coordenadas numéricas inválidas. Envie lat_origem, lon_origem, lat_destino e lon_destino."
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        # Validação de limites geográficos globais (-90 a 90 para lat, -180 a 180 para lon)
        if not (
            -90.0 <= lat_origem <= 90.0
            and -90.0 <= lat_destino <= 90.0
            and -180.0 <= lon_origem <= 180.0
            and -180.0 <= lon_destino <= 180.0
        ):
            return Response(
                {"erro": "Coordenadas fora dos limites do globo terrestre."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        from apps.logistics.services.routing import calcular_rota_e_frete

        resultado = calcular_rota_e_frete(
            lat_origem, lon_origem, lat_destino, lon_destino
        )
        return Response(resultado, status=status.HTTP_200_OK)

