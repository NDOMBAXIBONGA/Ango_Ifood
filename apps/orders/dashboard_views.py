"""
ViewSet Administrativa para Dashboard de Métricas Operacionais e KPIs de Negócio ('orders' / 'analytics').
Módulo: apps/orders/dashboard_views.py

Implementa com rigor técnico:
- Secção 10: Indicadores de Gestão (KPIs):
  * GMV (Gross Merchandise Value): Soma do valor dos produtos de pedidos concluídos (`Sum('subtotal')`);
  * AOV (Average Order Value): GMV / Total de Pedidos Concluídos;
  * Rentabilidade e Margem de Contribuição por Pedido: Total faturado deduzido de despesas variáveis diretas
    amortizadas (repasse a estafetas, descontos financiados pela plataforma e taxa de gateway de 2%);
- Secção 8.1: Metas Operacionais da Plataforma:
  * Pontualidade de SLAs de Entrega: % de pedidos entregues dentro do prazo estimado (Meta: >= 90%);
  * Taxa de Rejeição por Parceiros: % de pedidos rejeitados sobre pedidos enviados (Meta: <= 3%);
- Secção 11: Chaves primárias UUID e integridade referencial protegida;
- Agregações nativas no banco de dados PostgreSQL (Sum, Count, Case, When, F, ExpressionWrapper).
"""
from __future__ import annotations

import logging
from datetime import datetime, time
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Optional

from django.db.models import (
    Case,
    Count,
    F,
    FloatField,
    IntegerField,
    Q,
    Sum,
    Value,
    When,
)
from django.db.models.functions import Coalesce
from django.utils import timezone
from django.utils.dateparse import parse_date, parse_datetime
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import ValidationError as DRFValidationError
from rest_framework.request import Request
from rest_framework.response import Response

from apps.finance.models import EventoPedido, LivroRazaoLedger
from apps.orders.models import Pedido

logger = logging.getLogger("orders.analytics.dashboard")


# ==============================================================================
# CLASSE DE PERMISSÃO: IsAdminOrFinanceUser
# ==============================================================================

class IsAdminOrFinanceUser(permissions.BasePermission):
    """
    Garante acesso exclusivo a utilizadores do backoffice com perfil de 'Finanças' ou 'Admin'.
    """

    GRUPOS_AUTORIZADOS = {"Admin", "Administrador", "Finanças", "Financas", "Finance"}

    def has_permission(self, request: Request, view: Any) -> bool:
        if not request.user or not request.user.is_authenticated:
            return False

        # Superutilizadores e membros do Staff do Django Admin
        if request.user.is_superuser or request.user.is_staff:
            return True

        # Validação por Grupos RBAC do Django
        grupos_usuario = set(request.user.groups.values_list("name", flat=True))
        if bool(grupos_usuario.intersection(self.GRUPOS_AUTORIZADOS)):
            return True

        # Permissão específica ou role no CustomUser se existente
        cargo_usuario = getattr(request.user, "cargo", None) or getattr(request.user, "role", None)
        if cargo_usuario in ("admin", "finance", "financas"):
            return True

        return False


# ==============================================================================
# VIEWSET PRINCIPAL: OperationalMetricsDashboardViewSet (Secções 10, 8.1 e 11)
# ==============================================================================

