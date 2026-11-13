"""
Serializers da aplicação 'catalog' para:
1. Descoberta Geoespacial de Lojas (Store Discovery - RN-025 a RN-029).
2. Gestão do Catálogo pelo Parceiro (Categorias, Itens, Grupos de Opções e Opções - RN-014 a RN-020).
"""
from decimal import Decimal
from typing import Any

from django.db import transaction
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import serializers

from apps.catalog.models import (
    CategoriaItem,
    GrupoOpcao,
    HorarioFuncionamento,
    ItemMenu,
    OpcaoItem,
    ParceiroLoja,
)
from apps.catalog.tasks import (
    invalidar_cache_catalogo_imediato,
    sincronizar_alteracao_item_menu_task,
)


# ==============================================================================
# 1. SERIALIZERS DE DESCOBERTA GEOESPACIAL (RN-025 a RN-029)
# ==============================================================================

class DiscoveryQueryParamsSerializer(serializers.Serializer):
    """
    Valida os query params enviados para o endpoint `StoreDiscoveryViewSet.list`
    (`GET /api/v1/catalog/stores/?lat=...&lng=...`) cumprindo as regras RN-025 a RN-028.
    """

    lat = serializers.FloatField(
        min_value=-90.0,
        max_value=90.0,
        required=False,
        default=-8.8368,
        help_text=_("RN-025: Latitude da morada do cliente em graus decimais (WGS84 / SRID 4326)."),
    )
    lng = serializers.FloatField(
        min_value=-180.0,
        max_value=180.0,
        required=False,
        default=13.2343,
        help_text=_("RN-025: Longitude da morada do cliente em graus decimais (WGS84 / SRID 4326)."),
    )
    show_closed = serializers.BooleanField(
        default=True,
        required=False,
        help_text=_(
            "RN-026: Se True, inclui lojas fechadas enviando-as para o fim da ordenação. "
            "Se False, omite lojas fechadas."
        ),
    )
    incluir_fechadas = serializers.BooleanField(
        required=False,
        help_text=_("RN-026: Alias retrocompatível para show_closed."),
    )
    q = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=100,
        help_text=_("RN-028: Pesquisa textual por nome da loja, categoria ou item do menu."),
    )
    tipo_cozinha = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=80,
        help_text=_("RN-028: Filtro por tipo de cozinha ou categoria de produtos da loja."),
    )
    categoria = serializers.CharField(
        required=False,
        allow_blank=True,
        max_length=80,
        help_text=_("RN-028: Alias para filtro de categoria/tipo de cozinha."),
    )
    avaliacao_min = serializers.DecimalField(
        max_digits=3,
        decimal_places=2,
        min_value=Decimal("0.00"),
        max_value=Decimal("5.00"),
        required=False,
        help_text=_("RN-028: Filtro por avaliação mínima do parceiro (0.00 a 5.00)."),
    )
    score_min = serializers.DecimalField(
        max_digits=3,
        decimal_places=2,
        min_value=Decimal("0.00"),
        max_value=Decimal("5.00"),
        required=False,
        help_text=_("RN-028: Alias para avaliacao_min."),
    )
    entrega_gratis = serializers.BooleanField(
        default=False,
        required=False,
        help_text=_("RN-028: Filtro por lojas com entrega gratuita ativa."),
    )
    max_eta = serializers.IntegerField(
        min_value=5,
        max_value=180,
        required=False,
        help_text=_("RN-028: Tempo máximo de entrega estimado (ETA) em minutos."),
    )

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        # Harmoniza inclusão de lojas abertas e fechadas
        if "incluir_fechadas" in self.initial_data:
            val = self.initial_data.get("incluir_fechadas")
            if isinstance(val, str):
                attrs["show_closed"] = val.lower() in ("true", "1", "yes")
            else:
                attrs["show_closed"] = bool(val)
        elif "show_closed" in self.initial_data:
            val = self.initial_data.get("show_closed")
            if isinstance(val, str):
                attrs["show_closed"] = val.lower() in ("true", "1", "yes")
            else:
                attrs["show_closed"] = bool(val)
        else:
            attrs["show_closed"] = True

        if "score_min" in attrs and "avaliacao_min" not in attrs:
            attrs["avaliacao_min"] = attrs["score_min"]
        elif attrs.get("avaliacao_min") is None and attrs.get("score_min") is not None:
            attrs["avaliacao_min"] = attrs["score_min"]

        if "categoria" in attrs and "tipo_cozinha" not in attrs:
            attrs["tipo_cozinha"] = attrs["categoria"]
        elif not attrs.get("tipo_cozinha") and attrs.get("categoria"):
            attrs["tipo_cozinha"] = attrs["categoria"]

        return attrs


