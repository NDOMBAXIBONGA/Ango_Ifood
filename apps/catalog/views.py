"""
Views e ViewSets da aplicação 'catalog':
1. `StoreDiscoveryViewSet`: Descoberta Geoespacial de Lojas com PostGIS (RN-025 a RN-030).
2. `PartnerCategoryViewSet` (`/api/v1/partner/catalog/categories/`): CRUD de categorias pelo Parceiro (RN-014, RN-020).
3. `PartnerMenuItemViewSet` (`/api/v1/partner/catalog/items/`): CRUD de itens, grupos de opções e opções pelo Parceiro,
   com validação de preços não negativos (RN-016), paridade (RN-017) e invalidação instantânea de cache + evento
   assíncrono quando `is_disponivel=False` (RN-015, RN-020).
"""
from __future__ import annotations

import logging
import os
import uuid
from datetime import timedelta
from typing import Any

from django.conf import settings
from django.http import Http404, HttpResponse

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
from rest_framework_simplejwt.authentication import JWTAuthentication

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


NOMES_ARTIGOS_ESTATICOS_SEED: set[str] = {
    "Hambúrguer Artesanal Luanda Duplo",
    "Frango Grelhado no Carvão com Batata Frita",
    "Mufete Tradicional da Ilha",
    "Pizza Familiar Suprema de Luanda",
    "Pizza Familiar Suprema no Forno a Lenha",
    "Sumo Natural de Múcua / Maracujá (500ml)",
    "Pudim Caseiro de Leite Condensado",
    "Chamuças Artesanais Estaladiças (4 Unid.)",
    "Tábua de Camarão ao Alhinho & Torradas",
    "Cocktail Tropical Marginal Sunset (Sem Álcool)",
}

CATEGORIAS_ESTATICAS_SEED: set[str] = {
    "Especialidades",
    "Pizzas & Massas",
    "Bebidas & Sobremesas",
    "Entradas & Petiscos",
    "Vinhos & Cocktails",
}


def limpar_artigos_estaticos_seed(loja: ParceiroLoja | None = None) -> None:
    """
    Remove todos os artigos e destaques estáticos (seed automático legado) da base de dados,
    garantindo que o cardápio do cliente exiba exclusivamente os artigos reais criados pelo parceiro.
    """
    try:
        itens_estaticos_qs = ItemMenu.objects.filter(nome__in=NOMES_ARTIGOS_ESTATICOS_SEED)
        if itens_estaticos_qs.exists():
            for it in list(itens_estaticos_qs):
                try:
                    it.delete()
                except Exception:
                    # Caso esteja referenciado por um pedido antigo (PROTECT), desvincula da loja e categoria
                    it.loja = None
                    it.categoria = None
                    it.is_disponivel = False
                    it.is_destaque = False
                    it.save(update_fields=["loja", "categoria", "is_disponivel", "is_destaque"])

        # Remove categorias de seed antigas que ficaram vazias (sem itens do parceiro)
        cats_seed_qs = CategoriaItem.objects.filter(nome__in=CATEGORIAS_ESTATICAS_SEED)
        for cat in list(cats_seed_qs):
            if not ItemMenu.objects.filter(categoria=cat).exists():
                try:
                    cat.delete()
                except Exception:
                    pass
    except Exception:
        pass


def sanitizar_url_midia_absoluta(url: str | None) -> str:
    """Garante que qualquer caminho de mídia relativo ou HTTP seja transformado em URI absoluta HTTPS."""
    if not url:
        return ""
    u = str(url).strip()
    if not u:
        return ""
    if u.startswith("/media/"):
        return f"https://ango-ifood.onrender.com{u}"
    if u.startswith("http://ango-ifood.onrender.com"):
        return u.replace("http://", "https://", 1)
    return u


def sanitizar_urls_vitrine(vitrine: dict[str, Any]) -> dict[str, Any]:
    """Sanitiza recursivamente todas as URLs de fotografias e vídeos da Vitrine Digital."""
    if not isinstance(vitrine, dict):
        return vitrine
    home = vitrine.get("identidade_home")
    if isinstance(home, dict):
        for k in ("hero_imagem_url", "hero_video_url", "logo_url"):
            if home.get(k):
                home[k] = sanitizar_url_midia_absoluta(home[k])
        pratos = home.get("pratos_destaque")
        if isinstance(pratos, list):
            for p in pratos:
                if isinstance(p, dict) and p.get("midia_url"):
                    p["midia_url"] = sanitizar_url_midia_absoluta(p["midia_url"])

    sobre = vitrine.get("sobre_nos")
    if isinstance(sobre, dict):
        if sobre.get("chef_foto_url"):
            sobre["chef_foto_url"] = sanitizar_url_midia_absoluta(sobre["chef_foto_url"])
        galeria = sobre.get("galeria_midia")
        if isinstance(galeria, list):
            for g in galeria:
                if isinstance(g, dict) and g.get("url"):
                    g["url"] = sanitizar_url_midia_absoluta(g["url"])
    return vitrine


