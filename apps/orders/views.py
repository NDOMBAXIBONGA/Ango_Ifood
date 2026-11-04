"""
Views e ViewSets da API REST (Django REST Framework) para o fluxo de Checkout e Criação de Pedidos ('orders').
Implementa rigorosamente a sequência da jornada descrita nas Secções 4 e 5, bem como as Regras de Negócio:
- Secção 4 (Fluxo Ponta a Ponta - Passos 2 e 3): Validação final do carrinho, cálculo de taxas, geração de
  cotação temporária em Redis e confirmação do pedido com transição para pagamento e emissão do evento `order.created`.
- Secção 5.1 (Máquina de Estados do Pedido): Criação inicial no estado '1. CRIADO' (`Pedido.EstadoPedido.CRIADO`),
  criação das linhas (`LinhaPedido` e `LinhaPedidoOpcao`), limpeza do carrinho ativo e transição imediata para o
  estado '2. PAGAMENTO' (`Pedido.EstadoPedido.PAGAMENTO`) com registo imutável de `EventoPedido` (`order.created`).
- RN-040 a RN-045: Unicidade de loja no carrinho, pedido mínimo, limites de quantidade, validade estrita de 15 minutos
  da cotação em Redis (RN-043) e congelamento dos preços contratados.
- RN-050 a RN-059: Decomposição financeira transparente em unidades mínimas inteiras (Cêntimos/Kwanza convertido).
- RN-065 e RN-067: Validação do método de pagamento e proteção de idempotência contra submissões duplicadas.
"""
from __future__ import annotations

import logging
from typing import Any

from django.core.cache import cache
from django.db import transaction
from django.utils.translation import gettext_lazy as _
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.request import Request
from rest_framework.response import Response

from apps.orders.models import EventoPedido, LinhaPedido, LinhaPedidoOpcao, Pedido
from apps.orders.serializers import (
    CheckoutConfirmInputSerializer,
    CheckoutPreviewInputSerializer,
    PedidoConfirmadoOutputSerializer,
)
from apps.orders.services import CheckoutPricingError, CheckoutPricingService
from apps.orders.state_machine import OrderStateMachine
from apps.promotions.models import CupaoDesconto

logger = logging.getLogger(__name__)