class StoreDiscoverySerializer(serializers.ModelSerializer):
    """
    Serializer de listagem de lojas para Descoberta e Pesquisa (RN-025 a RN-029).
    Expõe distância calculada pelo PostGIS, ETA estimado, estado de abertura, próximo horário
    e etiqueta transparente de conteúdo patrocinado (RN-027 / RN-062).
    """

    distancia_metros = serializers.SerializerMethodField(
        help_text=_("RN-025 / RN-027: Distância linear em metros calculada pelo PostGIS."),
    )
    distancia_km = serializers.SerializerMethodField(
        help_text=_("RN-025 / RN-027: Distância linear em quilómetros arredondada a 2 casas decimais."),
    )
    is_aberta = serializers.SerializerMethodField(
        help_text=_("RN-012 / RN-026: Indica se a loja está aberta na hora atual do servidor."),
    )
    eta_minutos_estimado = serializers.SerializerMethodField(
        help_text=_("RN-029: Estimativa de tempo de entrega (ETA) em minutos."),
    )
    etiqueta_patrocinado = serializers.SerializerMethodField(
        help_text=_("RN-027 / RN-062: Indicação transparente quando o resultado é patrocinado."),
    )
    proximo_horario_abertura = serializers.SerializerMethodField(
        help_text=_("RN-026: Indicação do horário de abertura quando a loja está fechada."),
    )
    latitude = serializers.SerializerMethodField()
    longitude = serializers.SerializerMethodField()
    imagem_url = serializers.SerializerMethodField()
    tipo_cozinha = serializers.SerializerMethodField()
    taxa_entrega = serializers.SerializerMethodField()

    class Meta:
        model = ParceiroLoja
        fields = (
            "id",
            "nome",
            "morada_texto",
            "contacto",
            "latitude",
            "longitude",
            "imagem_url",
            "tipo_cozinha",
            "taxa_entrega",
            "raio_entrega_km",
            "estado",
            "score_reputacao",
            "is_patrocinado",
            "etiqueta_patrocinado",
            "is_entrega_gratis",
            "is_aberta",
            "proximo_horario_abertura",
            "distancia_metros",
            "distancia_km",
            "eta_minutos_estimado",
        )
        read_only_fields = fields

    def get_imagem_url(self, obj: ParceiroLoja) -> str:
        return (
            getattr(obj, "imagem_url", None)
            or "https://images.unsplash.com/photo-1504674900247-0877df9cc836?w=800"
        )

    def get_tipo_cozinha(self, obj: ParceiroLoja) -> str:
        cat = obj.categorias.first()
        return cat.nome if cat else "Restaurante"

    def get_taxa_entrega(self, obj: ParceiroLoja) -> int:
        if obj.is_entrega_gratis:
            return 0
        return 50000

    def get_latitude(self, obj: ParceiroLoja) -> float | None:
        return round(float(obj.geolocalizacao.y), 6) if obj.geolocalizacao else None

    def get_longitude(self, obj: ParceiroLoja) -> float | None:
        return round(float(obj.geolocalizacao.x), 6) if obj.geolocalizacao else None

    def get_distancia_metros(self, obj: ParceiroLoja) -> int | None:
        distancia = getattr(obj, "distancia", None)
        if distancia is not None and hasattr(distancia, "m"):
            return int(round(distancia.m))
        distancia_m = getattr(obj, "distancia_metros_calc", None)
        if distancia_m is not None:
            return int(round(float(distancia_m)))
        return None

    def get_distancia_km(self, obj: ParceiroLoja) -> float | None:
        metros = self.get_distancia_metros(obj)
        return round(metros / 1000.0, 2) if metros is not None else None

    def get_is_aberta(self, obj: ParceiroLoja) -> bool:
        agora = self.context.get("data_hora_atual") or timezone.now()
        if hasattr(obj, "_cached_is_loja_aberta"):
            return bool(obj._cached_is_loja_aberta)
        return obj.is_loja_aberta(agora)

    def get_eta_minutos_estimado(self, obj: ParceiroLoja) -> int:
        km = self.get_distancia_km(obj) or 1.0
        tempo_preparacao_e_atribuicao = 23
        tempo_deslocacao = int(round(km * 3.5))
        margem_seguranca = 5
        return tempo_preparacao_e_atribuicao + tempo_deslocacao + margem_seguranca

    def get_etiqueta_patrocinado(self, obj: ParceiroLoja) -> str | None:
        return "Patrocinado" if obj.is_patrocinado else None

    def get_proximo_horario_abertura(self, obj: ParceiroLoja) -> str | None:
        if self.get_is_aberta(obj):
            return None
        agora = timezone.localtime(self.context.get("data_hora_atual") or timezone.now())
        dia_atual = agora.weekday()
        horarios: list[HorarioFuncionamento] = list(obj.horarios.all())
        for offset in range(7):
            dia_procura = (dia_atual + offset) % 7
            turnos_dia = [
                h for h in horarios
                if h.dia_semana == dia_procura and not h.is_pausa_temporaria
            ]
            for turno in sorted(turnos_dia, key=lambda x: x.hora_abertura):
                if offset == 0 and turno.hora_abertura <= agora.time():
                    continue
                dia_nome = turno.get_dia_semana_display()
                return f"{dia_nome} às {turno.hora_abertura:%H:%M}"
        return None