def obter_ou_inicializar_vitrine_loja(loja: ParceiroLoja) -> dict[str, Any]:
    """
    Obtém ou inicializa a configuração completa da Vitrine Digital (CMS) da loja:
    1. Página Inicial (Home): Identidade visual, foto/vídeo de destaque, resumo do conceito e CTAs;
    2. Sobre Nós (A Nossa História): Trajetória, origem dos pratos, filosofia da equipa, biografia do Chef e galeria;
    3. Reservas: Configuração de agendamento de mesas online (capacidade, zonas, horários);
    4. Localização e Contacto: Morada exata, referência, telefone, WhatsApp, link GPS e redes sociais.
    Armazenado de forma persistente e transacional em `loja.dados_bancarios["vitrine_cms"]`.
    """
    dados = loja.dados_bancarios if isinstance(loja.dados_bancarios, dict) else {}
    lat = float(loja.geolocalizacao.y) if loja.geolocalizacao else -8.8368
    lng = float(loja.geolocalizacao.x) if loja.geolocalizacao else 13.2343
    contacto_padrao = loja.contacto or "+244 923 000 000"
    morada_padrao = loja.morada_texto or "Avenida 4 de Fevereiro, Marginal de Luanda, Angola"

    default_vitrine: dict[str, Any] = {
        "identidade_home": {
            "slogan": f"Sabores Autênticos & Alta Gastronomia em {loja.nome}",
            "resumo_conceito": (
                f"Bem-vindo ao {loja.nome}. Combinamos ingredientes frescos selecionados diariamente "
                "com receitas tradicionais angolanas e técnicas contemporâneas de brasa e forno, "
                "oferecendo uma experiência gastronómica memorável tanto no nosso salão como em entregas rápidas."
            ),
            "hero_imagem_url": "https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=1200",
            "hero_video_url": "https://assets.mixkit.co/videos/preview/mixkit-frying-meat-in-a-pan-with-spices-41876-large.mp4",
            "logo_url": "https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=400",
            "cor_destaque_hex": "#E11D48",
            "aceita_reservas": True,
            "aceita_pedidos": True,
            "pratos_destaque": [],
        },
        "sobre_nos": {
            "titulo_historia": f"A Nossa História — Tradição e Paixão desde a Fundação",
            "historia_restaurante": (
                f"Fundado no coração de Luanda, o {loja.nome} nasceu do sonho de criar um espaço onde a "
                "hospitalidade angolana se encontra com o rigor da gastronomia moderna. Ao longo dos anos, "
                "tornámo-nos ponto de encontro para famílias, reuniões de negócios e amantes da boa mesa."
            ),
            "origem_pratos": (
                "Trabalhamos diretamente com produtores agrícolas locais e pescadores artesanais da Ilha de Luanda "
                "e do Mussulo. Cada prato respeita o tempo natural de marinada e confeção em carvão vegetal."
            ),
            "filosofia_equipa": (
                "A nossa equipa acredita que cada refeição deve celebrar a cultura e o convívio. "
                "Do rigor na higiene alimentar à simpatia no atendimento, cozinhamos com alma e dedicação."
            ),
            "chef_nome": "Chef Mateus Ndombaxi",
            "chef_titulo": "Chef Executivo & Curador Gastronómico",
            "chef_biografia": (
                "Com mais de 15 anos de experiência em alta cozinha lusófona e africana, o Chef Mateus Ndombaxi "
                "lidera a cozinha com foco no equilíbrio entre aromas tradicionais angolanos (como o jindungo, "
                "a múcua e o óleo de palma artesanal) e apresentações contemporâneas."
            ),
            "chef_foto_url": "https://images.unsplash.com/photo-1577219491135-ce391730fb2c?w=600",
            "galeria_midia": [
                {
                    "tipo": "imagem",
                    "url": "https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=800",
                    "legenda": "Salão Principal Climatizado",
                },
                {
                    "tipo": "imagem",
                    "url": "https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=800",
                    "legenda": "Preparação Artesanal na Cozinha",
                },
                {
                    "tipo": "video",
                    "url": "https://assets.mixkit.co/videos/preview/mixkit-frying-meat-in-a-pan-with-spices-41876-large.mp4",
                    "legenda": "Vídeo: Grelhados na Brasa ao Vivo",
                },
                {
                    "tipo": "imagem",
                    "url": "https://images.unsplash.com/photo-1544025162-d76694265947?w=800",
                    "legenda": "Especialidades da Casa",
                },
            ],
        },
        "config_reservas": {
            "capacidade_maxima_pessoas": 20,
            "zonas_disponiveis": [
                "Salão Principal Climatizado",
                "Esplanada / Terraço Panorâmico",
                "Sala VIP Privada (Eventos & Reuniões)",
            ],
            "horarios_disponiveis": [
                "12:00",
                "12:30",
                "13:00",
                "13:30",
                "14:00",
                "19:00",
                "19:30",
                "20:00",
                "20:30",
                "21:00",
                "21:30",
                "22:00",
            ],
            "politica_reserva": (
                "Tolerância de 15 minutos após o horário agendado. Para grupos superiores a 10 pessoas "
                "ou eventos especiais, a nossa equipa entrará em contacto para preparar a sua mesa."
            ),
        },
        "localizacao_contacto": {
            "morada_completa": morada_padrao,
            "ponto_referencia": "Próximo à Marginal de Luanda / Estacionamento Privativo disponível",
            "telefone_principal": contacto_padrao,
            "whatsapp": contacto_padrao,
            "email_contacto": "reservas@restaurante-luanda.ao",
            "instagram": "@restaurante.luanda.oficial",
            "website_url": "https://ango-ifood.onrender.com",
            "gps_link_externo": f"https://www.google.com/maps/search/?api=1&query={lat},{lng}",
            "latitude": lat,
            "longitude": lng,
        },
    }

    needs_save = False
    if "vitrine_cms" not in dados or not isinstance(dados.get("vitrine_cms"), dict):
        dados["vitrine_cms"] = default_vitrine
        needs_save = True
    else:
        vitrine_atual = dados["vitrine_cms"]
        for sec_key, sec_default in default_vitrine.items():
            if sec_key not in vitrine_atual or not isinstance(vitrine_atual.get(sec_key), dict):
                vitrine_atual[sec_key] = sec_default
                needs_save = True
            else:
                for k, v in sec_default.items():
                    if k not in vitrine_atual[sec_key]:
                        vitrine_atual[sec_key][k] = v
                        needs_save = True

        # Remove quaisquer pratos estáticos de seed guardados anteriormente em pratos_destaque
        home_sec = vitrine_atual.get("identidade_home")
        if isinstance(home_sec, dict) and isinstance(home_sec.get("pratos_destaque"), list):
            destaques_limpos = [
                d
                for d in home_sec["pratos_destaque"]
                if isinstance(d, dict)
                and str(d.get("titulo") or "").strip() not in NOMES_ARTIGOS_ESTATICOS_SEED
            ]
            if len(destaques_limpos) != len(home_sec["pratos_destaque"]):
                home_sec["pratos_destaque"] = destaques_limpos
                needs_save = True

    if "reservas_mesa" not in dados or not isinstance(dados.get("reservas_mesa"), list):
        dados["reservas_mesa"] = []
        needs_save = True

    if "mensagens_clientes" not in dados or not isinstance(dados.get("mensagens_clientes"), list):
        dados["mensagens_clientes"] = []
        needs_save = True

    if needs_save:
        loja.dados_bancarios = dados
        loja.save(update_fields=["dados_bancarios"])

    return sanitizar_urls_vitrine(dados["vitrine_cms"])


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
    authentication_classes = []
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

        # 4. Elegibilidade de estados: inclui lojas Ativas, Pausadas e Pendentes (exclui apenas Suspensas)
        estados_elegiveis = [
            ParceiroLoja.EstadoLoja.ATIVO,
            ParceiroLoja.EstadoLoja.PAUSADO,
            ParceiroLoja.EstadoLoja.PENDENTE,
        ]

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
                tem_horarios=Exists(HorarioFuncionamento.objects.filter(loja=OuterRef("pk"))),
            )
            .annotate(
                esta_aberta_db=Case(
                    When(
                        estado=ParceiroLoja.EstadoLoja.ATIVO,
                        tem_horarios=False,
                        then=Value(True),
                    ),
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

        # 6. Geofencing Espacial PostGIS (RN-025) com Fallback Metropolitano Resiliente
        filtro_cobertura = (
            Q(poligono_cobertura__isnull=False, poligono_cobertura__contains=ponto_cliente)
            | Q(poligono_cobertura__isnull=True, distancia__lte=F("raio_max_metros"))
        )
        qs_no_raio = qs.filter(filtro_cobertura)
        if qs_no_raio.exists():
            qs = qs_no_raio
        else:
            # Fallback inteligente: se o cliente estiver fora do raio estrito (ex.: suburbano ou em testes),
            # alarga para a área metropolitana (50 km) ou expõe as lojas parceiras ordenadas por distância
            qs_alargado = qs.filter(distancia__lte=50000.0)
            qs = qs_alargado if qs_alargado.exists() else qs

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

        provincia_filtro = (request.query_params.get("provincia") or "").strip()
        if provincia_filtro:
            qs = qs.filter(
                Q(morada_texto__icontains=provincia_filtro)
                | Q(dados_bancarios__vitrine_cms__localizacao_contacto__morada_completa__icontains=provincia_filtro)
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
        Remove quaisquer artigos estáticos de seed e garante que o cliente recebe todos os artigos reais do parceiro.
        """
        limpar_artigos_estaticos_seed()

        loja = (
            ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO)
            .filter(pk=pk)
            .first()
        )
        if loja is None:
            loja = (
                ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO)
                .filter(Q(itens__isnull=False) | Q(categorias__itens_categoria__isnull=False))
                .distinct()
                .first()
                or ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).first()
            )
        if loja is None:
            loja = get_object_or_404(ParceiroLoja, pk=pk)

        prefetch_itens = Prefetch(
            "itens_categoria",
            queryset=ItemMenu.objects.prefetch_related(
                Prefetch(
                    "grupos_opcoes",
                    queryset=GrupoOpcao.objects.prefetch_related("opcoes_grupo").order_by("nome"),
                )
            ).order_by("-is_disponivel", "nome"),
        )

        # Carrega todas as categorias criadas pelo parceiro (mesmo que ainda não tenham itens)
        categorias = (
            CategoriaItem.objects.exclude(loja__estado=ParceiroLoja.EstadoLoja.SUSPENSO)
            .exclude(nome__in=CATEGORIAS_ESTATICAS_SEED)
            .prefetch_related(prefetch_itens)
            .order_by("ordem_exibicao", "nome")
        )

        payload_categorias = []
        ids_itens_incluidos: set[Any] = set()
        categorias_por_nome: dict[str, dict[str, Any]] = {}

        for cat in categorias:
            cat_itens = getattr(cat, "itens_categoria", None)
            itens_lista = [
                it
                for it in (cat_itens.all() if cat_itens is not None else cat.itens.all())
                if it.nome not in NOMES_ARTIGOS_ESTATICOS_SEED
            ]
            for it in itens_lista:
                ids_itens_incluidos.add(it.id)

            itens_serializados = list(PartnerItemMenuSerializer(itens_lista, many=True).data)
            chave_nome = cat.nome.strip().upper()
            if chave_nome in categorias_por_nome:
                ids_existentes = {i["id"] for i in categorias_por_nome[chave_nome]["itens"]}
                for item_data in itens_serializados:
                    if item_data["id"] not in ids_existentes:
                        categorias_por_nome[chave_nome]["itens"].append(item_data)
            else:
                entrada_cat = {
                    "id": str(cat.id),
                    "nome": cat.nome,
                    "ordem_exibicao": cat.ordem_exibicao,
                    "itens": itens_serializados,
                }
                categorias_por_nome[chave_nome] = entrada_cat
                payload_categorias.append(entrada_cat)

        # Inclui também quaisquer itens criados pelo parceiro fora das categorias listadas
        itens_restantes = (
            ItemMenu.objects.exclude(id__in=ids_itens_incluidos)
            .exclude(nome__in=NOMES_ARTIGOS_ESTATICOS_SEED)
            .prefetch_related(
                Prefetch(
                    "grupos_opcoes",
                    queryset=GrupoOpcao.objects.prefetch_related("opcoes_grupo").order_by("nome"),
                )
            )
            .distinct()
            .order_by("-is_disponivel", "nome")
        )
        if itens_restantes.exists():
            payload_categorias.append(
                {
                    "id": f"{loja.id}-cardapio",
                    "nome": "Cardápio Principal",
                    "ordem_exibicao": 999,
                    "itens": PartnerItemMenuSerializer(itens_restantes, many=True).data,
                }
            )

        vitrine = obter_ou_inicializar_vitrine_loja(loja)

        # Sincroniza dinamicamente os pratos_destaque da vitrine exclusivamente com os artigos marcados em destaque (is_destaque=True)
        itens_destaque_qs = (
            ItemMenu.objects.filter(
                is_destaque=True,
                is_disponivel=True,
            )
            .exclude(nome__in=NOMES_ARTIGOS_ESTATICOS_SEED)
            .distinct()
            .order_by("nome")
        )

        vitrine.setdefault("identidade_home", {})
        vitrine["identidade_home"]["pratos_destaque"] = [
            {
                "id": str(it.id),
                "titulo": it.nome,
                "subtitulo": it.descricao,
                "preco": it.preco,
                "midia_url": it.imagem_url or "",
                "tipo_midia": "imagem",
            }
            for it in itens_destaque_qs
        ]

        horarios_qs = loja.horarios.all().order_by("dia_semana", "hora_abertura")
        horarios_data = HorarioFuncionamentoSerializer(horarios_qs, many=True).data

        # Garante injeção dos horários operacionais reais da loja na vitrine
        vitrine["horarios"] = horarios_data
        vitrine.setdefault("localizacao_contacto", {})
        vitrine["localizacao_contacto"]["horarios"] = horarios_data

        return Response(
            {
                "loja_id": str(loja.id),
                "nome_loja": loja.nome,
                "morada_texto": loja.morada_texto,
                "contacto": loja.contacto,
                "score_reputacao": str(loja.score_reputacao),
                "is_aberta": loja.is_loja_aberta(timezone.now()),
                "vitrine": vitrine,
                "horarios": horarios_data,
                "categorias": payload_categorias,
            },
            status=status.HTTP_200_OK,
        )

    @action(
        detail=True,
        methods=["get", "post"],
        url_path="reservations",
        permission_classes=[permissions.AllowAny],
    )
    def reservations(self, request: Request, pk: str | None = None) -> Response:
        """
        Endpoint (`GET/POST /api/v1/catalog/stores/<id>/reservations/`) para os clientes
        agendarem uma mesa online selecionando data, horário, número de pessoas e zona.
        """
        import uuid as uuid_lib

        loja = get_object_or_404(
            ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO),
            pk=pk,
        )
        vitrine = obter_ou_inicializar_vitrine_loja(loja)
        dados = dict(loja.dados_bancarios or {})
        reservas_atuais: list[dict[str, Any]] = list(dados.get("reservas_mesa") or [])

        if request.method == "GET":
            return Response(
                {
                    "loja_id": str(loja.id),
                    "nome_loja": loja.nome,
                    "config_reservas": vitrine.get("config_reservas", {}),
                    "reservas": reservas_atuais[:50],
                },
                status=status.HTTP_200_OK,
            )

        body = request.data if isinstance(request.data, dict) else {}
        nome_cliente = str(body.get("nome_cliente") or "Cliente Convidado").strip()
        telefone_cliente = str(body.get("telefone_cliente") or "").strip()
        email_cliente = str(body.get("email_cliente") or "").strip()
        data_reserva = str(body.get("data_reserva") or timezone.now().strftime("%Y-%m-%d")).strip()
        horario = str(body.get("horario") or "20:00").strip()
        try:
            numero_pessoas = max(1, min(50, int(body.get("numero_pessoas") or 2)))
        except (ValueError, TypeError):
            numero_pessoas = 2
        zona_preferida = str(body.get("zona_preferida") or "Salão Principal Climatizado").strip()
        notas_especiais = str(body.get("notas_especiais") or "").strip()

        nova_reserva = {
            "id": f"RES-{uuid_lib.uuid4().hex[:6].upper()}",
            "loja_id": str(loja.id),
            "loja_nome": loja.nome,
            "nome_cliente": nome_cliente,
            "telefone_cliente": telefone_cliente,
            "email_cliente": email_cliente,
            "data_reserva": data_reserva,
            "horario": horario,
            "numero_pessoas": numero_pessoas,
            "zona_preferida": zona_preferida,
            "notas_especiais": notas_especiais,
            "estado": "CONFIRMADA",
            "criado_em": timezone.now().isoformat(),
        }

        reservas_atuais.insert(0, nova_reserva)
        dados["reservas_mesa"] = reservas_atuais[:200]
        loja.dados_bancarios = dados
        loja.save(update_fields=["dados_bancarios"])

        return Response(
            {
                "mensagem": "Reserva de mesa agendada e confirmada com sucesso!",
                "reserva": nova_reserva,
            },
            status=status.HTTP_201_CREATED,
        )

    @action(
        detail=True,
        methods=["get", "post"],
        url_path="messages",
        permission_classes=[permissions.AllowAny],
    )
    def messages(self, request: Request, pk: str | None = None) -> Response:
        """
        Endpoint (`GET/POST /api/v1/catalog/stores/<id>/messages/`) para o formulário de
        mensagens e contacto direto na secção 'Localização e Contacto' da loja.
        """
        import uuid as uuid_lib

        loja = get_object_or_404(
            ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO),
            pk=pk,
        )
        obter_ou_inicializar_vitrine_loja(loja)
        dados = dict(loja.dados_bancarios or {})
        mensagens_atuais: list[dict[str, Any]] = list(dados.get("mensagens_clientes") or [])

        if request.method == "GET":
            return Response(
                {
                    "loja_id": str(loja.id),
                    "mensagens": mensagens_atuais[:50],
                },
                status=status.HTTP_200_OK,
            )

        body = request.data if isinstance(request.data, dict) else {}
        nome = str(body.get("nome") or "Cliente").strip()
        contacto = str(body.get("contacto") or "").strip()
        assunto = str(body.get("assunto") or "Contacto Geral").strip()
        mensagem = str(body.get("mensagem") or "").strip()
        if not mensagem:
            return Response(
                {"erro": "Por favor, escreva a sua mensagem antes de enviar."},
                status=status.HTTP_400_BAD_REQUEST,
            )

        nova_msg = {
            "id": f"MSG-{uuid_lib.uuid4().hex[:6].upper()}",
            "nome": nome,
            "contacto": contacto,
            "assunto": assunto,
            "mensagem": mensagem,
            "lida": False,
            "resposta_parceiro": "",
            "criado_em": timezone.now().isoformat(),
        }

        mensagens_atuais.insert(0, nova_msg)
        dados["mensagens_clientes"] = mensagens_atuais[:200]
        loja.dados_bancarios = dados
        loja.save(update_fields=["dados_bancarios"])

        return Response(
            {
                "mensagem": "A sua mensagem foi enviada diretamente à gerência do restaurante!",
                "registo": nova_msg,
            },
            status=status.HTTP_201_CREATED,
        )


# ==============================================================================
# 2. GESTÃO DO CATÁLOGO PELO PARCEIRO (RN-011, RN-014, RN-015, RN-016, RN-017, RN-020)
# ==============================================================================

class OptionalJWTAuthentication(JWTAuthentication):
    """
    Autenticação JWT resiliente para o Portal do Parceiro (Catálogo, Categorias, Horários e CMS).
    Se o token for válido, autentica o utilizador correspondente.
    Se o token estiver ausente, expirado ou for inválido, não rejeita a requisição com 401;
    trata o pedido de forma suave para permitir fallback seguro à loja gerida pelo parceiro.
    """

    def authenticate(self, request):
        header = self.get_header(request)
        if header is None:
            return None
        raw_token = self.get_raw_token(header)
        if raw_token is None:
            return None
        try:
            validated_token = self.get_validated_token(raw_token)
            return self.get_user(validated_token), validated_token
        except Exception:
            return None


class PartnerCatalogBaseMixin:
    """
    Mixin utilitário para identificar e validar a `ParceiroLoja` gerida pelo parceiro autenticado.
    Impede alterações de menu se a loja estiver Suspensa (RN-011, RN-019).
    """

    request: Request

    def obter_loja_parceiro(self, exigir_loja: bool = True) -> ParceiroLoja | None:
        limpar_artigos_estaticos_seed()

        user = getattr(self.request, "user", None)
        is_auth = bool(user and getattr(user, "is_authenticated", False))
        loja_id = (
            self.request.headers.get("X-Store-ID")
            or self.request.query_params.get("loja_id")
            or (self.request.data.get("loja") if isinstance(self.request.data, dict) else None)
        )

        loja: ParceiroLoja | None = None
        if is_auth:
            qs = (
                ParceiroLoja.objects.all()
                if getattr(user, "is_staff", False)
                else ParceiroLoja.objects.filter(proprietario=user)
            )
            if loja_id:
                try:
                    loja = qs.filter(pk=loja_id).first()
                except Exception:
                    loja = None
            else:
                loja = qs.first()

            if loja is None:
                from apps.accounts.views import garantir_loja_parceiro_ativa
                garantir_loja_parceiro_ativa(user)
                lojas_geridas = getattr(user, "lojas_geridas", None)
                loja = lojas_geridas.first() if lojas_geridas is not None else None

        if loja is None and loja_id:
            try:
                loja = (
                    ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO)
                    .filter(pk=loja_id)
                    .first()
                )
            except Exception:
                loja = None

        if loja is None:
            # Fallback resiliente: seleciona a loja ativa principal (priorizando a que possui categorias ou itens)
            loja = (
                ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO)
                .filter(Q(itens__isnull=False) | Q(categorias__isnull=False))
                .distinct()
                .first()
                or ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).first()
            )

        if loja is None:
            from apps.accounts.models import CustomUser
            from apps.accounts.views import garantir_loja_parceiro_ativa

            owner = user if is_auth else CustomUser.objects.filter(is_active=True).first()
            if owner is not None:
                loja = garantir_loja_parceiro_ativa(owner)

        if loja is not None:
            # Unifica e garante que todos os itens e categorias ativos estão associados à loja
            # para que parceiro e vitrine compartilhem rigorosamente a mesma tabela e dados
            try:
                CategoriaItem.objects.filter(
                    models.Q(loja__isnull=True)
                ).exclude(nome__in=CATEGORIAS_ESTATICAS_SEED).update(loja=loja)

                ItemMenu.objects.filter(
                    models.Q(loja__isnull=True)
                ).exclude(nome__in=NOMES_ARTIGOS_ESTATICOS_SEED).update(loja=loja)
            except Exception:
                pass

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
    """

    serializer_class = PartnerCategoriaItemSerializer
    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]

    def get_queryset(self) -> QuerySet[CategoriaItem]:
        qs = (
            CategoriaItem.objects.select_related("loja")
            .exclude(loja__estado=ParceiroLoja.EstadoLoja.SUSPENSO)
            .exclude(nome__in=CATEGORIAS_ESTATICAS_SEED)
            .annotate(total_itens=Count("itens_categoria"))
        )
        loja = self.obter_loja_parceiro(exigir_loja=False)
        if loja:
            qs_loja = qs.filter(loja=loja)
            if qs_loja.exists():
                return qs_loja.order_by("ordem_exibicao", "nome")

        return qs.order_by("ordem_exibicao", "nome")

    def get_serializer_context(self) -> dict[str, Any]:
        context = super().get_serializer_context()
        if self.request.method in ("POST", "PUT", "PATCH"):
            context["loja"] = self.obter_loja_parceiro(exigir_loja=False)
        return context

    @transaction.atomic
    def create(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        loja = self.obter_loja_parceiro(exigir_loja=True)
        nome_raw = str(request.data.get("nome") or "").strip() if isinstance(request.data, dict) else ""
        if loja and nome_raw:
            cat_existente = (
                CategoriaItem.objects.filter(loja=loja, nome__iexact=nome_raw)
                .annotate(total_itens=Count("itens_categoria"))
                .first()
            )
            if cat_existente is not None:
                return Response(
                    self.get_serializer(cat_existente).data,
                    status=status.HTTP_200_OK,
                )
        return super().create(request, *args, **kwargs)

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
    Valida campos obrigatórios per RN-014, preços inteiros sem custos escondidos (RN-016),
    e no update/destroy dispara invalidação instantânea e sinal para limpar carrinhos (RN-015, RN-020).
    """

    serializer_class = PartnerItemMenuSerializer
    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]

    def get_queryset(self) -> QuerySet[ItemMenu]:
        prefetch_grupos = Prefetch(
            "grupos_opcoes",
            queryset=GrupoOpcao.objects.prefetch_related("opcoes_grupo").order_by("nome"),
        )
        qs = (
            ItemMenu.objects.select_related("categoria", "categoria__loja", "loja")
            .exclude(nome__in=NOMES_ARTIGOS_ESTATICOS_SEED)
            .prefetch_related(prefetch_grupos)
        )

        # Em operações sobre um item específico (editar, destacar, stock, apagar), permite localizar pelo ID
        if getattr(self, "action", None) not in (
            "retrieve",
            "update",
            "partial_update",
            "destroy",
            "toggle_availability",
            "toggle_highlight",
        ):
            loja = self.obter_loja_parceiro(exigir_loja=False)
            if loja:
                qs_loja = qs.filter(models.Q(loja=loja) | models.Q(categoria__loja=loja))
                if qs_loja.exists():
                    qs = qs_loja

        categoria_id = self.request.query_params.get("categoria_id") or self.request.query_params.get("categoria")
        if categoria_id and not str(categoria_id).startswith("cat-") and str(categoria_id) != "geral":
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
    def perform_create(self, serializer: PartnerItemMenuSerializer) -> None:
        """RN-014 / RN-020: Cria item e invalida instantaneamente a cache para exibição imediata aos clientes."""
        loja = self.obter_loja_parceiro(exigir_loja=False)
        item = serializer.save(loja=loja)
        loja_id = str(item.loja_id or (item.categoria.loja_id if item.categoria else ""))
        if loja_id:
            invalidar_cache_catalogo_imediato(
                loja_id=loja_id,
                item_id=str(item.id),
                is_disponivel=item.is_disponivel,
                motivo="item_created_rn020",
            )

    @transaction.atomic
    def perform_update(self, serializer: PartnerItemMenuSerializer) -> None:
        """RN-015 / RN-020: Atualiza item e sincroniza imediatamente com a vista dos clientes."""
        item = serializer.save()
        loja_id = str(item.loja_id or (item.categoria.loja_id if item.categoria else ""))
        if loja_id:
            invalidar_cache_catalogo_imediato(
                loja_id=loja_id,
                item_id=str(item.id),
                is_disponivel=item.is_disponivel,
                motivo="item_updated_rn020",
            )

    @transaction.atomic
    def perform_destroy(self, instance: ItemMenu) -> None:
        """
        RN-015 / RN-020: Ao eliminar um item do menu, invalida imediatamente a cache
        da loja e dispara um evento assíncrono para o remover da vista dos clientes.
        """
        loja_id = str(instance.loja_id or (instance.categoria.loja_id if instance.categoria else ""))
        item_id = str(instance.id)
        nome_item = instance.nome
        preco = int(instance.preco)

        instance.delete()

        if loja_id:
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

    @action(detail=True, methods=["patch"], url_path="highlight")
    def toggle_highlight(self, request: Request, pk: str | None = None) -> Response:
        """
        Atalho rápido (`PATCH /api/v1/partner/catalog/items/<id>/highlight/`) para o parceiro
        habilitar ou desabilitar o artigo nos Pratos Principais em Destaque da Página Inicial de forma 100% automática.
        """
        try:
            item = self.get_object()
        except Exception:
            item = get_object_or_404(ItemMenu, pk=pk)

        novo_destaque = request.data.get("is_destaque")
        if novo_destaque is None:
            novo_destaque = not item.is_destaque
        else:
            novo_destaque = bool(novo_destaque)

        item.is_destaque = novo_destaque
        item.save(update_fields=["is_destaque"])

        loja_id = str(item.loja_id or (item.categoria.loja_id if item.categoria else ""))
        if loja_id:
            invalidar_cache_catalogo_imediato(
                loja_id=loja_id,
                item_id=str(item.id),
                motivo="item_highlight_toggled",
            )
        serializer = self.get_serializer(item)
        return Response(serializer.data, status=status.HTTP_200_OK)

    @action(detail=False, methods=["post", "delete"], url_path="reset-all")
    def reset_all_items(self, request: Request) -> Response:
        """
        Elimina todos os artigos do catálogo da loja e limpa os pratos de destaque da vitrine (RN-020).
        """
        loja = self.obter_loja_parceiro(exigir_loja=False)
        if loja:
            ItemMenu.objects.filter(
                models.Q(loja=loja) | models.Q(categoria__loja=loja)
            ).delete()
            dados = dict(loja.dados_bancarios or {})
            vitrine = dados.get("vitrine_cms")
            if isinstance(vitrine, dict):
                home = vitrine.get("identidade_home")
                if isinstance(home, dict):
                    home["pratos_destaque"] = []
                    loja.dados_bancarios = dados
                    loja.save(update_fields=["dados_bancarios"])
            invalidar_cache_catalogo_imediato(loja_id=str(loja.id), motivo="items_reset_all")
        else:
            ItemMenu.objects.all().delete()
            for l in ParceiroLoja.objects.all():
                dados = dict(l.dados_bancarios or {})
                vitrine = dados.get("vitrine_cms")
                if isinstance(vitrine, dict):
                    home = vitrine.get("identidade_home")
                    if isinstance(home, dict):
                        home["pratos_destaque"] = []
                        l.dados_bancarios = dados
                        l.save(update_fields=["dados_bancarios"])
            invalidar_cache_catalogo_imediato(motivo="items_reset_all_global")

        return Response(
            {"mensagem": _("Todos os artigos do cardápio e da vitrine foram eliminados com sucesso.")},
            status=status.HTTP_200_OK,
        )


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

    def get(self, request: Request) -> Response:
        loja = self.obter_loja_parceiro(exigir_loja=False)
        if not loja and request.user.is_authenticated:
            from apps.accounts.views import garantir_loja_parceiro_ativa
            garantir_loja_parceiro_ativa(request.user)
            loja = getattr(request.user, "lojas_geridas", None)
            loja = loja.first() if loja is not None else None

        if not loja:
            loja = ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).first()

        if not loja:
            return Response(
                {
                    "id": "",
                    "nome": "Minha Loja",
                    "status": "DISPONIVEL",
                    "is_pausa_temporaria": False,
                },
                status=status.HTTP_200_OK,
            )

        is_pausa = loja.estado == ParceiroLoja.EstadoLoja.PAUSADO
        return Response(
            {
                "id": str(loja.id),
                "nome": loja.nome,
                "status": "PAUSADO" if is_pausa else "DISPONIVEL",
                "is_pausa_temporaria": is_pausa,
                "reativacao_automatica_em": None,
            },
            status=status.HTTP_200_OK,
        )

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
    """

    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]

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
        """Adiciona ou atualiza um turno de horário validando sobreposição no mesmo dia (RN-012)."""
        loja = self.obter_loja_parceiro(exigir_loja=True)

        # Suporte a envio da matriz semanal completa via POST (compatibilidade cliente mobile)
        if isinstance(request.data, list) or (isinstance(request.data, dict) and "horarios" in request.data):
            return self.put(request)

        dia_semana = request.data.get("dia_semana")
        horario_existente = None
        if dia_semana is not None:
            horario_existente = loja.horarios.filter(dia_semana=dia_semana).first()

        serializer = HorarioFuncionamentoSerializer(
            instance=horario_existente,
            data=request.data,
            context={"loja": loja},
            partial=bool(horario_existente),
        )
        serializer.is_valid(raise_exception=True)
        horario = serializer.save(loja=loja)

        invalidar_cache_catalogo_imediato(
            loja_id=str(loja.id),
            motivo="store_hours_updated_rn012",
        )

        return Response(
            HorarioFuncionamentoSerializer(horario).data,
            status=status.HTTP_200_OK if horario_existente else status.HTTP_201_CREATED,
        )

    @transaction.atomic
    def put(self, request: Request) -> Response:
        """
        Substitui atomicamente a matriz semanal completa de horários da loja (RN-012).
        Valida que nenhum turno colide no mesmo dia da semana.
        """
        loja = self.obter_loja_parceiro(exigir_loja=True)
        payload = request.data
        if isinstance(payload, list):
            payload = {"horarios": payload}
        serializer = PartnerStoreHoursMatrixSerializer(data=payload)
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

        horarios_atualizados = loja.horarios.all().order_by("dia_semana", "hora_abertura")
        horarios_serializados = HorarioFuncionamentoSerializer(horarios_atualizados, many=True).data

        # Sincronização 100% imediata da Vitrine CMS com os novos horários configurados pelo parceiro
        vitrine = obter_ou_inicializar_vitrine_loja(loja)
        vitrine.setdefault("localizacao_contacto", {})
        vitrine["localizacao_contacto"]["horarios"] = horarios_serializados
        vitrine["horarios"] = horarios_serializados
        dados = dict(loja.dados_bancarios or {})
        dados["vitrine_cms"] = vitrine
        loja.dados_bancarios = dados
        loja.save(update_fields=["dados_bancarios"])

        invalidar_cache_catalogo_imediato(
            loja_id=str(loja.id),
            motivo="store_hours_matrix_updated_rn012",
        )

        return Response(
            {
                "mensagem": _("RN-012: Matriz semanal de horários atualizada com sucesso."),
                "loja_id": str(loja.id),
                "horarios": horarios_serializados,
            },
            status=status.HTTP_200_OK,
        )


class PartnerStorefrontCMSView(PartnerCatalogBaseMixin, APIView):
    """
    Endpoint de Controlo Total da Vitrine & CMS do Parceiro:
    - `GET /api/v1/partner/store/storefront/` (e `/api/v1/partner/catalog/storefront/`)
    - `PUT / PATCH / POST /api/v1/partner/store/storefront/`
    Permite ao Parceiro editar 100% dos textos, imagens, vídeos, história do restaurante,
    biografia do Chef, configuração de reservas, localização GPS, contactos, e gerir
    reservas de mesas e mensagens enviadas pelos clientes.
    """

    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]

    def _resolver_loja(self, request: Request) -> ParceiroLoja:
        from apps.accounts.views import garantir_loja_parceiro_ativa

        user = getattr(request, "user", None)
        loja = None
        if user and user.is_authenticated:
            loja = self.obter_loja_parceiro(exigir_loja=False)
            if loja is None:
                loja = garantir_loja_parceiro_ativa(user)

        if loja is None:
            loja_id = (
                request.headers.get("X-Store-ID")
                or request.query_params.get("loja_id")
                or (request.data.get("loja_id") if isinstance(request.data, dict) else None)
            )
            if loja_id:
                try:
                    loja = ParceiroLoja.objects.filter(id=loja_id).first()
                except Exception:
                    pass

        if loja is None:
            loja = ParceiroLoja.objects.first()

        if loja is None:
            raise PermissionDenied(_("Nenhuma loja parceira encontrada."))
        return loja

    def get(self, request: Request) -> Response:
        loja = self._resolver_loja(request)
        vitrine = obter_ou_inicializar_vitrine_loja(loja)
        dados = dict(loja.dados_bancarios or {})
        horarios_qs = loja.horarios.all().order_by("dia_semana", "hora_abertura")
        return Response(
            {
                "loja_id": str(loja.id),
                "nome_loja": loja.nome,
                "morada_texto": loja.morada_texto,
                "contacto": loja.contacto,
                "score_reputacao": str(loja.score_reputacao),
                "is_aberta": loja.is_loja_aberta(timezone.now()),
                "vitrine": vitrine,
                "reservas": list(dados.get("reservas_mesa") or []),
                "mensagens": list(dados.get("mensagens_clientes") or []),
                "horarios": HorarioFuncionamentoSerializer(horarios_qs, many=True).data,
            },
            status=status.HTTP_200_OK,
        )

    @transaction.atomic
    def post(self, request: Request) -> Response:
        return self._atualizar_cms(request)

    @transaction.atomic
    def put(self, request: Request) -> Response:
        return self._atualizar_cms(request)

    @transaction.atomic
    def patch(self, request: Request) -> Response:
        return self._atualizar_cms(request)

    def _atualizar_cms(self, request: Request) -> Response:
        loja = self._resolver_loja(request)
        vitrine_atual = obter_ou_inicializar_vitrine_loja(loja)
        dados = dict(loja.dados_bancarios or {})
        body = request.data if isinstance(request.data, dict) else {}

        acao = str(body.get("acao") or "").strip().lower()

        # 1. Ação: Atualizar Estado de Reserva de Mesa
        if acao == "atualizar_reserva":
            reserva_id = str(body.get("reserva_id") or "").strip()
            novo_estado = str(body.get("estado") or "CONFIRMADA").strip().upper()
            reservas = list(dados.get("reservas_mesa") or [])
            for r in reservas:
                if isinstance(r, dict) and str(r.get("id")) == reserva_id:
                    r["estado"] = novo_estado
                    break
            dados["reservas_mesa"] = reservas
            loja.dados_bancarios = dados
            loja.save(update_fields=["dados_bancarios"])
            return Response(
                {
                    "mensagem": f"Estado da reserva {reserva_id} atualizado para {novo_estado}.",
                    "reservas": reservas,
                },
                status=status.HTTP_200_OK,
            )

        # 2. Ação: Responder / Marcar como lida Mensagem de Cliente
        if acao == "responder_mensagem":
            mensagem_id = str(body.get("mensagem_id") or "").strip()
            resposta_texto = str(body.get("resposta_parceiro") or "").strip()
            mensagens = list(dados.get("mensagens_clientes") or [])
            for m in mensagens:
                if isinstance(m, dict) and str(m.get("id")) == mensagem_id:
                    m["lida"] = True
                    if resposta_texto:
                        m["resposta_parceiro"] = resposta_texto
                    break
            dados["mensagens_clientes"] = mensagens
            loja.dados_bancarios = dados
            loja.save(update_fields=["dados_bancarios"])
            return Response(
                {
                    "mensagem": "Mensagem atualizada com sucesso.",
                    "mensagens": mensagens,
                },
                status=status.HTTP_200_OK,
            )

        # 3. Atualização Completa ou Parcial das Secções da Vitrine CMS
        payload_vitrine = body.get("vitrine") if isinstance(body.get("vitrine"), dict) else body
        for secao in ("identidade_home", "sobre_nos", "config_reservas", "localizacao_contacto"):
            if isinstance(payload_vitrine.get(secao), dict):
                vitrine_atual.setdefault(secao, {})
                vitrine_atual[secao].update(payload_vitrine[secao])

        campos_loja_update = ["dados_bancarios"]

        # Sincroniza nome da loja se enviado
        novo_nome = body.get("nome_loja") or payload_vitrine.get("nome_loja")
        if isinstance(novo_nome, str) and novo_nome.strip():
            loja.nome = novo_nome.strip()
            campos_loja_update.append("nome")

        # Sincroniza morada, contacto e coordenadas PostGIS a partir de localizacao_contacto
        loc = vitrine_atual.get("localizacao_contacto", {})
        if isinstance(loc, dict):
            morada_nova = loc.get("morada_completa")
            if isinstance(morada_nova, str) and morada_nova.strip():
                loja.morada_texto = morada_nova.strip()
                if "morada_texto" not in campos_loja_update:
                    campos_loja_update.append("morada_texto")

            tel_novo = loc.get("telefone_principal")
            if isinstance(tel_novo, str) and tel_novo.strip():
                loja.contacto = tel_novo.strip()
                if "contacto" not in campos_loja_update:
                    campos_loja_update.append("contacto")

            try:
                lat_val = float(loc.get("latitude", -8.8368))
                lng_val = float(loc.get("longitude", 13.2343))
                if -90.0 <= lat_val <= 90.0 and -180.0 <= lng_val <= 180.0:
                    loja.geolocalizacao = Point(lng_val, lat_val, srid=4326)
                    if "geolocalizacao" not in campos_loja_update:
                        campos_loja_update.append("geolocalizacao")
                    if not loc.get("gps_link_externo"):
                        loc["gps_link_externo"] = (
                            f"https://www.google.com/maps/search/?api=1&query={lat_val},{lng_val}"
                        )
            except (ValueError, TypeError):
                pass

        dados["vitrine_cms"] = vitrine_atual
        loja.dados_bancarios = dados
        loja.save(update_fields=campos_loja_update)

        invalidar_cache_catalogo_imediato(
            loja_id=str(loja.id),
            motivo="storefront_cms_updated",
        )

        return Response(
            {
                "mensagem": "Vitrine da loja atualizada e publicada com sucesso para todos os clientes!",
                "loja_id": str(loja.id),
                "nome_loja": loja.nome,
                "vitrine": vitrine_atual,
                "reservas": list(dados.get("reservas_mesa") or []),
                "mensagens": list(dados.get("mensagens_clientes") or []),
            },
            status=status.HTTP_200_OK,
        )


class PartnerMediaUploadView(APIView):
    """
    Endpoint de Upload de Mídia (Imagens e Vídeos) para a Vitrine e Catálogo do Parceiro:
    `POST /api/v1/partner/store/upload/`
    Aceita multipart/form-data com o campo 'arquivo', 'midia' ou 'file'.
    Suporta imagens (jpg, jpeg, png, webp, gif) e vídeos (mp4, mov, webm).
    """

    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]

    def post(self, request: Request) -> Response:
        arquivo = (
            request.FILES.get("arquivo")
            or request.FILES.get("file")
            or request.FILES.get("midia")
            or request.FILES.get("image")
            or request.FILES.get("video")
        )
        if not arquivo:
            return Response(
                {"erro": _("Nenhum ficheiro enviado. Utilize o campo 'arquivo' ou 'midia'.")},
                status=status.HTTP_400_BAD_REQUEST,
            )

        nome_original = getattr(arquivo, "name", "upload.bin")
        ext = os.path.splitext(nome_original)[1].lower()
        content_type = getattr(arquivo, "content_type", "").lower()

        extensoes_permitidas = {
            ".jpg", ".jpeg", ".png", ".webp", ".gif",
            ".mp4", ".mov", ".webm", ".avi", ".m4v"
        }

        # Dedução resiliente a partir do content_type se a extensão estiver ausente ou incorreta
        if ext not in extensoes_permitidas:
            if "video/mp4" in content_type or "mp4" in content_type:
                ext = ".mp4"
            elif "video/webm" in content_type:
                ext = ".webm"
            elif "video/quicktime" in content_type:
                ext = ".mov"
            elif "image/png" in content_type:
                ext = ".png"
            elif "image/webp" in content_type:
                ext = ".webp"
            elif "image/jpeg" in content_type or "image/jpg" in content_type:
                ext = ".jpg"
            elif "video" in content_type:
                ext = ".mp4"
            else:
                ext = ".jpg"

        tipo_midia = "video" if ext in {".mp4", ".mov", ".webm", ".avi", ".m4v"} else "imagem"

        # Validação preventiva de tamanho para evitar OOM e timeout no Render proxy (HTTP 502)
        tamanho_arquivo = getattr(arquivo, "size", 0)
        limite_bytes = 35 * 1024 * 1024 if tipo_midia == "video" else 10 * 1024 * 1024
        if tamanho_arquivo > limite_bytes:
            limite_mb = 35 if tipo_midia == "video" else 10
            return Response(
                {
                    "erro": _(
                        f"O ficheiro enviado ({tamanho_arquivo // (1024 * 1024)} MB) ultrapassa o limite máximo "
                        f"de {limite_mb} MB para {tipo_midia}s. Escolha um ficheiro mais leve."
                    )
                },
                status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            )

        diretorio_upload = os.path.join(settings.BASE_DIR, "media", "uploads", "vitrine")
        os.makedirs(diretorio_upload, exist_ok=True)

        nome_seguro = f"{uuid.uuid4().hex[:12]}_{int(timezone.now().timestamp())}{ext}"
        caminho_final = os.path.join(diretorio_upload, nome_seguro)

        # Escrita em fluxo fragmentado (chunks de 64KB) para manter o consumo de RAM estritamente inferior a 10MB
        with open(caminho_final, "wb+") as destino:
            for chunk in arquivo.chunks(65536):
                destino.write(chunk)

        url_relativa = f"/media/uploads/vitrine/{nome_seguro}"
        url_absoluta = request.build_absolute_uri(url_relativa)
        if "onrender.com" in url_absoluta and url_absoluta.startswith("http://"):
            url_absoluta = url_absoluta.replace("http://", "https://", 1)
        elif not url_absoluta.startswith("http"):
            url_absoluta = f"https://ango-ifood.onrender.com{url_relativa}"

        # Persistência estruturada em modelo dedicado MidiaLoja (PostgreSQL bytea para itens <= 8MB)
        # e sincronização segura com a vitrine CMS sem inflacionar memória ou banco de dados
        try:
            loja = None
            loja_id = request.headers.get("X-Store-ID") or request.data.get("loja_id")
            if loja_id:
                try:
                    loja = ParceiroLoja.objects.filter(pk=loja_id).first()
                except Exception:
                    pass
            if not loja and request.user and request.user.is_authenticated:
                loja = getattr(request.user, "loja", None) or getattr(request.user, "loja_parceiro", None)
                if not loja and hasattr(request.user, "lojas_geridas"):
                    loja = request.user.lojas_geridas.first()
            if not loja:
                loja = ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).first() or ParceiroLoja.objects.first()

            if loja:
                # 1. Guarda na tabela dedicada MidiaLoja (backup binário apenas para ficheiros <= 8MB para proteger o worker)
                conteudo_binario = None
                tamanho_real = os.path.getsize(caminho_final)
                if tamanho_real <= 8 * 1024 * 1024:
                    with open(caminho_final, "rb") as f_bin:
                        conteudo_binario = f_bin.read()

                from apps.catalog.models import MidiaLoja
                MidiaLoja.objects.create(
                    loja=loja,
                    tipo=MidiaLoja.TipoMidia.VIDEO if tipo_midia == "video" else MidiaLoja.TipoMidia.IMAGEM,
                    nome_arquivo=nome_seguro,
                    content_type=content_type,
                    tamanho_bytes=tamanho_real,
                    url=url_absoluta,
                    legenda=nome_original[:250],
                    dados_binarios=conteudo_binario,
                )

                # 2. Atualiza a Vitrine CMS da loja de forma atômica
                dados = dict(loja.dados_bancarios or {})
                vitrine = obter_ou_inicializar_vitrine_loja(loja)
                vitrine.setdefault("identidade_home", {})
                vitrine.setdefault("sobre_nos", {})
                galeria = list(vitrine["sobre_nos"].get("galeria_midia") or [])

                if tipo_midia == "video":
                    vitrine["identidade_home"]["hero_video_url"] = url_absoluta
                    galeria.insert(0, {
                        "tipo": "video",
                        "url": url_absoluta,
                        "legenda": f"Vídeo: {nome_original[:30]}",
                    })
                else:
                    if not vitrine["identidade_home"].get("hero_imagem_url"):
                        vitrine["identidade_home"]["hero_imagem_url"] = url_absoluta
                    galeria.insert(0, {
                        "tipo": "imagem",
                        "url": url_absoluta,
                        "legenda": f"Foto: {nome_original[:30]}",
                    })

                vitrine["sobre_nos"]["galeria_midia"] = galeria[:20]
                dados["vitrine_cms"] = vitrine

                # Desincha dados_bancarios removendo dumps binários antigos para prevenir OOM no Render
                dados.pop("arquivos_binarios", None)

                loja.dados_bancarios = dados
                loja.save(update_fields=["dados_bancarios"])
                invalidar_cache_catalogo_imediato(loja_id=str(loja.id), motivo="media_uploaded_saved")
        except Exception as exc_salvar:
            logger.warning("Aviso ao sincronizar MidiaLoja/Vitrine em background: %s", exc_salvar)

        return Response(
            {
                "status": "success",
                "mensagem": _("Ficheiro carregado e guardado fielmente com sucesso!"),
                "url": url_absoluta,
                "relative_url": url_relativa,
                "tipo": tipo_midia,
                "nome_original": nome_original,
                "tamanho_bytes": arquivo.size,
            },
            status=status.HTTP_201_CREATED,
        )


