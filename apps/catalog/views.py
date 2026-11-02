"""
Views e ViewSets da aplicação 'catalog':
1. `StoreDiscoveryViewSet`: Descoberta Geoespacial de Lojas com PostGIS (RN-025 a RN-030).
2. `PartnerCategoryViewSet` (`/api/v1/partner/catalog/categories/`): CRUD de categorias pelo Parceiro (RN-014, RN-020).
3. `PartnerMenuItemViewSet` (`/api/v1/partner/catalog/items/`): CRUD de itens, grupos de opções e opções pelo Parceiro,
   com validação de preços não negativos (RN-016), paridade (RN-017) e invalidação instantânea de cache + evento
   assíncrono quando `is_disponivel=False` (RN-015, RN-020).
"""
import logging
from datetime import timedelta
from typing import Any

from django.contrib.gis.db.models.functions import Distance
from django.contrib.gis.geos import Point
from django.contrib.gis.measure import D
from django.core.cache import cache
from django.db import transaction
from django.db.models import (
    BooleanField,
    Case,
    Count,
    Exists,
    ExpressionWrapper,
    F,
    FloatField,
    OuterRef,
    Prefetch,
    Q,
    QuerySet,
    Value,
    When,
)
from django.db.models.functions import Cast
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.pagination import PageNumberPagination
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.catalog.models import (
    CategoriaItem,
    GrupoOpcao,
    HorarioFuncionamento,
    ItemMenu,
    ParceiroLoja,
)
from apps.catalog.permissions import IsActivePartner
from apps.catalog.serializers import (
    DiscoveryQueryParamsSerializer,
    HorarioFuncionamentoSerializer,
    PartnerCategoriaItemSerializer,
    PartnerItemMenuSerializer,
    PartnerStoreHoursMatrixSerializer,
    PartnerStorePauseStatusSerializer,
    StoreDiscoverySerializer,
)
from apps.catalog.tasks import (
    invalidar_cache_catalogo_imediato,
    sincronizar_alteracao_item_menu_task,
)


# ==============================================================================
# 1. DESCOBERTA GEOESPACIAL DE LOJAS (StoreDiscoveryViewSet - RN-025 a RN-030)
# ==============================================================================

class StoreDiscoveryPagination(PageNumberPagination):
    """
    Paginação performante para o catálogo de descoberta de lojas.
    Permite ao cliente mobile definir `page_size` até ao limite máximo de 50 lojas por página.
    """

    page_size = 20
    page_size_query_param = "page_size"
    max_page_size = 50