# ==============================================================================
# 2. SERIALIZERS DE GESTÃO DE CATÁLOGO PELO PARCEIRO (RN-014, RN-015, RN-016, RN-017, RN-020)
# ==============================================================================

class PartnerOpcaoItemSerializer(serializers.ModelSerializer):
    """
    Serializer para criação/edição de `OpcaoItem` pelo Parceiro (RN-014, RN-015, RN-016).
    Garante que `preco_adicional` nunca seja negativo.
    """

    id = serializers.UUIDField(required=False)
    preco_adicional = serializers.IntegerField(
        min_value=0,
        default=0,
        error_messages={
            "min_value": _("RN-016: O preço adicional da opção nunca pode ser negativo."),
        },
        help_text=_("RN-016 / RN-059: Preço adicional em unidades mínimas inteiras (>= 0)."),
    )

    class Meta:
        model = OpcaoItem
        fields = (
            "id",
            "nome",
            "preco_adicional",
            "is_disponivel",
        )

    def validate_preco_adicional(self, value: int) -> int:
        """RN-016: Validação explícita para garantir que o suplemento nunca é negativo."""
        if value < 0:
            raise serializers.ValidationError(
                _("RN-016: O preço adicional de uma opção nunca pode ser negativo.")
            )
        return value


class PartnerGrupoOpcaoSerializer(serializers.ModelSerializer):
    """
    Serializer para criação/edição de `GrupoOpcao` e respetivas opções aninhadas (`OpcaoItem`)
    pelo Parceiro (RN-014, RN-015, RN-016).
    """

    id = serializers.UUIDField(required=False)
    opcoes = PartnerOpcaoItemSerializer(many=True, required=False, default=list)

    class Meta:
        model = GrupoOpcao
        fields = (
            "id",
            "nome",
            "is_obrigatorio",
            "minimo_escolhas",
            "maximo_escolhas",
            "opcoes",
        )

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        """
        RN-014: Valida regras de obrigatoriedade e limites mínimo/máximo de escolhas.
        """
        is_obrigatorio = attrs.get(
            "is_obrigatorio",
            getattr(self.instance, "is_obrigatorio", False),
        )
        minimo = attrs.get(
            "minimo_escolhas",
            getattr(self.instance, "minimo_escolhas", 0),
        )
        maximo = attrs.get(
            "maximo_escolhas",
            getattr(self.instance, "maximo_escolhas", 1),
        )

        if minimo < 0:
            raise serializers.ValidationError(
                {"minimo_escolhas": _("RN-014: O mínimo de escolhas não pode ser negativo.")}
            )
        if maximo < 1:
            raise serializers.ValidationError(
                {"maximo_escolhas": _("RN-014: O máximo de escolhas tem de ser pelo menos 1.")}
            )
        if is_obrigatorio and minimo < 1:
            attrs["minimo_escolhas"] = 1
            minimo = 1
        if minimo > maximo:
            raise serializers.ValidationError(
                {
                    "minimo_escolhas": _(
                        "RN-014: O número mínimo de escolhas não pode ser superior ao máximo de escolhas."
                    )
                }
            )
        return attrs