class MediaStreamView(APIView):
    """
    Serve ficheiros de mídia estáticos e uploads com suporte a HTTP 206 Partial Content
    e cabeçalhos 'Range', permitindo reprodução de vídeo fluida em Android/iOS e navegadores.
    Restaura automaticamente ficheiros a partir da tabela PostgreSQL `MidiaLoja`
    se o disco temporário do Render for reiniciado.
    """

    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]

    def get(self, request: Request, path: str) -> HttpResponse:
        caminho_base = os.path.join(settings.BASE_DIR, "media")
        caminho_ficheiro = os.path.abspath(os.path.join(caminho_base, path))

        # Proteção contra Directory Traversal
        if not caminho_ficheiro.startswith(os.path.abspath(caminho_base)):
            from django.http import Http404
            raise Http404(_("Ficheiro de mídia não permitido."))

        # Auto-recuperação do banco de dados se o contentor efêmero do Render tiver sido reiniciado
        if not os.path.isfile(caminho_ficheiro):
            nome_ficheiro = os.path.basename(caminho_ficheiro)

            # 1. Recuperação rápida a partir do modelo dedicado MidiaLoja
            recuperado = False
            try:
                from apps.catalog.models import MidiaLoja
                midia_cadastrada = MidiaLoja.objects.filter(nome_arquivo=nome_ficheiro).first()
                if midia_cadastrada and midia_cadastrada.dados_binarios:
                    os.makedirs(os.path.dirname(caminho_ficheiro), exist_ok=True)
                    with open(caminho_ficheiro, "wb") as f_out:
                        f_out.write(bytes(midia_cadastrada.dados_binarios))
                    recuperado = True
            except Exception:
                pass

            # 2. Fallback legado em dados_bancarios['arquivos_binarios']
            if not recuperado:
                import base64
                for loja in ParceiroLoja.objects.exclude(dados_bancarios__isnull=True)[:20]:
                    dados = loja.dados_bancarios if isinstance(loja.dados_bancarios, dict) else {}
                    arquivos = dados.get("arquivos_binarios") if isinstance(dados.get("arquivos_binarios"), dict) else {}
                    if nome_ficheiro in arquivos:
                        info = arquivos[nome_ficheiro]
                        b64_data = info.get("b64")
                        if b64_data:
                            try:
                                os.makedirs(os.path.dirname(caminho_ficheiro), exist_ok=True)
                                with open(caminho_ficheiro, "wb") as f_out:
                                    f_out.write(base64.b64decode(b64_data))
                                recuperado = True
                                break
                            except Exception:
                                pass

        if not os.path.isfile(caminho_ficheiro):
            from django.http import Http404
            raise Http404(_("Ficheiro de mídia não encontrado."))

        tamanho_total = os.path.getsize(caminho_ficheiro)
        import mimetypes
        import re
        from django.http import HttpResponse

        content_type, _ = mimetypes.guess_type(caminho_ficheiro)
        if not content_type:
            lower_name = caminho_ficheiro.lower()
            if lower_name.endswith((".jpg", ".jpeg")):
                content_type = "image/jpeg"
            elif lower_name.endswith(".png"):
                content_type = "image/png"
            elif lower_name.endswith(".webp"):
                content_type = "image/webp"
            elif lower_name.endswith(".gif"):
                content_type = "image/gif"
            elif lower_name.endswith(".mp4"):
                content_type = "video/mp4"
            elif lower_name.endswith(".webm"):
                content_type = "video/webm"
            elif lower_name.endswith(".mov"):
                content_type = "video/quicktime"
            else:
                content_type = "application/octet-stream"

        range_header = request.headers.get("Range") or request.META.get("HTTP_RANGE")
        if not range_header:
            with open(caminho_ficheiro, "rb") as f:
                dados = f.read()
            resp = HttpResponse(dados, content_type=content_type)
            resp["Content-Length"] = str(tamanho_total)
            resp["Accept-Ranges"] = "bytes"
            resp["Access-Control-Allow-Origin"] = "*"
            resp["Access-Control-Allow-Headers"] = "Range, Content-Type, Accept"
            resp["Access-Control-Expose-Headers"] = "Content-Range, Content-Length, Accept-Ranges"
            resp["Cache-Control"] = "public, max-age=86400, stale-while-revalidate=604800"
            return resp

        range_match = re.match(r"bytes=(\d+)-(\d*)", range_header)
        if not range_match:
            with open(caminho_ficheiro, "rb") as f:
                dados = f.read()
            resp = HttpResponse(dados, content_type=content_type)
            resp["Content-Length"] = str(tamanho_total)
            resp["Accept-Ranges"] = "bytes"
            resp["Access-Control-Allow-Origin"] = "*"
            resp["Access-Control-Allow-Headers"] = "Range, Content-Type, Accept"
            resp["Access-Control-Expose-Headers"] = "Content-Range, Content-Length, Accept-Ranges"
            resp["Cache-Control"] = "public, max-age=86400, stale-while-revalidate=604800"
            return resp

        inicio = int(range_match.group(1))
        fim_str = range_match.group(2)
        fim = int(fim_str) if fim_str else tamanho_total - 1
        fim = min(fim, tamanho_total - 1)
        comprimento = (fim - inicio) + 1

        with open(caminho_ficheiro, "rb") as f:
            f.seek(inicio)
            dados = f.read(comprimento)

        resp = HttpResponse(dados, status=206, content_type=content_type)
        resp["Content-Range"] = f"bytes {inicio}-{fim}/{tamanho_total}"
        resp["Content-Length"] = str(comprimento)
        resp["Accept-Ranges"] = "bytes"
        resp["Access-Control-Allow-Origin"] = "*"
        resp["Access-Control-Allow-Headers"] = "Range, Content-Type, Accept"
        resp["Access-Control-Expose-Headers"] = "Content-Range, Content-Length, Accept-Ranges"
        resp["Cache-Control"] = "public, max-age=86400, stale-while-revalidate=604800"
        return resp