class CheckoutViewSet(viewsets.GenericViewSet):
    """
    ViewSet responsável pela jornada de Checkout do Cliente (`/api/v1/orders/checkout/`).
    Disponibiliza duas ações transacionais:
    1. `POST /api/v1/orders/checkout/preview/`: Calcula a cotação financeira via `CheckoutPricingService`
       e armazena-a na cache Redis com TTL imutável de 15 minutos (RN-043), devolvendo `id_cotacao`.
    2. `POST /api/v1/orders/checkout/confirm/`: Valida a cotação em Redis, cria o `Pedido` no estado
       inicial '1. CRIADO', persiste as `LinhaPedido` e `LinhaPedidoOpcao`, limpa o carrinho ativo
       e avança o estado para '2. PAGAMENTO' emitindo o evento imutável `order.created` (Secção 5.1).
    """

    permission_classes = [permissions.IsAuthenticated]
    serializer_class = CheckoutPreviewInputSerializer
    queryset = Pedido.objects.none()

    # Prefixo de chave Redis para guardar o estado do carrinho ativo do cliente antes da confirmação
    ACTIVE_CART_CACHE_PREFIX: str = "checkout:active_cart:user"
    ACTIVE_CART_TTL_SEGUNDOS: int = 60 * 60 * 24  # 24 horas

    def get_serializer_class(self):
        if self.action == "confirm":
            return CheckoutConfirmInputSerializer
        return CheckoutPreviewInputSerializer

    # =========================================================================
    # 1. ENDPOINT: POST /api/v1/orders/checkout/preview/
    # =========================================================================

    @action(detail=False, methods=["post"], url_path="preview", url_name="preview")
    def preview(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        Recebe os dados do carrinho (`loja_id`, `itens`, `morada_id`, `gorjeta_estafeta`, `cupao_codigo`),
        executa `CheckoutPricingService.calcular_cotacao(dados_carrinho, request.user)` e devolve o
        resumo detalhado de preços em unidades mínimas inteiras juntamente com o `id_cotacao`
        armazenado na cache Redis por 15 minutos (RN-043).
        """
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        # Mantém registo do carrinho ativo do utilizador em cache Redis (para limpeza posterior no /confirm/)
        chave_carrinho_ativo = self._construir_chave_carrinho_ativo(request.user.id)
        cache.set(
            chave_carrinho_ativo,
            request.data,
            timeout=self.ACTIVE_CART_TTL_SEGUNDOS,
        )

        # Executa todas as validações de negócio (RN-040 a RN-044, RN-050 a RN-059) e grava cotação em Redis
        try:
            cotacao = CheckoutPricingService.calcular_cotacao(
                dados_carrinho=request.data,
                utilizador=request.user,
            )
        except CheckoutPricingError as exc:
            logger.warning(
                "Falha de validação financeira no checkout preview para utilizador=%s: %s",
                request.user.id,
                exc.detail,
            )
            return Response(exc.detail, status=status.HTTP_400_BAD_REQUEST)

        resposta_preview: dict[str, Any] = {
            "id_cotacao": cotacao["cotacao_id"],
            "cotacao_id": cotacao["cotacao_id"],
            "expira_em": cotacao["expira_em"],
            "ttl_segundos": cotacao["ttl_segundos"],
            "loja_id": cotacao["loja_id"],
            "loja_nome": cotacao["loja_nome"],
            "morada_id": cotacao["morada_id"],
            "morada_texto": cotacao["morada_texto"],
            "resumo_precos": {
                "subtotal": cotacao["subtotal"],
                "taxa_entrega": cotacao["taxa_entrega"],
                "taxa_servico": cotacao["taxa_servico"],
                "taxa_pequeno_pedido": cotacao["taxa_pequeno_pedido"],
                "gorjeta_estafeta": cotacao["gorjeta_estafeta"],
                "descontos": cotacao["descontos"],
                "total_cobrado": cotacao["total_cobrado"],
                "moeda_unidades_minimas": True,
            },
            # Mantém também os campos no nível de topo para compatibilidade direta com clientes Mobile/Web
            "subtotal": cotacao["subtotal"],
            "taxa_entrega": cotacao["taxa_entrega"],
            "taxa_servico": cotacao["taxa_servico"],
            "taxa_pequeno_pedido": cotacao["taxa_pequeno_pedido"],
            "gorjeta_estafeta": cotacao["gorjeta_estafeta"],
            "descontos": cotacao["descontos"],
            "total_cobrado": cotacao["total_cobrado"],
            "detalhes_entrega": cotacao["detalhes_entrega"],
            "detalhes_taxa_servico": cotacao["detalhes_taxa_servico"],
            "detalhes_pedido_minimo": cotacao["detalhes_pedido_minimo"],
            "cupao": cotacao["cupao"],
            "itens": cotacao["itens"],
            "quantidade_total_itens": cotacao["quantidade_total_itens"],
        }

        logger.info(
            "Cotação de checkout gerada com sucesso: id_cotacao=%s utilizador=%s loja=%s total_cobrado=%s",
            cotacao["cotacao_id"],
            request.user.id,
            cotacao["loja_id"],
            cotacao["total_cobrado"],
        )
        return Response(resposta_preview, status=status.HTTP_200_OK)

    # =========================================================================
    # 2. ENDPOINT: POST /api/v1/orders/checkout/confirm/
    # =========================================================================

    @action(detail=False, methods=["post"], url_path="confirm", url_name="confirm")
    def confirm(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        Recebe `id_cotacao` e `metodo_pagamento_id`:
        1. Valida se a cotação na cache Redis ainda é válida (dentro dos 15 minutos da regra RN-043).
           Se expirou ou não existe, devolve erro HTTP 400.
        2. Numa transação atómica (`transaction.atomic()`):
           - Cria o registo na tabela `Pedido` com o estado inicial `'CRIADO'` (`1. Criado (Carrinho Validado)`).
           - Cria as respetivas linhas de pedido (`LinhaPedido`) e opções selecionadas (`LinhaPedidoOpcao`)
             com os preços congelados na cotação.
           - Limpa o carrinho ativo e consome a cotação na cache Redis.
           - Avança o estado do pedido para `'PAGAMENTO'` (`2. Pagamento (Autorizado/Capturado)`)
             gerando o evento imutável `order.created` na tabela `EventoPedido` (Secção 5.1).
        """
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        id_cotacao: str = serializer.validated_data["id_cotacao"]
        metodo_pagamento_id: str = serializer.validated_data["metodo_pagamento_id"]
        metodo_pagamento_canonico: str = serializer.validated_data["metodo_pagamento_canonico"]

        # 1. Validação da cotação na cache Redis (TTL de 15 minutos - RN-043)
        try:
            cotacao = CheckoutPricingService.obter_cotacao_valida(
                cotacao_id=id_cotacao,
                utilizador=request.user,
            )
        except CheckoutPricingError as exc:
            logger.warning(
                "Tentativa de confirmação com cotação expirada ou inválida: id_cotacao=%s utilizador=%s",
                id_cotacao,
                request.user.id,
            )
            return Response(exc.detail, status=status.HTTP_400_BAD_REQUEST)

        # Lock de idempotência em Redis para impedir submissão concorrente da mesma cotação (RN-067)
        lock_key = f"checkout:confirm:lock:{id_cotacao}"
        if not cache.add(lock_key, str(request.user.id), timeout=60):
            return Response(
                {
                    "erro": _(
                        "RN-067: Esta cotação já se encontra em processamento de confirmação. "
                        "Aguarde alguns segundos para evitar duplicação do pedido."
                    ),
                    "codigo_regra": "RN-067",
                    "id_cotacao": id_cotacao,
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        try:
            with transaction.atomic():
                # Se a cotação incluiu um cupão de desconto, bloqueia a linha do cupão (`select_for_update`)
                # e revalida os limites global e por utilizador dentro da transação (RN-056)
                cupao_info = cotacao.get("cupao")
                if cupao_info and cupao_info.get("cupao_id"):
                    self._revalidar_cupao_em_transacao(
                        cupao_id=cupao_info["cupao_id"],
                        utilizador=request.user,
                    )

                # Passo A: Cria o registo na tabela `Pedido` com o estado inicial '1. CRIADO' (Secção 5.1)
                pedido = Pedido(
                    cliente=request.user,
                    loja_id=cotacao["loja_id"],
                    estado=Pedido.EstadoPedido.CRIADO,
                    subtotal=int(cotacao["subtotal"]),
                    taxa_entrega=int(cotacao["taxa_entrega"]),
                    taxa_servico=int(cotacao["taxa_servico"]),
                    taxa_pequeno_pedido=int(cotacao["taxa_pequeno_pedido"]),
                    gorjeta_estafeta=int(cotacao["gorjeta_estafeta"]),
                    descontos=int(cotacao["descontos"]),
                    total_cobrado=int(cotacao["total_cobrado"]),
                    metodo_pagamento=metodo_pagamento_canonico,
                )
                pedido.full_clean()
                pedido.save()

                estado_inicial_registado = pedido.estado  # 'CRIADO' ('1. Criado (Carrinho Validado)')

                # Passo B: Cria as respetivas linhas de pedido (`LinhaPedido`) e opções (`LinhaPedidoOpcao`)
                # congelando os preços unitários exatos do momento da cotação (RN-020, RN-042, RN-043, RN-045)
                for item_cotado in cotacao.get("itens", []):
                    linha_pedido = LinhaPedido.objects.create(
                        pedido=pedido,
                        item_id=item_cotado["item_id"],
                        quantidade=int(item_cotado["quantidade"]),
                        preco_unitario_no_momento=int(item_cotado["preco_unitario_no_momento"]),
                        notas=str(item_cotado.get("notas") or "")[:255],
                    )

                    opcoes_a_criar = [
                        LinhaPedidoOpcao(
                            linha_pedido=linha_pedido,
                            opcao_id=opcao_cotada["opcao_id"],
                            preco_no_momento=int(opcao_cotada["preco_no_momento"]),
                        )
                        for opcao_cotada in item_cotado.get("opcoes", [])
                    ]
                    if opcoes_a_criar:
                        LinhaPedidoOpcao.objects.bulk_create(opcoes_a_criar)

                # Passo C e D: Transita para '2. PAGAMENTO' via OrderStateMachine registando o evento imutável (Secção 5.1 e 5.2)
                dados_evento: dict[str, Any] = {
                    "id_cotacao": id_cotacao,
                    "assinatura_carrinho": cotacao.get("assinatura_carrinho"),
                    "morada_id": cotacao.get("morada_id"),
                    "morada_texto": cotacao.get("morada_texto"),
                    "metodo_pagamento_id": metodo_pagamento_id,
                    "metodo_pagamento": metodo_pagamento_canonico,
                    "decomposicao_financeira": {
                        "subtotal": pedido.subtotal,
                        "taxa_entrega": pedido.taxa_entrega,
                        "taxa_servico": pedido.taxa_servico,
                        "taxa_pequeno_pedido": pedido.taxa_pequeno_pedido,
                        "gorjeta_estafeta": pedido.gorjeta_estafeta,
                        "descontos": pedido.descontos,
                        "total_cobrado": pedido.total_cobrado,
                    },
                    "detalhes_entrega": cotacao.get("detalhes_entrega", {}),
                }
                if cupao_info:
                    dados_evento["cupao_codigo"] = cupao_info.get("codigo")
                    dados_evento["cupao"] = cupao_info

                pedido, evento_criado, _ = OrderStateMachine.transitar_estado(
                    pedido_id=pedido.id,
                    novo_estado=Pedido.EstadoPedido.PAGAMENTO,
                    ator=f"cliente:{request.user.id}",
                    dados_adicionais=dados_evento,
                )

                # Passo E: Limpa o carrinho ativo e invalida a cotação já consumida na cache Redis
                self._limpar_carrinho_e_cotacao_ativa(
                    utilizador_id=request.user.id,
                    id_cotacao=id_cotacao,
                )

        except CheckoutPricingError as exc:
            cache.delete(lock_key)
            return Response(exc.detail, status=status.HTTP_400_BAD_REQUEST)
        except Exception:
            cache.delete(lock_key)
            raise

        # Recarrega o pedido com linhas, opções e eventos para serialização de resposta
        pedido_completo = (
            Pedido.objects.select_related("loja", "cliente")
            .prefetch_related("linhas__item", "linhas__opcoes_selecionadas__opcao", "eventos")
            .get(pk=pedido.pk)
        )
        output_serializer = PedidoConfirmadoOutputSerializer(pedido_completo)

        evento_nome = evento_criado.tipo_evento if evento_criado else EventoPedido.TipoEvento.ORDER_CREATED

        logger.info(
            "Pedido confirmado com sucesso: pedido_id=%s estado=%s evento=%s total_cobrado=%s",
            pedido.id,
            pedido.estado,
            evento_nome,
            pedido.total_cobrado,
        )

        return Response(
            {
                "mensagem": _(
                    "Pedido criado no estado '1. CRIADO', carrinho limpo e estado avançado "
                    "para '2. PAGAMENTO' com emissão do evento 'order.created'."
                ),
                "id_cotacao_consumida": id_cotacao,
                "carrinho_limpo": True,
                "evento_gerado": evento_nome,
                "pedido": output_serializer.data,
            },
            status=status.HTTP_201_CREATED,
        )

    # =========================================================================
    # MÉTODOS AUXILIARES DE GESTÃO DE SESSÃO DE CARRINHO E TRANSAÇÃO
    # =========================================================================

    @classmethod
    def _construir_chave_carrinho_ativo(cls, utilizador_id: Any) -> str:
        """Retorna a chave Redis onde o carrinho ativo do cliente é mantido."""
        return f"{cls.ACTIVE_CART_CACHE_PREFIX}:{utilizador_id}"

    @classmethod
    def _limpar_carrinho_e_cotacao_ativa(cls, utilizador_id: Any, id_cotacao: str) -> None:
        """
        Remove da cache Redis:
        1. O carrinho ativo do cliente (`checkout:active_cart:user:<id>` e `cart:user:<id>`).
        2. A cotação recém-consumida (`checkout:cotacao:<id_cotacao>`), impedindo reutilização.
        3. O ponteiro de última cotação do utilizador (`checkout:cotacao:user:<id>:latest`).
        """
        chaves_para_remover = [
            cls._construir_chave_carrinho_ativo(utilizador_id),
            f"cart:user:{utilizador_id}",
            f"{CheckoutPricingService.CACHE_KEY_PREFIX}:{id_cotacao}",
            f"{CheckoutPricingService.CACHE_KEY_PREFIX}:user:{utilizador_id}:latest",
        ]
        cache.delete_many(chaves_para_remover)

    @staticmethod
    def _revalidar_cupao_em_transacao(cupao_id: str, utilizador: Any) -> None:
        """
        RN-056: Garante com bloqueio pessimista (`select_for_update`) que o cupão aplicado
        na cotação não excedeu o `limite_global_uso` nem o `limite_por_utilizador` entre
        o momento do `/preview/` e o momento do `/confirm/`.
        """
        try:
            cupao = CupaoDesconto.objects.select_for_update().get(pk=cupao_id)
        except CupaoDesconto.DoesNotExist as exc:
            raise CheckoutPricingError(
                mensagem=_("RN-056: O cupão associado à cotação deixou de existir."),
                codigo_regra="RN-056",
            ) from exc

        if not cupao.esta_dentro_da_validade:
            raise CheckoutPricingError(
                mensagem=_(f"RN-056: O cupão '{cupao.codigo}' expirou antes da confirmação do pedido."),
                codigo_regra="RN-056",
            )

        eventos_uso_qs = EventoPedido.objects.filter(
            tipo_evento=EventoPedido.TipoEvento.ORDER_CREATED,
            dados_adicionais__cupao_codigo=cupao.codigo,
        ).exclude(pedido__estado=Pedido.EstadoPedido.CANCELADO)

        usos_globais = eventos_uso_qs.values("pedido_id").distinct().count()
        if usos_globais >= int(cupao.limite_global_uso):
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-056: O cupão '{cupao.codigo}' esgotou o limite global de utilizações ({cupao.limite_global_uso})."
                ),
                codigo_regra="RN-056",
            )

        usos_utilizador = (
            eventos_uso_qs.filter(pedido__cliente=utilizador)
            .values("pedido_id")
            .distinct()
            .count()
        )
        if usos_utilizador >= int(cupao.limite_por_utilizador):
            raise CheckoutPricingError(
                mensagem=_(
                    f"RN-056: Já atingiu o limite máximo de {cupao.limite_por_utilizador} "
                    f"utilização(ões) para o cupão '{cupao.codigo}'."
                ),
                codigo_regra="RN-056",
            )


class CustomerOrderViewSet(viewsets.ReadOnlyModelViewSet):
    """
    ViewSet para consulta de pedidos do cliente autenticado (RN-007, Secção 4 Passo 9).
    - `GET /api/v1/orders/`: Lista os pedidos do utilizador autenticado
    - `GET /api/v1/orders/{id}/`: Consulta detalhada de um pedido específico
    """

    permission_classes = [permissions.IsAuthenticated]
    serializer_class = PedidoConfirmadoOutputSerializer

    def get_queryset(self):
        user = self.request.user
        if not user.is_authenticated:
            return Pedido.objects.none()
        return (
            Pedido.objects.filter(cliente=user)
            .select_related("loja", "cliente")
            .prefetch_related("linhas__item", "linhas__opcoes_selecionadas")
            .order_by("-data_criacao")
        )