class PartnerCategoriaItemSerializer(serializers.ModelSerializer):
    """
    Serializer para o endpoint `/api/v1/partner/catalog/categories/` (RN-014, RN-020).
    """

    total_itens = serializers.IntegerField(read_only=True, default=0)

    class Meta:
        model = CategoriaItem
        fields = (
            "id",
            "loja",
            "nome",
            "ordem_exibicao",
            "total_itens",
        )
        read_only_fields = ("id", "total_itens")
        extra_kwargs = {
            "loja": {"required": False},
        }

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        loja = attrs.get("loja") or getattr(self.instance, "loja", None) or self.context.get("loja")
        if loja is None:
            raise serializers.ValidationError(
                {"loja": _("RN-014: É necessário identificar a loja parceira da categoria.")}
            )
        attrs["loja"] = loja

        nome = (attrs.get("nome") or getattr(self.instance, "nome", "")).strip()
        qs = CategoriaItem.objects.filter(loja=loja, nome__iexact=nome)
        if self.instance is not None:
            qs = qs.exclude(pk=self.instance.pk)
        if qs.exists():
            raise serializers.ValidationError(
                {"nome": _("RN-014: Já existe uma categoria com este nome nesta loja.")}
            )
        attrs["nome"] = nome
        return attrs


class PartnerItemMenuSerializer(serializers.ModelSerializer):
    """
    Serializer completo para o endpoint `/api/v1/partner/catalog/items/`.
    Suporta gestão de `ItemMenu` + `grupos_opcoes` + `opcoes` (RN-014),
    validação estrita de preços não negativos e paridade de preços (RN-016, RN-017)
    e invalidação instantânea de cache + evento assíncrono quando `is_disponivel=False` (RN-015, RN-020).
    """

    preco = serializers.IntegerField(
        min_value=0,
        error_messages={
            "min_value": _("RN-016: O preço do item nunca pode ser negativo."),
        },
        help_text=_(
            "RN-016 / RN-059: Preço final com impostos em unidades mínimas inteiras (nunca negativo)."
        ),
    )
    preco_balcao_referencia = serializers.IntegerField(
        min_value=0,
        required=False,
        write_only=True,
        help_text=_(
            "RN-017: Preço praticado no balcão (opcional) para validar margem máxima de paridade (10%)."
        ),
    )
    grupos_opcoes = PartnerGrupoOpcaoSerializer(many=True, required=False)

    class Meta:
        model = ItemMenu
        fields = (
            "id",
            "categoria",
            "nome",
            "descricao",
            "preco",
            "preco_balcao_referencia",
            "imagem_url",
            "alergenos",
            "is_disponivel",
            "grupos_opcoes",
        )
        read_only_fields = ("id",)

    def validate_preco(self, value: int) -> int:
        """RN-016: Garante que o preço do menu nunca é negativo."""
        if value < 0:
            raise serializers.ValidationError(
                _("RN-016: O preço do item nunca pode ser negativo.")
            )
        return value

    def validate_alergenos(self, value: Any) -> list[str]:
        """RN-014: Garante que alergénios é uma lista de strings."""
        if not isinstance(value, list):
            raise serializers.ValidationError(
                _("RN-014: O campo 'alergenos' deve ser uma lista JSON de strings.")
            )
        return [str(a).strip() for a in value if str(a).strip()]

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        """
        1. Valida que a categoria pertence à loja do parceiro autenticado.
        2. RN-017 (Paridade de preços): Se `preco_balcao_referencia` for informado, garante que
           o preço na app não excede o preço de balcão em mais de 10%.
        """
        categoria: CategoriaItem | None = attrs.get("categoria") or getattr(
            self.instance, "categoria", None
        )
        loja_contexto: ParceiroLoja | None = self.context.get("loja")

        if categoria and loja_contexto and categoria.loja_id != loja_contexto.id:
            raise serializers.ValidationError(
                {
                    "categoria": _(
                        "RN-014: A categoria selecionada não pertence à loja do parceiro autenticado."
                    )
                }
            )

        preco_app = attrs.get("preco", getattr(self.instance, "preco", 0))
        preco_balcao = attrs.pop("preco_balcao_referencia", None)
        if preco_balcao is not None and preco_balcao > 0:
            teto_paridade = int(preco_balcao * 1.10)
            if preco_app > teto_paridade:
                raise serializers.ValidationError(
                    {
                        "preco": _(
                            f"RN-017 (Paridade de Preços): O preço na aplicação ({preco_app}) não pode "
                            f"exceder o preço de balcão ({preco_balcao}) em mais de 10% (máximo permitido: {teto_paridade})."
                        )
                    }
                )

        return attrs

    def _guardar_grupos_e_opcoes(
        self,
        item: ItemMenu,
        grupos_data: list[dict[str, Any]],
    ) -> None:
        """
        RN-014: Sincroniza os `GrupoOpcao` e `OpcaoItem` aninhados de um `ItemMenu`.
        """
        ids_grupos_mantidos: list[Any] = []

        for grupo_dict in grupos_data:
            opcoes_data: list[dict[str, Any]] = grupo_dict.pop("opcoes", [])
            grupo_id = grupo_dict.pop("id", None)

            if grupo_id:
                grupo_obj, _ = GrupoOpcao.objects.update_or_create(
                    id=grupo_id,
                    item=item,
                    defaults=grupo_dict,
                )
            else:
                grupo_obj = GrupoOpcao.objects.create(item=item, **grupo_dict)

            ids_grupos_mantidos.append(grupo_obj.id)

            ids_opcoes_mantidas: list[Any] = []
            for opcao_dict in opcoes_data:
                opcao_id = opcao_dict.pop("id", None)
                if opcao_id:
                    opcao_obj, _ = OpcaoItem.objects.update_or_create(
                        id=opcao_id,
                        grupo=grupo_obj,
                        defaults=opcao_dict,
                    )
                else:
                    opcao_obj = OpcaoItem.objects.create(grupo=grupo_obj, **opcao_dict)
                ids_opcoes_mantidas.append(opcao_obj.id)

            grupo_obj.opcoes.exclude(id__in=ids_opcoes_mantidas).delete()

        item.grupos_opcoes.exclude(id__in=ids_grupos_mantidos).delete()

    def _disparar_sincronizacao_catalogo(
        self,
        item: ItemMenu,
        motivo: str,
    ) -> None:
        """
        RN-015 / RN-020: Atualiza a cache instantaneamente no processo atual e agenda a
        tarefa assíncrona Celery (no `transaction.on_commit`) para propagar via WebSockets/Redis
        em menos de 5 minutos.
        """
        loja_id = str(item.categoria.loja_id)
        item_id = str(item.id)

        # 1. Limpeza imediata e síncrona na cache Redis local
        invalidar_cache_catalogo_imediato(
            loja_id=loja_id,
            item_id=item_id,
            is_disponivel=item.is_disponivel,
            motivo=motivo,
        )

        # 2. Disparo do evento assíncrono Celery + Channels após confirmação da transação na BD
        def _enfileirar_evento() -> None:
            try:
                sincronizar_alteracao_item_menu_task.delay(
                    loja_id=loja_id,
                    item_id=item_id,
                    nome_item=item.nome,
                    is_disponivel=item.is_disponivel,
                    preco=int(item.preco),
                    motivo=motivo,
                )
            except Exception:
                # Fallback resiliente caso o broker Redis não esteja acessível no ambiente local
                pass

        transaction.on_commit(_enfileirar_evento)

    @transaction.atomic
    def create(self, validated_data: dict[str, Any]) -> ItemMenu:
        grupos_data = validated_data.pop("grupos_opcoes", None)
        item = ItemMenu.objects.create(**validated_data)

        if grupos_data is not None:
            self._guardar_grupos_e_opcoes(item, grupos_data)

        self._disparar_sincronizacao_catalogo(item, motivo="item_created")
        return item

    @transaction.atomic
    def update(self, instance: ItemMenu, validated_data: dict[str, Any]) -> ItemMenu:
        """
        RN-015 e RN-020: Atualiza o `ItemMenu` (e grupos/opções se fornecidos).
        Se o item for marcado como indisponível (`is_disponivel=False`) ou sofrer alteração de preço/dados,
        invalida a cache instantaneamente e dispara o evento assíncrono Celery/Channels para limpar o item
        da visão dos clientes em até 5 minutos.
        """
        estava_disponivel = instance.is_disponivel
        preco_anterior = instance.preco

        grupos_data = validated_data.pop("grupos_opcoes", None)

        for attr, value in validated_data.items():
            setattr(instance, attr, value)
        instance.save()

        if grupos_data is not None:
            self._guardar_grupos_e_opcoes(instance, grupos_data)

        # Determina o motivo específico para auditoria e priorização (RN-015, RN-020)
        if estava_disponivel and not instance.is_disponivel:
            motivo = "item_marked_unavailable_rn015"
        elif not estava_disponivel and instance.is_disponivel:
            motivo = "item_marked_available_rn015"
        elif preco_anterior != instance.preco:
            motivo = "item_price_changed_rn020"
        else:
            motivo = "item_updated_rn020"

        self._disparar_sincronizacao_catalogo(instance, motivo=motivo)
        return instance