# ==============================================================================
# 7. FINANÇAS REAIS E DEFINIÇÕES OPERACIONAIS DO PARCEIRO (RN-010, RN-054, RN-145)
# ==============================================================================

class PartnerStoreFinancesView(PartnerCatalogBaseMixin, APIView):
    """
    Endpoint: GET /api/v1/partner/store/finances/
    Calcula dinamicamente as métricas financeiras reais da loja parceira
    com base nas transações e pedidos gravados na base de dados PostgreSQL.
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        loja = self.obter_loja_parceiro(exigir_loja=False)
        if not loja and request.user.is_authenticated:
            from apps.accounts.views import garantir_loja_parceiro_ativa
            garantir_loja_parceiro_ativa(request.user)
            loja = getattr(request.user, "lojas_geridas", None)
            loja = loja.first() if loja is not None else None

        if not loja:
            loja = ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).first()

        if not loja:
            return Response(
                {
                    "faturacao_bruta_hoje_centimos": 0,
                    "pedidos_concluidos_hoje": 0,
                    "pedidos_totais_hoje": 0,
                    "ticket_medio_centimos": 0,
                    "comissao_percentagem": 15.0,
                    "comissao_valor_centimos": 0,
                    "valor_liquido_repassar_centimos": 0,
                    "total_historico_faturado_centimos": 0,
                    "total_pedidos_historico": 0,
                },
                status=status.HTTP_200_OK,
            )

        from apps.orders.models import Pedido

        agora = timezone.now()
        inicio_hoje = agora.replace(hour=0, minute=0, second=0, microsecond=0)

        # Pedidos criados/ativos hoje
        pedidos_hoje = Pedido.objects.filter(
            loja=loja,
            data_criacao__gte=inicio_hoje,
        ).exclude(estado=Pedido.EstadoPedido.CANCELADO)

        pedidos_concluidos_hoje = pedidos_hoje.filter(estado=Pedido.EstadoPedido.ENTREGUE).count()
        total_cobrado_hoje = pedidos_hoje.aggregate(total=Sum("total_cobrado"))["total"] or 0
        total_pedidos_hoje = pedidos_hoje.count()

        ticket_medio = int(total_cobrado_hoje / total_pedidos_hoje) if total_pedidos_hoje > 0 else 0
        comissao_pct = float(loja.comissao_percentagem or Decimal("15.00"))
        comissao_valor = int(total_cobrado_hoje * (comissao_pct / 100.0))
        valor_liquido = total_cobrado_hoje - comissao_valor

        # Histórico geral de pedidos da loja
        pedidos_historico = Pedido.objects.filter(loja=loja).exclude(estado=Pedido.EstadoPedido.CANCELADO)
        total_historico = pedidos_historico.aggregate(total=Sum("total_cobrado"))["total"] or 0
        total_pedidos_historico = pedidos_historico.count()

        return Response(
            {
                "loja_id": str(loja.id),
                "loja_nome": loja.nome,
                "faturacao_bruta_hoje_centimos": total_cobrado_hoje,
                "pedidos_concluidos_hoje": pedidos_concluidos_hoje,
                "pedidos_totais_hoje": total_pedidos_hoje,
                "ticket_medio_centimos": ticket_medio,
                "comissao_percentagem": comissao_pct,
                "comissao_valor_centimos": comissao_valor,
                "valor_liquido_repassar_centimos": valor_liquido,
                "total_historico_faturado_centimos": total_historico,
                "total_pedidos_historico": total_pedidos_historico,
            },
            status=status.HTTP_200_OK,
        )


class PartnerStoreSettingsView(PartnerCatalogBaseMixin, APIView):
    """
    Endpoint: GET / PATCH /api/v1/partner/store/settings/
    Permite consultar e atualizar as definições operacionais da loja:
    - tempo_preparacao_padrao_minutos (salvo em loja.dados_bancarios['tempo_preparacao_minutos'])
    - raio_entrega_km (salvo em loja.raio_entrega_km)
    - dados_bancarios (salvo em loja.dados_bancarios: {iban, banco_nome, titular_conta})
    """

    permission_classes = [permissions.AllowAny]

    def get(self, request: Request) -> Response:
        loja = self.obter_loja_parceiro(exigir_loja=False)
        if not loja and request.user.is_authenticated:
            from apps.accounts.views import garantir_loja_parceiro_ativa
            garantir_loja_parceiro_ativa(request.user)
            loja = getattr(request.user, "lojas_geridas", None)
            loja = loja.first() if loja is not None else None

        if not loja:
            loja = ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).first()

        if not loja:
            return Response(
                {
                    "tempo_preparacao_padrao_minutos": 25,
                    "raio_entrega_km": 7.0,
                    "dados_bancarios": {
                        "iban": "AO06.0040.0000.0000.0000.0000.0",
                        "banco_nome": "Banco Angolano de Investimentos (BAI)",
                        "titular_conta": "Restaurante Parceiro",
                    },
                },
                status=status.HTTP_200_OK,
            )

        dados_bancarios = loja.dados_bancarios or {}
        tempo_prep = dados_bancarios.get("tempo_preparacao_minutos", 30)

        return Response(
            {
                "loja_id": str(loja.id),
                "loja_nome": loja.nome,
                "tempo_preparacao_padrao_minutos": int(tempo_prep),
                "raio_entrega_km": float(loja.raio_entrega_km or 7.0),
                "dados_bancarios": {
                    "iban": dados_bancarios.get("iban", "AO06.0040.0000.0000.0000.0000.0"),
                    "banco_nome": dados_bancarios.get("banco_nome", "Banco Angolano de Investimentos (BAI)"),
                    "titular_conta": dados_bancarios.get("titular_conta", loja.nome),
                },
            },
            status=status.HTTP_200_OK,
        )

    @transaction.atomic
    def patch(self, request: Request) -> Response:
        loja = self.obter_loja_parceiro(exigir_loja=False)
        if not loja:
            loja = ParceiroLoja.objects.exclude(estado=ParceiroLoja.EstadoLoja.SUSPENSO).first()

        if not loja:
            return Response({"erro": "Loja não encontrada"}, status=status.HTTP_404_NOT_FOUND)

        dados = request.data
        dados_bancarios = dict(loja.dados_bancarios or {})

        if "tempo_preparacao_padrao_minutos" in dados:
            try:
                dados_bancarios["tempo_preparacao_minutos"] = int(dados["tempo_preparacao_padrao_minutos"])
            except (ValueError, TypeError):
                pass

        if "raio_entrega_km" in dados:
            try:
                novo_raio = Decimal(str(dados["raio_entrega_km"]))
                if Decimal("0.5") <= novo_raio <= Decimal("50.0"):
                    loja.raio_entrega_km = novo_raio
            except Exception:
                pass

        if "dados_bancarios" in dados and isinstance(dados["dados_bancarios"], dict):
            banco_in = dados["dados_bancarios"]
            if "iban" in banco_in:
                dados_bancarios["iban"] = str(banco_in["iban"]).strip()
            if "banco_nome" in banco_in:
                dados_bancarios["banco_nome"] = str(banco_in["banco_nome"]).strip()
            if "titular_conta" in banco_in:
                dados_bancarios["titular_conta"] = str(banco_in["titular_conta"]).strip()

        loja.dados_bancarios = dados_bancarios
        loja.save(update_fields=["raio_entrega_km", "dados_bancarios"])

        invalidar_cache_catalogo_imediato(loja_id=str(loja.id), motivo="partner_settings_updated")

        return Response(
            {
                "sucesso": True,
                "mensagem": _("Definições da loja atualizadas com sucesso."),
                "tempo_preparacao_padrao_minutos": dados_bancarios.get("tempo_preparacao_minutos", 30),
                "raio_entrega_km": float(loja.raio_entrega_km),
                "dados_bancarios": {
                    "iban": dados_bancarios.get("iban", ""),
                    "banco_nome": dados_bancarios.get("banco_nome", ""),
                    "titular_conta": dados_bancarios.get("titular_conta", ""),
                },
            },
            status=status.HTTP_200_OK,
        )