class StoreDiscoveryViewSet(viewsets.ReadOnlyModelViewSet):
    """
    Endpoint de Descoberta e Cobertura Geográfica de Lojas (`GET /api/v1/catalog/stores/`).
    Implementa as regras de negócio RN-025, RN-026, RN-027, RN-028, RN-029 e RN-030.

    Requisitos e Regras Técnicas:
    - RN-025: Geofencing espacial com PostGIS (`Point`, `PolygonField`, `Distance`).
      Filtra lojas cujo `poligono_cobertura` contém o ponto do cliente ou, caso ausente,
      a distância linear seja inferior ou igual ao raio máximo de entrega da loja (`raio_entrega_km`).
    - RN-026: Disponibilidade operacional dinâmica em tempo de execução via subquery SQL anotada.
      Avalia se a loja possui turno aberto no momento atual (`agora`). Se `show_closed=False` (padrão),
      omite estabelecimentos fechados; se `show_closed=True`, inclui-os empurrados para o final.
    - RN-027: Algoritmo de ranking unificado multinível:
      1. Disponibilidade (`-esta_aberta_db`);
      2. Destaque patrocinado (`-is_patrocinado`);
      3. Menor distância física calculada pelo PostGIS (`distancia`);
      4. Maior score de reputação do parceiro (`-score_reputacao`);
      5. Desempate alfabético por nome (`nome`).
    - RN-028: Filtros avançados combináveis:
      * `tipo_cozinha` / `categoria`: Filtragem por especialidade culinária ou categoria;
      * `avaliacao_min` / `score_min`: Reputação mínima do parceiro (0.00 a 5.00);
      * `entrega_gratis`: Lojas com taxa de entrega gratuita;
      * `max_eta`: Tempo estimado de entrega máximo em minutos (RN-029);
      * `q`: Busca textual por nome do restaurante, categoria ou itens do menu.
    - RN-030: Prevenção estrita de N+1 queries com `select_related("proprietario")`
      e `prefetch_related("categorias", "horarios")`.
    """

    serializer_class = StoreDiscoverySerializer
    pagination_class = StoreDiscoveryPagination
    permission_classes = [permissions.AllowAny]
    queryset = ParceiroLoja.objects.none()

    def _construir_subquery_horario_aberto(self, agora: Any) -> Exists:
        """
        RN-026: Subquery SQL de alto desempenho para verificar se existe um turno de funcionamento
        aberto no momento `agora`, incluindo suporte a horários noturnos que cruzam a meia-noite
        e respeito a pausas operacionais temporárias (RN-013).
        """
        agora_local = timezone.localtime(agora) if timezone.is_aware(agora) else agora
        dia_atual = agora_local.weekday()
        dia_anterior = (dia_atual - 1) % 7
        hora_atual = agora_local.time()

        # Turno diurno padrão (ex.: 08:00 às 22:00)
        condicao_turno_diurno = (
            Q(dia_semana=dia_atual)
            & Q(hora_abertura__lte=F("hora_fecho"))
            & Q(hora_abertura__lte=hora_atual)
            & Q(hora_fecho__gte=hora_atual)
        )
        # Turno noturno que começou hoje e fecha amanhã (ex.: 18:00 às 02:00)
        condicao_turno_noturno_hoje = Q(
            dia_semana=dia_atual,
            hora_abertura__gt=F("hora_fecho"),
            hora_abertura__lte=hora_atual,
        )
        # Turno noturno que começou ontem e ainda está ativo nesta madrugada (ex.: até às 02:00)
        condicao_turno_madrugada_ontem = Q(
            dia_semana=dia_anterior,
            hora_abertura__gt=F("hora_fecho"),
            hora_fecho__gte=hora_atual,
        )
        # Sem pausa temporária ativa ou pausa cujo prazo já expirou (RN-013)
        condicao_sem_pausa_ativa = Q(is_pausa_temporaria=False) | Q(
            is_pausa_temporaria=True,
            reativacao_automatica_em__isnull=False,
            reativacao_automatica_em__lte=agora,
        )

        horarios_abertos_qs = (
            HorarioFuncionamento.objects.filter(loja=OuterRef("pk"))
            .filter(
                condicao_turno_diurno
                | condicao_turno_noturno_hoje
                | condicao_turno_madrugada_ontem
            )
            .filter(condicao_sem_pausa_ativa)
        )
        return Exists(horarios_abertos_qs)

    def list(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        Executa a listagem geoespacial otimizada de lojas parceiras com geofencing PostGIS.
        """
        # 1. Validação obrigatória dos parâmetros geoespaciais e filtros
        params_serializer = DiscoveryQueryParamsSerializer(data=request.query_params)
        params_serializer.is_valid(raise_exception=True)
        params = params_serializer.validated_data

        lat: float = params["lat"]
        lng: float = params["lng"]
        show_closed: bool = params.get("show_closed", False)
        termo_pesquisa: str = (params.get("q") or "").strip()
        termo_categoria: str = (params.get("tipo_cozinha") or params.get("categoria") or "").strip()
        avaliacao_min = params.get("avaliacao_min") or params.get("score_min")
        entrega_gratis: bool = params.get("entrega_gratis", False)
        max_eta: int | None = params.get("max_eta")

        # 2. Construção do Ponto Geográfico PostGIS WGS84 (SRID 4326)
        ponto_cliente = Point(float(lng), float(lat), srid=4326)
        agora = timezone.now()

        # 3. Otimização N+1: Prefetch de categorias e horários ordenados
        prefetch_horarios = Prefetch(
            "horarios",
            queryset=HorarioFuncionamento.objects.order_by("dia_semana", "hora_abertura"),
        )
        prefetch_categorias = Prefetch(
            "categorias",
            queryset=CategoriaItem.objects.order_by("ordem_exibicao", "nome"),
        )

        # 4. Elegibilidade de estados: exclui Pendentes e Suspensos (RN-011, RN-019)
        estados_elegiveis = (
            [ParceiroLoja.EstadoLoja.ATIVO, ParceiroLoja.EstadoLoja.PAUSADO]
            if show_closed
            else [ParceiroLoja.EstadoLoja.ATIVO]
        )

        # 5. QuerySet base com Anotação Espacial e Subquery de Disponibilidade
        qs: QuerySet[ParceiroLoja] = (
            ParceiroLoja.objects.filter(estado__in=estados_elegiveis)
            .select_related("proprietario")
            .prefetch_related(prefetch_horarios, prefetch_categorias)
            .annotate(
                distancia=Distance("geolocalizacao", ponto_cliente),
                raio_max_metros=ExpressionWrapper(
                    Cast(F("raio_entrega_km"), FloatField()) * Value(1000.0),
                    output_field=FloatField(),
                ),
                tem_turno_aberto=self._construir_subquery_horario_aberto(agora),
            )
            .annotate(
                esta_aberta_db=Case(
                    When(
                        estado=ParceiroLoja.EstadoLoja.ATIVO,
                        tem_turno_aberto=True,
                        then=Value(True),
                    ),
                    default=Value(False),
                    output_field=BooleanField(),
                ),
            )
        )

        # 6. Geofencing Espacial PostGIS (RN-025):
        # Polígono de cobertura contém o ponto do cliente OU, se ausente, dentro do raio de entrega
        filtro_cobertura = (
            Q(poligono_cobertura__isnull=False, poligono_cobertura__contains=ponto_cliente)
            | Q(poligono_cobertura__isnull=True, distancia__lte=F("raio_max_metros"))
        )
        qs = qs.filter(filtro_cobertura)

        # 7. Disponibilidade Operacional (RN-026)
        if not show_closed:
            qs = qs.filter(esta_aberta_db=True)

        # 8. Filtros adicionais (RN-028)
        if termo_pesquisa:
            qs = qs.filter(
                Q(nome__icontains=termo_pesquisa)
                | Q(categorias__nome__icontains=termo_pesquisa)
                | Q(categorias__itens_categoria__nome__icontains=termo_pesquisa)
                | Q(itens__nome__icontains=termo_pesquisa)
            ).distinct()

        if termo_categoria:
            qs = qs.filter(
                Q(categorias__nome__icontains=termo_categoria)
                | Q(nome__icontains=termo_categoria)
            ).distinct()

        if avaliacao_min is not None:
            qs = qs.filter(score_reputacao__gte=avaliacao_min)

        if entrega_gratis:
            qs = qs.filter(is_entrega_gratis=True)

        if max_eta is not None:
            # RN-029: ETA = 25 min base + 3.5 min/km -> km_max = max(0.5, (max_eta - 25) / 3.5)
            raio_eta_km = max(0.5, (float(max_eta) - 25.0) / 3.5)
            raio_eta_metros = raio_eta_km * 1000.0
            qs = qs.filter(distancia__lte=raio_eta_metros)

        # 9. Algoritmo de Ranking Unificado (RN-027)
        ranking_order = [
            "-esta_aberta_db",
            "-is_patrocinado",
            "distancia",
            "-score_reputacao",
            "nome",
        ]
        qs = qs.order_by(*ranking_order)

        # 10. Paginação e Serialização
        pagina = self.paginate_queryset(qs)
        lojas_pagina: list[ParceiroLoja] = list(pagina if pagina is not None else qs)

        for loja in lojas_pagina:
            aberta_cache = getattr(loja, "esta_aberta_db", None)
            if aberta_cache is not None:
                loja._cached_is_loja_aberta = bool(aberta_cache)  # type: ignore[attr-defined]

        serializer = self.get_serializer(
            lojas_pagina,
            many=True,
            context={
                **self.get_serializer_context(),
                "data_hora_atual": agora,
                "ponto_cliente": ponto_cliente,
            },
        )

        if pagina is not None:
            return self.get_paginated_response(serializer.data)

        return Response(serializer.data, status=status.HTTP_200_OK)

    @action(detail=True, methods=["get"], url_path="menu")
    def menu(self, request: Request, pk: str | None = None) -> Response:
        """
        Endpoint público (`GET /api/v1/catalog/stores/<id>/menu/`) consumido pelo `StoreMenuScreen`
        na aplicação mobile do Cliente para listar as categorias, itens e opções da loja (RN-014, RN-015).
        """
        loja = get_object_or_404(
            ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO),
            pk=pk,
        )
        prefetch_itens = Prefetch(
            "itens",
            queryset=ItemMenu.objects.prefetch_related(
                Prefetch(
                    "grupos_opcoes",
                    queryset=GrupoOpcao.objects.prefetch_related("opcoes").order_by("nome"),
                )
            ).order_by("-is_disponivel", "nome"),
        )
        categorias = (
            CategoriaItem.objects.filter(loja=loja)
            .prefetch_related(prefetch_itens)
            .order_by("ordem_exibicao", "nome")
        )

        payload_categorias = []
        for cat in categorias:
            payload_categorias.append(
                {
                    "id": str(cat.id),
                    "nome": cat.nome,
                    "ordem_exibicao": cat.ordem_exibicao,
                    "itens": PartnerItemMenuSerializer(cat.itens.all(), many=True).data,
                }
            )

        return Response(
            {
                "loja_id": str(loja.id),
                "nome_loja": loja.nome,
                "is_aberta": loja.is_loja_aberta(timezone.now()),
                "categorias": payload_categorias,
            },
            status=status.HTTP_200_OK,
        )


# ==============================================================================
# 2. GESTÃO DO CATÁLOGO PELO PARCEIRO (RN-011, RN-014, RN-015, RN-016, RN-017, RN-020)
# ==============================================================================

class PartnerCatalogBaseMixin:
    """
    Mixin utilitário para identificar e validar a `ParceiroLoja` gerida pelo parceiro autenticado.
    Impede alterações de menu se a loja estiver Suspensa (RN-011, RN-019).
    """

    request: Request

    def obter_loja_parceiro(self, exigir_loja: bool = True) -> ParceiroLoja | None:
        user = self.request.user
        loja_id = (
            self.request.headers.get("X-Store-ID")
            or self.request.query_params.get("loja_id")
            or (self.request.data.get("loja") if isinstance(self.request.data, dict) else None)
        )

        qs = ParceiroLoja.objects.all() if user.is_staff else ParceiroLoja.objects.filter(proprietario=user)

        if loja_id:
            loja = get_object_or_404(qs, pk=loja_id)
        else:
            loja = qs.first()

        if loja is None and exigir_loja:
            raise PermissionDenied(
                _("RN-010 / RN-011: Nenhuma loja parceira encontrada ou associada a este utilizador.")
            )

        if loja is not None and loja.estado == ParceiroLoja.EstadoLoja.SUSPENSO:
            raise PermissionDenied(
                _("RN-019: Esta loja encontra-se suspensa e não pode modificar o catálogo.")
            )

        return loja


class PartnerCategoryViewSet(PartnerCatalogBaseMixin, viewsets.ModelViewSet):
    """
    Endpoint RESTful: `/api/v1/partner/catalog/categories/`
    Permite ao Parceiro listar, criar, atualizar e eliminar categorias do seu menu (RN-014, RN-020).
    Exige autenticação JWT e status de Parceiro 'Ativo' (RN-011).
    """

    serializer_class = PartnerCategoriaItemSerializer
    permission_classes = [IsActivePartner]

    def get_queryset(self) -> QuerySet[CategoriaItem]:
        user = self.request.user
        qs = CategoriaItem.objects.select_related("loja").annotate(
            total_itens=Count("itens")
        )
        if not user.is_staff:
            qs = qs.filter(loja__proprietario=user)

        loja_id = self.request.headers.get("X-Store-ID") or self.request.query_params.get("loja_id")
        if loja_id:
            qs = qs.filter(loja_id=loja_id)

        return qs.order_by("ordem_exibicao", "nome")

    def get_serializer_context(self) -> dict[str, Any]:
        context = super().get_serializer_context()
        if self.request.method in ("POST", "PUT", "PATCH"):
            context["loja"] = self.obter_loja_parceiro(exigir_loja=False)
        return context

    @transaction.atomic
    def perform_create(self, serializer: PartnerCategoriaItemSerializer) -> None:
        loja = self.obter_loja_parceiro(exigir_loja=True)
        categoria = serializer.save(loja=loja)
        invalidar_cache_catalogo_imediato(
            loja_id=str(categoria.loja_id),
            motivo="category_created_rn020",
        )

    @transaction.atomic
    def perform_update(self, serializer: PartnerCategoriaItemSerializer) -> None:
        categoria = serializer.save()
        invalidar_cache_catalogo_imediato(
            loja_id=str(categoria.loja_id),
            motivo="category_updated_rn020",
        )

    @transaction.atomic
    def perform_destroy(self, instance: CategoriaItem) -> None:
        loja_id = str(instance.loja_id)
        instance.delete()
        invalidar_cache_catalogo_imediato(
            loja_id=loja_id,
            motivo="category_deleted_rn020",
        )


class PartnerMenuItemViewSet(PartnerCatalogBaseMixin, viewsets.ModelViewSet):
    """
    Endpoint RESTful: `/api/v1/partner/catalog/items/`
    CRUD completo dos itens do menu vinculados à loja do parceiro autenticado.
    Exige autenticação JWT e status de Parceiro 'Ativo' (RN-011).
    Valida campos obrigatórios per RN-014, preços inteiros sem custos escondidos (RN-016),
    e no update/destroy dispara invalidação instantânea e sinal para limpar carrinhos (RN-015, RN-020).
    """

    serializer_class = PartnerItemMenuSerializer
    permission_classes = [IsActivePartner]

    def get_queryset(self) -> QuerySet[ItemMenu]:
        user = self.request.user
        prefetch_grupos = Prefetch(
            "grupos_opcoes",
            queryset=GrupoOpcao.objects.prefetch_related("opcoes").order_by("nome"),
        )
        qs = ItemMenu.objects.select_related("categoria", "categoria__loja").prefetch_related(
            prefetch_grupos
        )

        if not user.is_staff:
            qs = qs.filter(categoria__loja__proprietario=user)

        loja_id = self.request.headers.get("X-Store-ID") or self.request.query_params.get("loja_id")
        if loja_id:
            qs = qs.filter(categoria__loja_id=loja_id)

        categoria_id = self.request.query_params.get("categoria_id")
        if categoria_id:
            qs = qs.filter(categoria_id=categoria_id)

        is_disponivel = self.request.query_params.get("is_disponivel")
        if is_disponivel is not None:
            qs = qs.filter(is_disponivel=is_disponivel.lower() in ("true", "1", "yes"))

        return qs.order_by("categoria__ordem_exibicao", "nome")

    def get_serializer_context(self) -> dict[str, Any]:
        context = super().get_serializer_context()
        if self.request.method in ("POST", "PUT", "PATCH"):
            context["loja"] = self.obter_loja_parceiro(exigir_loja=False)
        return context

    @transaction.atomic
    def perform_destroy(self, instance: ItemMenu) -> None:
        """
        RN-015 / RN-020: Ao eliminar um item do menu, invalida imediatamente a cache
        da loja e dispara um evento assíncrono para o remover da vista dos clientes.
        """
        loja_id = str(instance.categoria.loja_id)
        item_id = str(instance.id)
        nome_item = instance.nome
        preco = int(instance.preco)

        instance.delete()

        invalidar_cache_catalogo_imediato(
            loja_id=loja_id,
            item_id=item_id,
            is_disponivel=False,
            motivo="item_deleted_rn020",
        )

        def _notificar_remocao() -> None:
            try:
                sincronizar_alteracao_item_menu_task.delay(
                    loja_id=loja_id,
                    item_id=item_id,
                    nome_item=nome_item,
                    is_disponivel=False,
                    preco=preco,
                    motivo="item_deleted_rn020",
                )
            except Exception:
                pass

        transaction.on_commit(_notificar_remocao)

    @action(detail=True, methods=["patch"], url_path="availability")
    def toggle_availability(self, request: Request, pk: str | None = None) -> Response:
        """
        Atalho rápido (`PATCH /api/v1/partner/catalog/items/<id>/availability/`) para o parceiro
        marcar um item como disponível/indisponível com invalidação instantânea (RN-015, RN-020).
        """
        item = self.get_object()
        if "is_disponivel" not in request.data:
            raise ValidationError(
                {"is_disponivel": _("RN-015: O campo booleano 'is_disponivel' é obrigatório.")}
            )

        serializer = self.get_serializer(
            item,
            data={"is_disponivel": request.data["is_disponivel"]},
            partial=True,
        )
        serializer.is_valid(raise_exception=True)
        serializer.save()
        return Response(serializer.data, status=status.HTTP_200_OK)


# ==============================================================================
# 3. OPERAÇÃO INTERNA DO PORTAL DO PARCEIRO (STATUS E HORÁRIOS - RN-012, RN-013)
# ==============================================================================

class PartnerStoreStatusView(PartnerCatalogBaseMixin, APIView):
    """
    Endpoint 1: `PATCH /api/v1/partner/store/status/`
    Permite à loja ativar ou desativar uma pausa temporária no fluxo de pedidos (RN-013).
    Recebe um booleano `is_pausa_temporaria` e um inteiro `duracao_minutos`.
    Calcula o timestamp exato de reativação automática e atualiza o estado da loja
    na cache Redis e na base de dados PostgreSQL.
    Exige autenticação JWT e status de Parceiro 'Ativo' (RN-011).
    """

    permission_classes = [IsActivePartner]

    @transaction.atomic
    def patch(self, request: Request) -> Response:
        loja = self.obter_loja_parceiro(exigir_loja=True)
        serializer = PartnerStorePauseStatusSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        is_pausa: bool = serializer.validated_data["is_pausa_temporaria"]
        duracao_minutos: int = serializer.validated_data.get("duracao_minutos", 30)

        agora = timezone.now()

        if is_pausa:
            reativacao_automatica_em = agora + timedelta(minutes=duracao_minutos)
            loja.estado = ParceiroLoja.EstadoLoja.PAUSADO

            # Atualiza os turnos da loja com o timestamp de reabertura automática (RN-013)
            loja.horarios.all().update(
                is_pausa_temporaria=True,
                reativacao_automatica_em=reativacao_automatica_em,
            )

            # Grava estado na cache Redis com TTL proporcional à duração da pausa
            cache_payload = {
                "loja_id": str(loja.id),
                "estado": loja.estado,
                "is_pausa_temporaria": True,
                "reativacao_automatica_em": reativacao_automatica_em.isoformat(),
                "pausado_em": agora.isoformat(),
            }
            cache.set(
                f"catalog:store:{loja.id}:pause_status",
                cache_payload,
                timeout=duracao_minutos * 60,
            )

            # Invalida cache de descoberta para refletir o status fechado/pausado imediatamente
            invalidar_cache_catalogo_imediato(
                loja_id=str(loja.id),
                motivo="store_paused_rn013",
            )
        else:
            reativacao_automatica_em = None
            loja.estado = ParceiroLoja.EstadoLoja.ATIVO

            # Remove a pausa dos turnos de funcionamento
            loja.horarios.all().update(
                is_pausa_temporaria=False,
                reativacao_automatica_em=None,
            )

            # Remove o status de pausa do Redis e invalida a cache para reabertura
            cache.delete(f"catalog:store:{loja.id}:pause_status")
            invalidar_cache_catalogo_imediato(
                loja_id=str(loja.id),
                motivo="store_unpaused_rn013",
            )

        loja.save(update_fields=["estado"])

        return Response(
            {
                "mensagem": _("RN-013: Estado operacional da loja atualizado com sucesso."),
                "loja_id": str(loja.id),
                "nome": loja.nome,
                "estado": loja.estado,
                "is_pausa_temporaria": is_pausa,
                "reativacao_automatica_em": (
                    reativacao_automatica_em.isoformat()
                    if reativacao_automatica_em
                    else None
                ),
                "duracao_minutos": duracao_minutos if is_pausa else 0,
            },
            status=status.HTTP_200_OK,
        )


class PartnerStoreHoursView(PartnerCatalogBaseMixin, APIView):
    """
    Endpoint 3: `GET/POST/PUT /api/v1/partner/store/hours/`
    Permite consultar e configurar a matriz de horários de funcionamento por dia da semana
    (0 a 6), incluindo horas de abertura, fecho e intervalos de pausas (RN-012).
    Impede a sobreposição de horários para o mesmo dia da semana através de validação estrita.
    Exige autenticação JWT e status de Parceiro 'Ativo' (RN-011).
    """

    permission_classes = [IsActivePartner]

    def get(self, request: Request) -> Response:
        loja = self.obter_loja_parceiro(exigir_loja=True)
        horarios = loja.horarios.all().order_by("dia_semana", "hora_abertura")
        serializer = HorarioFuncionamentoSerializer(horarios, many=True)
        return Response(
            {
                "loja_id": str(loja.id),
                "loja_nome": loja.nome,
                "is_aberta_agora": loja.is_loja_aberta(),
                "total_turnos": horarios.count(),
                "horarios": serializer.data,
            },
            status=status.HTTP_200_OK,
        )

    @transaction.atomic
    def post(self, request: Request) -> Response:
        """Adiciona um novo turno de horário validando sobreposição no mesmo dia (RN-012)."""
        loja = self.obter_loja_parceiro(exigir_loja=True)
        serializer = HorarioFuncionamentoSerializer(
            data=request.data,
            context={"loja": loja},
        )
        serializer.is_valid(raise_exception=True)
        horario = serializer.save(loja=loja)

        invalidar_cache_catalogo_imediato(
            loja_id=str(loja.id),
            motivo="store_hours_added_rn012",
        )

        return Response(
            HorarioFuncionamentoSerializer(horario).data,
            status=status.HTTP_201_CREATED,
        )

    @transaction.atomic
    def put(self, request: Request) -> Response:
        """
        Substitui atomicamente a matriz semanal completa de horários da loja (RN-012).
        Valida que nenhum turno colide no mesmo dia da semana.
        """
        loja = self.obter_loja_parceiro(exigir_loja=True)
        serializer = PartnerStoreHoursMatrixSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        horarios_data = serializer.validated_data["horarios"]

        # Remove horários anteriores e recria a matriz validada
        loja.horarios.all().delete()

        novos_horarios = [
            HorarioFuncionamento(
                loja=loja,
                dia_semana=h["dia_semana"],
                hora_abertura=h["hora_abertura"],
                hora_fecho=h["hora_fecho"],
            )
            for h in horarios_data
        ]
        HorarioFuncionamento.objects.bulk_create(novos_horarios)

        invalidar_cache_catalogo_imediato(
            loja_id=str(loja.id),
            motivo="store_hours_matrix_updated_rn012",
        )

        horarios_atualizados = loja.horarios.all().order_by("dia_semana", "hora_abertura")
        return Response(
            {
                "mensagem": _("RN-012: Matriz semanal de horários atualizada com sucesso."),
                "loja_id": str(loja.id),
                "horarios": HorarioFuncionamentoSerializer(horarios_atualizados, many=True).data,
            },
            status=status.HTTP_200_OK,
        )