class OperationalMetricsDashboardViewSet(viewsets.ViewSet):
    """
    ViewSet administrativa para agregação em alta performance de KPIs e SLAs operacionais.
    Endpoint canónico:
    `GET /api/v1/admin/dashboard/kpis/`
    """

    permission_classes = [permissions.IsAuthenticated, IsAdminOrFinanceUser]

    @action(detail=False, methods=["get"], url_path="kpis")
    def kpis(self, request: Request) -> Response:
        """
        Calcula e devolve a análise multidimensional de KPIs (Secção 10) e Metas Operacionais (Secção 8.1).
        Query Parameters obrigatórios/suportados:
        - `data_inicio`: Data inicial (YYYY-MM-DD ou ISO DateTime) [OBRIGATÓRIO]
        - `data_fim`: Data final (YYYY-MM-DD ou ISO DateTime) [OBRIGATÓRIO]
        - `cidade`: Filtro textual de cidade (ex: 'Luanda')
        - `zona_id`: Filtro de zona operacional ou bairro
        - `categoria_loja`: Filtro de categoria comercial do estabelecimento
        """
        # 1. Parsing, validação e segmentação de filtros (Requisito 1)
        filtros = self._validar_e_extrair_filtros(request)

        # 2. Queryset segmentado no PostgreSQL evitando leituras globais desnecessárias
        base_qs = Pedido.objects.select_related("loja").filter(filtros["q_pedidos"])

        # Contagem total de pedidos criados no período
        total_pedidos_periodo = base_qs.count()

        # Subset de pedidos concluídos com sucesso (Secção 10)
        pedidos_concluidos_qs = base_qs.filter(estado=Pedido.EstadoPedido.CONCLUIDO)
        total_concluidos = pedidos_concluidos_qs.count()

        pedidos_cancelados_count = base_qs.filter(estado=Pedido.EstadoPedido.CANCELADO).count()
        pedidos_rejeitados_count = base_qs.filter(estado=Pedido.EstadoPedido.REJEITADO).count()

        # ----------------------------------------------------------------------
        # REQUISITO 2: GMV (Gross Merchandise Value - Secção 10)
        # Soma agregada do valor final dos produtos: Sum('subtotal') onde estado='CONCLUIDO'
        # ----------------------------------------------------------------------
        agregacao_gmv = pedidos_concluidos_qs.aggregate(
            gmv_total=Coalesce(Sum("subtotal"), Value(0))
        )
        gmv_cents = int(agregacao_gmv["gmv_total"] or 0)
        gmv_kz = round(gmv_cents / 100.0, 2)

        # ----------------------------------------------------------------------
        # REQUISITO 3: AOV (Average Order Value - Secção 10)
        # Divide o GMV pelo número de pedidos concluídos, tratando divisão por zero
        # ----------------------------------------------------------------------
        if total_concluidos > 0:
            aov_cents = int(round(gmv_cents / total_concluidos))
            aov_kz = round(aov_cents / 100.0, 2)
        else:
            aov_cents = 0
            aov_kz = 0.0

        # ----------------------------------------------------------------------
        # REQUISITO 4: RENTABILIDADE E MARGEM DE CONTRIBUIÇÃO POR PEDIDO (SECÇÃO 10)
        # Deduz do total faturado (subtotal + taxas) as despesas variáveis diretas
        # amortizadas (logística a estafetas, descontos de cupões e custo de gateway 2%).
        # Executado via agregação nativa no PostgreSQL.
        # ----------------------------------------------------------------------
        agregacao_financeira = pedidos_concluidos_qs.aggregate(
            total_subtotal=Coalesce(Sum("subtotal"), Value(0)),
            total_taxa_entrega=Coalesce(Sum("taxa_entrega"), Value(0)),
            total_taxa_servico=Coalesce(Sum("taxa_servico"), Value(0)),
            total_taxa_pequeno_pedido=Coalesce(Sum("taxa_pequeno_pedido"), Value(0)),
            total_gorjetas=Coalesce(Sum("gorjeta_estafeta"), Value(0)),
            total_descontos=Coalesce(Sum("descontos"), Value(0)),
            total_cobrado=Coalesce(Sum("total_cobrado"), Value(0)),
        )

        total_subtotal = int(agregacao_financeira["total_subtotal"])
        total_taxa_entrega = int(agregacao_financeira["total_taxa_entrega"])
        total_taxa_servico = int(agregacao_financeira["total_taxa_servico"])
        total_taxa_pequeno_pedido = int(agregacao_financeira["total_taxa_pequeno_pedido"])
        total_gorjetas = int(agregacao_financeira["total_gorjetas"])
        total_descontos_cupons = int(agregacao_financeira["total_descontos"])
        total_cobrado_faturado = int(agregacao_financeira["total_cobrado"])

        # Despesa Variável A: Payout aos Restaurantes/Parceiros pelos alimentos (Subtotal - Comissão média de 20%)
        # Conforme a Secção 7.1: A plataforma retém 20% de comissão e repassa 80% do subtotal
        despesa_parceiros_comida = int(round(total_subtotal * 0.80))
        comissao_retida_plataforma = total_subtotal - despesa_parceiros_comida

        # Despesa Variável B: Custo de Logística pago a estafetas (Taxa base/distância + 100% gorjetas - Secção 7.1)
        # No modelo canónico: repassa 1100 de cada 1200 de taxa de entrega (ou ~91.67%) + gorjeta
        repasse_entrega_estafetas = int(round(total_taxa_entrega * (110000.0 / 120000.0)))
        custo_logistica_estafetas = repasse_entrega_estafetas + total_gorjetas

        # Despesa Variável C: Descontos de cupões financiados pela plataforma (RN-055)
        custo_descontos_plataforma = total_descontos_cupons

        # Despesa Variável D: Custos de processamento do Gateway (2% sobre total cobrado - Secção 7.1 & 10)
        custo_processamento_gateway_2pct = int(round(total_cobrado_faturado * 0.02))

        # Total de despesas variáveis diretas amortizadas
        total_despesas_variaveis = (
            despesa_parceiros_comida
            + custo_logistica_estafetas
            + custo_descontos_plataforma
            + custo_processamento_gateway_2pct
        )

        # Margem de Contribuição Líquida Total da Plataforma:
        # Faturado Total - Despesas Variáveis Diretas
        margem_contribuicao_total_cents = max(0, total_cobrado_faturado - total_despesas_variaveis)
        margem_contribuicao_total_kz = round(margem_contribuicao_total_cents / 100.0, 2)

        if total_concluidos > 0:
            margem_contribuicao_por_pedido_cents = int(
                round(margem_contribuicao_total_cents / total_concluidos)
            )
            margem_contribuicao_por_pedido_kz = round(
                margem_contribuicao_por_pedido_cents / 100.0, 2
            )
            margem_contribuicao_pct = round(
                (margem_contribuicao_total_cents / total_cobrado_faturado) * 100.0, 2
            ) if total_cobrado_faturado > 0 else 0.0
        else:
            margem_contribuicao_por_pedido_cents = 0
            margem_contribuicao_por_pedido_kz = 0.0
            margem_contribuicao_pct = 0.0

        # ----------------------------------------------------------------------
        # REQUISITO 5: PONTUALIDADE DE SLAS DE ENTREGA (SECÇÃO 8.1)
        # % de pedidos cujo timestamp real de entrega foi <= data_criacao + eta_estimada
        # Meta regulamentar: >= 90.0%
        # ----------------------------------------------------------------------
        pedidos_entregues_qs = base_qs.filter(
            estado__in=[Pedido.EstadoPedido.ENTREGUE, Pedido.EstadoPedido.CONCLUIDO],
            entrega_logistica__isnull=False,
        ).annotate(
            # Avalia se a entrega ocorreu antes ou no prazo exato da ETA estimada
            is_pontual=Case(
                When(
                    Q(entrega_logistica__eta_estimada__isnull=False)
                    & Q(data_atualizacao__lte=F("entrega_logistica__eta_estimada")),
                    then=Value(1),
                ),
                default=Value(0),
                output_field=IntegerField(),
            )
        )

        total_entregues_avaliados = pedidos_entregues_qs.count()
        total_pontuais = pedidos_entregues_qs.filter(is_pontual=1).count()

        if total_entregues_avaliados > 0:
            taxa_pontualidade_sla_pct = round(
                (total_pontuais / total_entregues_avaliados) * 100.0, 2
            )
        else:
            taxa_pontualidade_sla_pct = 100.0

        meta_pontualidade_atingida = taxa_pontualidade_sla_pct >= 90.0

        # ----------------------------------------------------------------------
        # REQUISITO 6: TAXA DE REJEIÇÃO POR PARCEIROS (SECÇÃO 8.1)
        # Relação matemática entre eventos 'order.rejected' e o total de pedidos enviados
        # Meta regulamentar: <= 3.0%
        # ----------------------------------------------------------------------
        eventos_pedidos_periodo = EventoPedido.objects.filter(pedido__in=base_qs)

        total_eventos_rejeitados = eventos_pedidos_periodo.filter(
            tipo_evento=EventoPedido.TipoEvento.ORDER_REJECTED
        ).count()

        # Pedidos enviados ao parceiro para aceitação
        pedidos_enviados_parceiro_count = (
            eventos_pedidos_periodo.filter(
                tipo_evento__in=[
                    EventoPedido.TipoEvento.ORDER_SENT_TO_PARTNER,
                    EventoPedido.TipoEvento.ORDER_ACCEPTED,
                    EventoPedido.TipoEvento.ORDER_REJECTED,
                ]
            )
            .values("pedido_id")
            .distinct()
            .count()
        )

        if pedidos_enviados_parceiro_count == 0:
            pedidos_enviados_parceiro_count = total_pedidos_periodo

        if pedidos_enviados_parceiro_count > 0:
            taxa_rejeicao_parceiros_pct = round(
                (total_eventos_rejeitados / pedidos_enviados_parceiro_count) * 100.0, 2
            )
        else:
            taxa_rejeicao_parceiros_pct = 0.0

        meta_rejeicao_atingida = taxa_rejeicao_parceiros_pct <= 3.0

        # Taxa de Sucesso Operacional de Pedidos Concluídos (Meta Secção 8.1: > 95%)
        taxa_sucesso_pedidos_pct = (
            round((total_concluidos / total_pedidos_periodo) * 100.0, 2)
            if total_pedidos_periodo > 0
            else 0.0
        )

        # ----------------------------------------------------------------------
        # PAYLOAD DE RESPOSTA ESTRUTURADO DE ALTA PERFORMANCE (JSON)
        # ----------------------------------------------------------------------
        payload = {
            "sucesso": True,
            "periodo_analise": {
                "data_inicio": filtros["data_inicio_str"],
                "data_fim": filtros["data_fim_str"],
                "cidade": filtros["cidade"],
                "zona_id": filtros["zona_id"],
                "categoria_loja": filtros["categoria_loja"],
            },
            "funil_volume_pedidos": {
                "total_pedidos_criados": total_pedidos_periodo,
                "pedidos_concluidos": total_concluidos,
                "pedidos_cancelados": pedidos_cancelados_count,
                "pedidos_rejeitados": pedidos_rejeitados_count,
                "taxa_conclusao_sucesso_pct": taxa_sucesso_pedidos_pct,
                "meta_sucesso_seccao_8_1_pct": 95.0,
                "meta_sucesso_atingida": taxa_sucesso_pedidos_pct >= 95.0,
            },
            "kpis_financeiros_seccao_10": {
                "gmv": {
                    "valor_centimos": gmv_cents,
                    "valor_kz": gmv_kz,
                    "descricao": "Gross Merchandise Value - Soma do subtotal de pedidos concluídos",
                },
                "aov": {
                    "valor_centimos": aov_cents,
                    "valor_kz": aov_kz,
                    "descricao": "Average Order Value - Valor médio faturado por pedido concluído",
                },
                "rentabilidade_e_contribuicao": {
                    "faturamento_bruto_cobrado_cents": total_cobrado_faturado,
                    "faturamento_bruto_cobrado_kz": round(total_cobrado_faturado / 100.0, 2),
                    "despesas_variaveis_diretas": {
                        "pago_parceiros_comida_cents": despesa_parceiros_comida,
                        "pago_parceiros_comida_kz": round(despesa_parceiros_comida / 100.0, 2),
                        "custo_logistica_estafetas_cents": custo_logistica_estafetas,
                        "custo_logistica_estafetas_kz": round(custo_logistica_estafetas / 100.0, 2),
                        "descontos_cupons_plataforma_cents": custo_descontos_plataforma,
                        "descontos_cupons_plataforma_kz": round(custo_descontos_plataforma / 100.0, 2),
                        "custo_processamento_gateway_2pct_cents": custo_processamento_gateway_2pct,
                        "custo_processamento_gateway_2pct_kz": round(
                            custo_processamento_gateway_2pct / 100.0, 2
                        ),
                        "total_despesas_amortizadas_cents": total_despesas_variaveis,
                    },
                    "margem_contribuicao_total_cents": margem_contribuicao_total_cents,
                    "margem_contribuicao_total_kz": margem_contribuicao_total_kz,
                    "margem_contribuicao_por_pedido_cents": margem_contribuicao_por_pedido_cents,
                    "margem_contribuicao_por_pedido_kz": margem_contribuicao_por_pedido_kz,
                    "margem_contribuicao_percentagem": margem_contribuicao_pct,
                },
            },
            "metas_operacionais_seccao_8_1": {
                "pontualidade_sla_entrega": {
                    "pedidos_entregues_avaliados": total_entregues_avaliados,
                    "pedidos_dentro_do_prazo": total_pontuais,
                    "taxa_pontualidade_pct": taxa_pontualidade_sla_pct,
                    "meta_regulamentar_minima_pct": 90.0,
                    "meta_atingida": meta_pontualidade_atingida,
                    "status": "CONFORME" if meta_pontualidade_atingida else "ABAIXO_DA_META",
                },
                "taxa_rejeicao_parceiros": {
                    "pedidos_enviados_a_lojas": pedidos_enviados_parceiro_count,
                    "eventos_rejeitados": total_eventos_rejeitados,
                    "taxa_rejeicao_pct": taxa_rejeicao_parceiros_pct,
                    "meta_regulamentar_maxima_pct": 3.0,
                    "meta_atingida": meta_rejeicao_atingida,
                    "status": "CONFORME" if meta_rejeicao_atingida else "ALERTA_OPERACIONAL",
                },
            },
            "timestamp_geracao": timezone.now().isoformat(),
        }

        return Response(payload, status=status.HTTP_200_OK)

    @action(detail=False, methods=["get"], url_path="metrics")
    def metrics(self, request: Request) -> Response:
        """Alias para o endpoint canónico 'kpis'."""
        return self.kpis(request)

    # ==========================================================================
    # MÉTODOS AUXILIARES DE PARSING E SEGMENTAÇÃO SQL
    # ==========================================================================

    def _validar_e_extrair_filtros(self, request: Request) -> dict[str, Any]:
        """
        Valida a obrigatoriedade dos parâmetros 'data_inicio' e 'data_fim',
        e monta a query de filtros espaciais e categóricos para segmentação SQL indexada.
        """
        raw_inicio = request.query_params.get("data_inicio")
        raw_fim = request.query_params.get("data_fim")

        if not raw_inicio:
            raise DRFValidationError(
                {"data_inicio": "O parâmetro 'data_inicio' é obrigatório (formato YYYY-MM-DD ou ISO)."}
            )
        if not raw_fim:
            raise DRFValidationError(
                {"data_fim": "O parâmetro 'data_fim' é obrigatório (formato YYYY-MM-DD ou ISO)."}
            )

        dt_inicio = self._fazer_parse_datetime(raw_inicio, is_fim=False)
        dt_fim = self._fazer_parse_datetime(raw_fim, is_fim=True)

        if dt_inicio > dt_fim:
            raise DRFValidationError(
                {"data_inicio": "A 'data_inicio' não pode ser superior à 'data_fim'."}
            )

        cidade = request.query_params.get("cidade", "").strip()
        zona_id = request.query_params.get("zona_id", "").strip()
        categoria_loja = request.query_params.get("categoria_loja", "").strip()

        # Constrói expressão Q indexada no PostgreSQL
        q_pedidos = Q(data_criacao__gte=dt_inicio, data_criacao__lte=dt_fim)

        # Filtro geográfico por Cidade
        if cidade:
            q_pedidos &= (
                Q(loja__morada_texto__icontains=cidade)
                | Q(cliente__moradas__cidade__icontains=cidade)
            )

        # Filtro por Zona Operacional ou Bairro
        if zona_id:
            try:
                zona_uuid = uuid.UUID(zona_id)
                q_pedidos &= Q(loja__id=zona_uuid)
            except ValueError:
                q_pedidos &= (
                    Q(loja__morada_texto__icontains=zona_id)
                    | Q(cliente__moradas__bairro__icontains=zona_id)
                )

        # Filtro por Categoria Comercial da Loja
        if categoria_loja:
            q_pedidos &= (
                Q(loja__categorias__nome__icontains=categoria_loja)
                | Q(loja__nome__icontains=categoria_loja)
            )

        return {
            "dt_inicio": dt_inicio,
            "dt_fim": dt_fim,
            "data_inicio_str": dt_inicio.isoformat(),
            "data_fim_str": dt_fim.isoformat(),
            "cidade": cidade or None,
            "zona_id": zona_id or None,
            "categoria_loja": categoria_loja or None,
            "q_pedidos": q_pedidos,
        }

    def _fazer_parse_datetime(self, valor_str: str, is_fim: bool = False) -> datetime:
        """Converte strings de datas YYYY-MM-DD ou ISO para datetime com timezone-awareness."""
        dt = parse_datetime(valor_str)
        if dt is None:
            d = parse_date(valor_str)
            if d is None:
                raise DRFValidationError(
                    f"Formato de data inválido: '{valor_str}'. Utilize 'YYYY-MM-DD' ou ISO 8601."
                )
            t = time.max if is_fim else time.min
            dt = datetime.combine(d, t)

        if timezone.is_naive(dt):
            dt = timezone.make_aware(dt, timezone.get_current_timezone())

        return dt


# Alias de compatibilidade retroativa
OperationalDashboardViewSet = OperationalMetricsDashboardViewSet
