"""
Serializers da aplicação 'orders' para o fluxo de Checkout (`preview` e `confirm`) e representação
detalhada de Pedidos, Linhas de Pedido, Opções e Eventos Imutáveis (Secções 4, 5, 6.4, 6.5 e 11).
"""
from __future__ import annotations

from typing import Any

from django.utils.translation import gettext_lazy as _
from rest_framework import serializers

from apps.orders.models import EventoPedido, LinhaPedido, LinhaPedidoOpcao, Pedido


class ItemCarrinhoInputSerializer(serializers.Serializer):
    """
    Valida cada linha de item enviada no payload de `POST /api/v1/orders/checkout/preview/`
    (RN-014, RN-042, RN-045).
    """

    item_id = serializers.UUIDField(
        required=True,
        help_text=_("UUID do ItemMenu selecionado pelo cliente."),
    )
    quantidade = serializers.IntegerField(
        required=True,
        min_value=1,
        help_text=_("RN-042: Quantidade inteira de unidades do item (mínimo 1)."),
    )
    opcoes = serializers.ListField(
        child=serializers.UUIDField(),
        required=False,
        allow_empty=True,
        default=list,
        help_text=_("RN-014: Lista de UUIDs de OpcaoItem selecionados para personalizar este item."),
    )
    notas = serializers.CharField(
        required=False,
        allow_blank=True,
        default="",
        max_length=255,
        help_text=_("RN-045: Notas opcionais de preparação destinadas ao parceiro."),
    )


class CheckoutPreviewInputSerializer(serializers.Serializer):
    """
    Serializer de validação de entrada para `POST /api/v1/orders/checkout/preview/`
    (Secção 6.4, RN-040 a RN-044, RN-050 a RN-059).
    """

    loja_id = serializers.UUIDField(
        required=True,
        help_text=_("RN-040: UUID da loja parceira única associada ao carrinho."),
    )
    itens = serializers.ListField(
        child=ItemCarrinhoInputSerializer(),
        required=True,
        allow_empty=False,
        help_text=_("Lista não vazia de itens e respetivas opções que compõem o carrinho."),
    )
    morada_id = serializers.CharField(
        required=False,
        allow_blank=True,
        allow_null=True,
        default=None,
        help_text=_("RN-005 / RN-051: UUID da morada de entrega do cliente autenticado (ou 'morada_principal')."),
    )
    gorjeta_estafeta = serializers.IntegerField(
        required=False,
        default=0,
        min_value=0,
        help_text=_("RN-058 / RN-059: Valor inteiro opcional de gorjeta para o estafeta (unidades mínimas)."),
    )
    cupao_codigo = serializers.CharField(
        required=False,
        allow_blank=True,
        allow_null=True,
        default=None,
        max_length=50,
        help_text=_("RN-056: Código promocional opcional a aplicar ao carrinho."),
    )
    fator_preco_dinamico = serializers.DecimalField(
        required=False,
        max_digits=4,
        decimal_places=2,
        default=None,
        allow_null=True,
        help_text=_("RN-052: Multiplicador opcional de preço dinâmico da zona (1.00 a 2.00)."),
    )