# ==============================================================================
# 3. SERIALIZERS DE OPERAÇÃO DO PARCEIRO: PAUSA E HORÁRIOS (RN-012, RN-013)
# ==============================================================================

class PartnerStorePauseStatusSerializer(serializers.Serializer):
    """
    Serializer para ativação ou cancelamento da pausa temporária de pedidos da loja (RN-013).
    Recebe `is_pausa_temporaria` (bool) e `duracao_minutos` (int).
    Endpoint: `PATCH /api/v1/partner/store/status/`.
    """

    is_pausa_temporaria = serializers.BooleanField(
        required=True,
        help_text=_("RN-013: Define se a loja entra em pausa temporária de receção de pedidos."),
    )
    duracao_minutos = serializers.IntegerField(
        required=False,
        default=30,
        min_value=1,
        max_value=1440,  # Máximo de 24 horas (1 dia) para pausa temporária
        help_text=_("RN-013: Duração da pausa em minutos (1 a 1440 minutos). Obrigatório se is_pausa_temporaria=True."),
    )
    reativacao_automatica_em = serializers.DateTimeField(
        read_only=True,
        help_text=_("RN-013: Timestamp exato calculado para reabertura automática da loja."),
    )

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        is_pausa = attrs.get("is_pausa_temporaria", False)
        duracao = attrs.get("duracao_minutos")

        if is_pausa and (duracao is None or duracao <= 0):
            raise serializers.ValidationError(
                {
                    "duracao_minutos": _(
                        "RN-013: Deve especificar uma duração positiva em minutos (ex.: 15, 30, 60) "
                        "ao ativar uma pausa temporária."
                    )
                }
            )
        return attrs


class HorarioFuncionamentoSerializer(serializers.ModelSerializer):
    """
    Serializer individual para turno de `HorarioFuncionamento` da loja (RN-012).
    Valida consistência horária e impede turnos nulos.
    """

    dia_semana_label = serializers.CharField(
        source="get_dia_semana_display",
        read_only=True,
        help_text=_("RN-012: Nome por extenso do dia da semana (Segunda-feira a Domingo)."),
    )

    class Meta:
        model = HorarioFuncionamento
        fields = (
            "id",
            "dia_semana",
            "dia_semana_label",
            "hora_abertura",
            "hora_fecho",
            "is_pausa_temporaria",
            "reativacao_automatica_em",
        )
        read_only_fields = ("id", "dia_semana_label", "is_pausa_temporaria", "reativacao_automatica_em")

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        """
        RN-012: Valida que `hora_abertura` e `hora_fecho` não são idênticas.
        Verifica sobreposição de horários para o mesmo dia da semana na mesma loja.
        """
        hora_abertura = attrs.get("hora_abertura") or getattr(self.instance, "hora_abertura", None)
        hora_fecho = attrs.get("hora_fecho") or getattr(self.instance, "hora_fecho", None)
        dia_semana = attrs.get("dia_semana", getattr(self.instance, "dia_semana", None))

        if hora_abertura == hora_fecho:
            raise serializers.ValidationError(
                _("RN-012: A hora de abertura e a hora de fecho não podem ser idênticas.")
            )

        loja = self.context.get("loja")
        if loja and dia_semana is not None:
            # Consulta outros horários já persistidos para o mesmo dia da semana
            qs = HorarioFuncionamento.objects.filter(loja=loja, dia_semana=dia_semana)
            if self.instance and self.instance.pk:
                qs = qs.exclude(pk=self.instance.pk)

            for outro in qs:
                # Checagem de sobreposição simples para turnos normais
                if outro.hora_abertura < outro.hora_fecho and hora_abertura < hora_fecho:
                    if max(hora_abertura, outro.hora_abertura) < min(hora_fecho, outro.hora_fecho):
                        raise serializers.ValidationError(
                            _(
                                f"RN-012: Existe sobreposição com outro horário existente para este dia "
                                f"({outro.hora_abertura.strftime('%H:%M')} às {outro.hora_fecho.strftime('%H:%M')})."
                            )
                        )

        return attrs