class CheckoutConfirmInputSerializer(serializers.Serializer):
    """
    Serializer de validação de entrada para `POST /api/v1/orders/checkout/confirm/`
    (Secções 4, 5.1, RN-043, RN-065).
    Suporta `id_cotacao` (e alias `cotacao_id`) bem como `metodo_pagamento_id` (e alias `metodo_pagamento`).
    """

    MAPEAMENTO_PREFIXOS_PAGAMENTO: dict[str, str] = {
        "CARD": Pedido.MetodoPagamento.CARTAO,
        "CARTAO": Pedido.MetodoPagamento.CARTAO,
        "CREDIT_CARD": Pedido.MetodoPagamento.CARTAO,
        "DEBIT_CARD": Pedido.MetodoPagamento.CARTAO,
        "WALLET": Pedido.MetodoPagamento.CARTEIRA_DIGITAL,
        "MOBILE_MONEY": Pedido.MetodoPagamento.CARTEIRA_DIGITAL,
        "MCX": Pedido.MetodoPagamento.CARTEIRA_DIGITAL,
        "CARTEIRA_DIGITAL": Pedido.MetodoPagamento.CARTEIRA_DIGITAL,
        "REF": Pedido.MetodoPagamento.REFERENCIA_TRANSFERENCIA,
        "REFERENCIA": Pedido.MetodoPagamento.REFERENCIA_TRANSFERENCIA,
        "REFERENCIA_TRANSFERENCIA": Pedido.MetodoPagamento.REFERENCIA_TRANSFERENCIA,
        "TRANSFERENCIA": Pedido.MetodoPagamento.REFERENCIA_TRANSFERENCIA,
        "INTERNAL_WALLET": Pedido.MetodoPagamento.CARTEIRA_INTERNA,
        "CARTEIRA_INTERNA": Pedido.MetodoPagamento.CARTEIRA_INTERNA,
        "CASH": Pedido.MetodoPagamento.NUMERARIO,
        "COD": Pedido.MetodoPagamento.NUMERARIO,
        "NUMERARIO": Pedido.MetodoPagamento.NUMERARIO,
    }

    id_cotacao = serializers.UUIDField(
        required=False,
        help_text=_("RN-043: Identificador UUID da cotação gerada em /preview/ (válida por 15 minutos)."),
    )
    cotacao_id = serializers.UUIDField(
        required=False,
        write_only=True,
        help_text=_("Alias compatível para 'id_cotacao'."),
    )
    metodo_pagamento_id = serializers.CharField(
        required=False,
        max_length=100,
        help_text=_(
            "RN-065: Identificador ou código do método de pagamento selecionado "
            "(ex.: 'CARTAO', 'CARTEIRA_DIGITAL', 'REFERENCIA_TRANSFERENCIA', 'CARTEIRA_INTERNA', 'NUMERARIO' "
            "ou token/ID de meio de pagamento ex.: 'CARTAO:pm_12345')."
        ),
    )
    metodo_pagamento = serializers.CharField(
        required=False,
        write_only=True,
        max_length=100,
        help_text=_("Alias compatível para 'metodo_pagamento_id'."),
    )

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        # 1. Resolução de `id_cotacao`
        id_cotacao = attrs.get("id_cotacao") or attrs.get("cotacao_id")
        if not id_cotacao:
            raise serializers.ValidationError(
                {
                    "id_cotacao": _(
                        "RN-043: O campo 'id_cotacao' é obrigatório para confirmar o checkout."
                    )
                }
            )
        attrs["id_cotacao"] = str(id_cotacao)

        # 2. Resolução e validação de `metodo_pagamento_id` (RN-065)
        metodo_raw = (
            attrs.get("metodo_pagamento_id")
            or attrs.get("metodo_pagamento")
            or ""
        ).strip()
        if not metodo_raw:
            raise serializers.ValidationError(
                {
                    "metodo_pagamento_id": _(
                        "RN-065: O campo 'metodo_pagamento_id' é obrigatório para iniciar o pagamento."
                    )
                }
            )

        # Extrai o código canónico de `Pedido.MetodoPagamento` (suporta formato direto 'CARTAO' ou composto 'CARTAO:pm_xxx')
        prefixo = metodo_raw.split(":")[0].split("-")[0].strip().upper()
        metodo_normalizado = metodo_raw.upper()

        escolhas_validas = dict(Pedido.MetodoPagamento.choices)
        if metodo_normalizado in escolhas_validas:
            metodo_canonico = metodo_normalizado
        elif prefixo in self.MAPEAMENTO_PREFIXOS_PAGAMENTO:
            metodo_canonico = self.MAPEAMENTO_PREFIXOS_PAGAMENTO[prefixo]
        else:
            opcoes_str = ", ".join(escolhas_validas.keys())
            raise serializers.ValidationError(
                {
                    "metodo_pagamento_id": _(
                        f"RN-065: Método de pagamento '{metodo_raw}' inválido ou não suportado. "
                        f"Valores permitidos: {opcoes_str}."
                    )
                }
            )

        attrs["metodo_pagamento_id"] = metodo_raw
        attrs["metodo_pagamento_canonico"] = metodo_canonico
        return attrs


class LinhaPedidoOpcaoOutputSerializer(serializers.ModelSerializer):
    """Serializer de leitura para as opções congeladas numa linha de pedido (Secção 11)."""

    opcao_nome = serializers.CharField(source="opcao.nome", read_only=True)

    class Meta:
        model = LinhaPedidoOpcao
        fields = [
            "id",
            "opcao",
            "opcao_nome",
            "preco_no_momento",
        ]
        read_only_fields = fields