class PartnerStoreHoursMatrixSerializer(serializers.Serializer):
    """
    Serializer para configuração e sincronização em lote da matriz semanal de horários da loja (RN-012).
    Endpoint: `PUT/POST /api/v1/partner/store/hours/`.
    Valida rigorosamente a não sobreposição de horários para o mesmo dia da semana.
    """

    horarios = HorarioFuncionamentoSerializer(many=True)

    def validate_horarios(self, value: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """
        RN-012: Agrupa os turnos por `dia_semana` e valida que nenhum turno se sobrepõe
        com outro no mesmo dia da semana.
        """
        if not value:
            raise serializers.ValidationError(
                _("RN-012: A matriz semanal de horários não pode estar vazia.")
            )

        horarios_por_dia: dict[int, list[dict[str, Any]]] = {}
        for h in value:
            dia = h["dia_semana"]
            horarios_por_dia.setdefault(dia, []).append(h)

        for dia, turnos in horarios_por_dia.items():
            if len(turnos) <= 1:
                continue

            # Compara todos os pares de turnos para o mesmo dia da semana
            for i in range(len(turnos)):
                for j in range(i + 1, len(turnos)):
                    t1 = turnos[i]
                    t2 = turnos[j]
                    a1, f1 = t1["hora_abertura"], t1["hora_fecho"]
                    a2, f2 = t2["hora_abertura"], t2["hora_fecho"]

                    # Caso ambos sejam diurnos (a < f)
                    if a1 < f1 and a2 < f2:
                        if max(a1, a2) < min(f1, f2):
                            nome_dia = HorarioFuncionamento.DiaSemana(dia).label
                            raise serializers.ValidationError(
                                _(
                                    f"RN-012: Sobreposição detetada para {nome_dia}: "
                                    f"Turno 1 ({a1.strftime('%H:%M')} - {f1.strftime('%H:%M')}) colide com "
                                    f"Turno 2 ({a2.strftime('%H:%M')} - {f2.strftime('%H:%M')})."
                                )
                            )
                    else:
                        # Turnos noturnos que cruzam a meia-noite
                        raise serializers.ValidationError(
                            _(
                                f"RN-012: Múltiplos turnos noturnos não podem ser combinados no mesmo dia "
                                f"sem separação explícita de dias civis."
                            )
                        )

        return value