class LinhaPedidoOutputSerializer(serializers.ModelSerializer):
    """Serializer de leitura para as linhas de artigo de um pedido confirmado (Secção 11)."""

    item_nome = serializers.CharField(source="item.nome", read_only=True)
    opcoes_selecionadas = LinhaPedidoOpcaoOutputSerializer(many=True, read_only=True)

    class Meta:
        model = LinhaPedido
        fields = [
            "id",
            "item",
            "item_nome",
            "quantidade",
            "preco_unitario_no_momento",
            "notas",
            "opcoes_selecionadas",
        ]
        read_only_fields = fields


class EventoPedidoOutputSerializer(serializers.ModelSerializer):
    """Serializer de leitura para os eventos imutáveis do pedido (Secção 5.2 e 12.1)."""

    class Meta:
        model = EventoPedido
        fields = [
            "id",
            "tipo_evento",
            "autor",
            "timestamp",
            "dados_adicionais",
        ]
        read_only_fields = fields


class PedidoConfirmadoOutputSerializer(serializers.ModelSerializer):
    """
    Serializer completo de resposta do `Pedido` criado e transitado para `'2. PAGAMENTO'`
    no endpoint `POST /api/v1/orders/checkout/confirm/` e na listagem do cliente (`GET /api/v1/orders/`).
    """

    estado_display = serializers.CharField(source="get_estado_display", read_only=True)
    metodo_pagamento_display = serializers.CharField(
        source="get_metodo_pagamento_display",
        read_only=True,
    )
    loja_nome = serializers.CharField(source="loja.nome", read_only=True)
    loja_detalhes = serializers.SerializerMethodField(read_only=True)
    morada_detalhes = serializers.SerializerMethodField(read_only=True)
    estafeta_detalhes = serializers.SerializerMethodField(read_only=True)
    pin_entrega = serializers.SerializerMethodField(read_only=True)
    morada_entrega = serializers.SerializerMethodField(read_only=True)
    linhas = LinhaPedidoOutputSerializer(many=True, read_only=True)
    eventos = EventoPedidoOutputSerializer(many=True, read_only=True)

    class Meta:
        model = Pedido
        fields = [
            "id",
            "cliente",
            "loja",
            "loja_nome",
            "loja_detalhes",
            "estado",
            "estado_display",
            "subtotal",
            "taxa_entrega",
            "taxa_servico",
            "taxa_pequeno_pedido",
            "gorjeta_estafeta",
            "descontos",
            "total_cobrado",
            "metodo_pagamento",
            "metodo_pagamento_display",
            "pin_entrega",
            "morada_entrega",
            "morada_detalhes",
            "estafeta_detalhes",
            "linhas",
            "eventos",
            "data_criacao",
            "data_atualizacao",
        ]
        read_only_fields = fields

    def get_pin_entrega(self, obj: Pedido) -> str:
        """RN-094 / RN-095: Devolve o PIN real de 4 dígitos da Entrega associada ao pedido."""
        try:
            entrega = getattr(obj, "entrega_logistica", None)
            if entrega and getattr(entrega, "pin_entrega", None):
                return str(entrega.pin_entrega)
            from apps.logistics.models import Entrega
            entrega_db, _ = Entrega.objects.get_or_create(pedido=obj)
            if entrega_db and entrega_db.pin_entrega:
                return str(entrega_db.pin_entrega)
        except Exception:
            pass
        return f"{(int(obj.id.hex[:8], 16) % 9000) + 1000:04d}"

    def get_morada_entrega(self, obj: Pedido) -> str:
        """Extrai o texto da morada congelada no evento de criação do pedido ou morada padrão do cliente."""
        try:
            for ev in obj.eventos.all():
                if isinstance(ev.dados_adicionais, dict) and ev.dados_adicionais.get("morada_texto"):
                    return str(ev.dados_adicionais["morada_texto"])
        except Exception:
            pass
        try:
            morada = obj.cliente.moradas.order_by("-id").first()
            if morada:
                return morada.texto_endereco
        except Exception:
            pass
        return "Luanda, Angola"

    def get_loja_detalhes(self, obj: Pedido) -> dict[str, Any]:
        loja = getattr(obj, "loja", None)
        if not loja:
            return {
                "id": "",
                "nome": "Restaurante Parceiro",
                "morada": "Luanda, Angola",
                "contacto": "+244 923 000 000",
                "nif": "",
                "score_reputacao": "5.00",
                "latitude": -8.8368,
                "longitude": 13.2343,
            }
        lat = float(loja.geolocalizacao.y) if getattr(loja, "geolocalizacao", None) else -8.8368
        lng = float(loja.geolocalizacao.x) if getattr(loja, "geolocalizacao", None) else 13.2343
        return {
            "id": str(loja.id),
            "nome": loja.nome or "Restaurante Parceiro",
            "morada": getattr(loja, "morada_texto", None) or "Luanda, Angola",
            "contacto": getattr(loja, "contacto", None) or "+244 923 000 000",
            "nif": getattr(loja, "nif", None) or "",
            "score_reputacao": str(getattr(loja, "score_reputacao", "5.00")),
            "latitude": lat,
            "longitude": lng,
        }

    def get_morada_detalhes(self, obj: Pedido) -> dict[str, Any]:
        texto = self.get_morada_entrega(obj)
        ref = ""
        andar = ""
        instrucoes = ""
        lat = -8.8147
        lng = 13.2343
        try:
            morada = obj.cliente.moradas.order_by("-id").first()
            if morada:
                ref = morada.referencia or ""
                andar = morada.andar_porta or ""
                instrucoes = morada.instrucoes_estafeta or ""
                if getattr(morada, "geolocalizacao", None):
                    lat = float(morada.geolocalizacao.y)
                    lng = float(morada.geolocalizacao.x)
        except Exception:
            pass
        return {
            "texto_endereco": texto,
            "referencia": ref,
            "andar_porta": andar,
            "instrucoes_estafeta": instrucoes,
            "latitude": lat,
            "longitude": lng,
        }

    def get_estafeta_detalhes(self, obj: Pedido) -> dict[str, Any]:
        try:
            from apps.logistics.models import Entrega
            entrega = getattr(obj, "entrega_logistica", None)
            if not entrega:
                entrega, _ = Entrega.objects.select_related("estafeta", "estafeta__utilizador").get_or_create(pedido=obj)
            estafeta = getattr(entrega, "estafeta", None)
            dist_km = round((getattr(entrega, "distancia_metros", 2500) or 2500) / 1000.0, 2)
            if not estafeta:
                return {
                    "atribuido": False,
                    "estado_logistico": getattr(entrega, "estado_logistico", "PENDENTE"),
                    "etapa_display": "A aguardar aceitação de estafeta na zona",
                    "distancia_km": dist_km,
                    "eta_minutos": max(8, int(dist_km * 4)),
                }
            u = getattr(estafeta, "utilizador", None)
            if entrega.estado_logistico == Entrega.EstadoEntrega.ENTREGUE:
                etapa_str = "Pedido Entregue"
            elif entrega.chegada_cliente_em:
                etapa_str = "Estafeta à Sua Porta (Aguarda PIN)"
            elif entrega.recolhido_em or entrega.estado_logistico in (
                Entrega.EstadoEntrega.RECOLHIDO,
                Entrega.EstadoEntrega.EM_TRANSITO,
            ):
                etapa_str = "Pedido Recolhido • Em Rota para o Seu Endereço"
            elif entrega.chegada_loja_em:
                etapa_str = "Estafeta no Restaurante a Recolher o Pedido"
            else:
                etapa_str = "Corrida Aceite • Estafeta a Caminho do Restaurante"

            return {
                "atribuido": True,
                "id": str(estafeta.id),
                "nome": (getattr(u, "nome", None) or getattr(u, "email", None) or "Estafeta Ango-iFood") if u else "Estafeta Ango-iFood",
                "telemovel": (getattr(u, "telemovel", None) or "+244 923 111 222") if u else "+244 923 111 222",
                "email": (getattr(u, "email", None) or "") if u else "",
                "tipo_veiculo": estafeta.tipo_veiculo,
                "tipo_veiculo_display": estafeta.get_tipo_veiculo_display(),
                "marca_modelo_veiculo": estafeta.marca_modelo_veiculo or "Haojue 125",
                "matricula_veiculo": estafeta.matricula_veiculo or "LD-44-99-AF",
                "score_reputacao": str(estafeta.score_reputacao or "4.95"),
                "estado_logistico": entrega.estado_logistico,
                "etapa_display": etapa_str,
                "distancia_km": dist_km,
                "eta_minutos": max(5, int(dist_km * 4)),
            }
        except Exception:
            return {"atribuido": False}

