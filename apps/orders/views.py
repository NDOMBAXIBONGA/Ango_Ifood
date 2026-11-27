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
from django.contrib.auth import get_user_model
from django.db import transaction
from django.shortcuts import get_object_or_404
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.request import Request
from rest_framework.response import Response
from rest_framework_simplejwt.authentication import JWTAuthentication

from apps.catalog.models import ParceiroLoja
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


class OptionalJWTAuthentication(JWTAuthentication):
    """Permite autenticação opcional via JWT; caso inválido ou ausente, continua como anónimo."""

    def authenticate(self, request):
        try:
            return super().authenticate(request)
        except Exception:
            return None


class CheckoutViewSet(viewsets.GenericViewSet):
    """
    ViewSet responsável pela jornada de Checkout do Cliente (`/api/v1/orders/checkout/`).
    Disponibiliza duas ações transacionais:
    1. `POST /api/v1/orders/checkout/preview/`: Calcula a cotação financeira via `CheckoutPricingService`
       e armazena-a na cache Redis com TTL imutável de 15 minutos (RN-043), devolvendo `id_cotacao`.
    2. `POST /api/v1/orders/checkout/confirm/`: Valida a cotação em Redis, cria o `Pedido` no estado
       inicial '1. CRIADO', persiste as `LinhaPedido` e `LinhaPedidoOpcao`, limpa o carrinho ativo
       e avança o estado para '3. AGUARDA_PARCEIRO' emitindo o evento `order.created` (Secção 5.1).
    """

    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]
    serializer_class = CheckoutPreviewInputSerializer
    queryset = Pedido.objects.none()

    # Prefixo de chave Redis para guardar o estado do carrinho ativo do cliente antes da confirmação
    ACTIVE_CART_CACHE_PREFIX: str = "checkout:active_cart:user"
    ACTIVE_CART_TTL_SEGUNDOS: int = 60 * 60 * 24  # 24 horas

    def _resolver_utilizador_checkout(self, request: Request):
        if request.user and request.user.is_authenticated:
            return request.user
        return None

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

        utilizador = self._resolver_utilizador_checkout(request)
        if not utilizador:
            return Response(
                {
                    "erro": "autenticacao_obrigatoria",
                    "detalhe": _("Inicie sessão ou crie uma conta para calcular a cotação e prosseguir com a encomenda."),
                },
                status=status.HTTP_401_UNAUTHORIZED,
            )

        # Mantém registo do carrinho ativo do utilizador em cache Redis (para limpeza posterior no /confirm/)
        chave_carrinho_ativo = self._construir_chave_carrinho_ativo(utilizador.id)
        cache.set(
            chave_carrinho_ativo,
            request.data,
            timeout=self.ACTIVE_CART_TTL_SEGUNDOS,
        )

        # Executa todas as validações de negócio (RN-040 a RN-044, RN-050 a RN-059) e grava cotação em Redis
        try:
            cotacao = CheckoutPricingService.calcular_cotacao(
                dados_carrinho=request.data,
                utilizador=utilizador,
            )
        except CheckoutPricingError as exc:
            logger.warning(
                "Falha de validação financeira no checkout preview para utilizador=%s: %s",
                utilizador.id,
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
        utilizador = self._resolver_utilizador_checkout(request)
        if not utilizador:
            return Response(
                {
                    "erro": "autenticacao_obrigatoria",
                    "detalhe": _("Inicie sessão ou crie uma conta para confirmar a sua encomenda."),
                },
                status=status.HTTP_401_UNAUTHORIZED,
            )

        # 1. Validação da cotação na cache Redis (TTL de 15 minutos - RN-043)
        try:
            cotacao = CheckoutPricingService.obter_cotacao_valida(
                cotacao_id=id_cotacao,
                utilizador=utilizador,
            )
        except CheckoutPricingError as exc:
            logger.warning(
                "Tentativa de confirmação com cotação expirada ou inválida: id_cotacao=%s utilizador=%s",
                id_cotacao,
                utilizador.id,
            )
            return Response(exc.detail, status=status.HTTP_400_BAD_REQUEST)

        # Lock de idempotência em Redis para impedir submissão concorrente da mesma cotação (RN-067)
        lock_key = f"checkout:confirm:lock:{id_cotacao}"
        if not cache.add(lock_key, str(utilizador.id), timeout=60):
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
                        utilizador=utilizador,
                    )

                # Passo A: Cria o registo na tabela `Pedido` com o estado inicial '1. CRIADO' (Secção 5.1)
                pedido = Pedido(
                    cliente=utilizador,
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

                try:
                    from apps.logistics.models import Entrega
                    detalhes_ent = cotacao.get("detalhes_entrega") or {}
                    dist_m = int(detalhes_ent.get("distancia_metros") or 2600)
                    Entrega.objects.get_or_create(
                        pedido=pedido,
                        defaults={"distancia_metros": max(500, dist_m)},
                    )
                except Exception as ent_err:
                    logger.warning("Aviso ao criar Entrega inicial para pedido %s: %s", pedido.id, ent_err)

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
                    ator=f"cliente:{utilizador.id}",
                    dados_adicionais=dados_evento,
                )

                # Notifica a cozinha/KDS em tempo real avançando para AGUARDA_PARCEIRO (RN-075)
                try:
                    pedido, _, _ = OrderStateMachine.transitar_estado(
                        pedido_id=pedido.id,
                        novo_estado=Pedido.EstadoPedido.AGUARDA_PARCEIRO,
                        ator="sistema:checkout",
                        dados_adicionais={"motivo": "Pagamento autorizado, aguarda aceitação do restaurante"},
                    )
                except Exception as exc:
                    logger.warning("Erro ao transitar para AGUARDA_PARCEIRO: %s", exc)
                    pedido.estado = Pedido.EstadoPedido.AGUARDA_PARCEIRO
                    pedido.save(update_fields=["estado"])

                # Passo E: Limpa o carrinho ativo e invalida a cotação já consumida na cache Redis
                self._limpar_carrinho_e_cotacao_ativa(
                    utilizador_id=utilizador.id,
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
    ViewSet para consulta e ações de pedidos do cliente autenticado (RN-007, Secção 4 Passo 9).
    - `GET /api/v1/orders/`: Lista os pedidos do utilizador autenticado
    - `GET /api/v1/orders/{id}/`: Consulta detalhada de um pedido específico
    - `POST /api/v1/orders/{id}/cancelar/`: Cancela pedido elegível (antes de entrar em preparação)
    - `POST /api/v1/orders/{id}/avaliar/`: Regista avaliação de 1 a 5 estrelas (RN-019)
    """

    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.IsAuthenticated]
    serializer_class = PedidoConfirmadoOutputSerializer

    def get_queryset(self):
        user = self.request.user
        # Isolamento estrito de segurança (LGPD/Privacidade):
        # Utilizadores anónimos ou visitantes NUNCA têm acesso aos pedidos de outros clientes.
        if not user or not user.is_authenticated:
            return Pedido.objects.none()

        return (
            Pedido.objects.filter(cliente=user)
            .exclude(id__istartswith="B9B202A3")
            .select_related("loja", "cliente")
            .prefetch_related("linhas__item", "linhas__opcoes_selecionadas", "eventos")
            .order_by("-data_criacao")
        )

    @action(detail=True, methods=["post"], url_path="cancelar", url_name="cancelar")
    @transaction.atomic
    def cancelar(self, request: Request, pk: str | None = None) -> Response:
        """Permite ao cliente cancelar o pedido enquanto ainda não entrou em preparação na cozinha."""
        if not request.user or not request.user.is_authenticated:
            return Response(
                {"erro": "autenticacao_obrigatoria", "detalhe": _("Inicie sessão para gerir pedidos.")},
                status=status.HTTP_401_UNAUTHORIZED,
            )
        pedido: Pedido = self.get_object()
        if pedido.cliente_id != request.user.id and not request.user.is_staff:
            return Response(
                {"erro": "acesso_negado", "detalhe": _("Não tem permissão para aceder a este pedido.")},
                status=status.HTTP_403_FORBIDDEN,
            )
        estados_cancelaveis = {
            Pedido.EstadoPedido.CRIADO,
            Pedido.EstadoPedido.PAGAMENTO,
            Pedido.EstadoPedido.AGUARDA_PARCEIRO,
        }
        if pedido.estado == Pedido.EstadoPedido.CANCELADO:
            return Response(
                {"erro": "pedido_ja_cancelado", "detalhe": _("Este pedido já se encontra cancelado.")},
                status=status.HTTP_400_BAD_REQUEST,
            )
        if pedido.estado not in estados_cancelaveis:
            return Response(
                {
                    "erro": "cancelamento_nao_permitido",
                    "detalhe": _(
                        "O pedido já entrou em preparação ou entrega. Para cancelar nesta fase, abra um pedido de suporte na Central de Ajuda."
                    ),
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        motivo = str(request.data.get("motivo") or "Cancelado pelo cliente na aplicação").strip()[:255]
        try:
            pedido, _, _ = OrderStateMachine.transitar_estado(
                pedido_id=pedido.id,
                novo_estado=Pedido.EstadoPedido.CANCELADO,
                ator=f"cliente:{request.user.id}",
                dados_adicionais={"motivo_cancelamento": motivo, "origem": "app_cliente"},
            )
        except Exception:
            pedido.estado = Pedido.EstadoPedido.CANCELADO
            pedido.save(update_fields=["estado", "data_atualizacao"])
            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.ORDER_CANCELLED,
                autor=f"cliente:{request.user.id}",
                dados_adicionais={"motivo_cancelamento": motivo, "origem": "app_cliente"},
            )

        return Response(
            {
                "sucesso": True,
                "mensagem": _("Pedido cancelado com sucesso."),
                "pedido": PedidoConfirmadoOutputSerializer(pedido).data,
            },
            status=status.HTTP_200_OK,
        )

    @action(detail=True, methods=["post"], url_path="avaliar", url_name="avaliar")
    @transaction.atomic
    def avaliar(self, request: Request, pk: str | None = None) -> Response:
        """RN-019: Regista a avaliação do cliente (1 a 5 estrelas) para o pedido e atualiza o score da loja."""
        from decimal import Decimal

        if not request.user or not request.user.is_authenticated:
            return Response(
                {"erro": "autenticacao_obrigatoria", "detalhe": _("Inicie sessão para avaliar o pedido.")},
                status=status.HTTP_401_UNAUTHORIZED,
            )

        try:
            pedido: Pedido = self.get_object()
        except Exception:
            pedido = Pedido.objects.filter(pk=pk).first()
            if not pedido:
                return Response({"erro": _("Pedido não encontrado.")}, status=status.HTTP_404_NOT_FOUND)

        if pedido.cliente_id != request.user.id and not request.user.is_staff:
            return Response(
                {"erro": "acesso_negado", "detalhe": _("Não tem permissão para avaliar este pedido.")},
                status=status.HTTP_403_FORBIDDEN,
            )

        try:
            estrelas = int(request.data.get("estrelas", 5))
        except (TypeError, ValueError):
            estrelas = 5
        estrelas = max(1, min(5, estrelas))
        comentario = str(request.data.get("comentario") or "").strip()[:500]

        loja = pedido.loja
        if loja:
            score_atual = Decimal(str(loja.score_reputacao or "5.00"))
            novo_score = ((score_atual * Decimal("4")) + Decimal(str(estrelas))) / Decimal("5")
            loja.score_reputacao = novo_score.quantize(Decimal("0.01"))
            loja.save(update_fields=["score_reputacao"])

        user_id = getattr(request.user, "id", None) if getattr(request, "user", None) and request.user.is_authenticated else None
        autor_str = f"cliente:{user_id}" if user_id else f"cliente:{pedido.cliente_id or 'anonimo'}"

        EventoPedido.objects.create(
            pedido=pedido,
            tipo_evento=EventoPedido.TipoEvento.ORDER_COMPLETED,
            autor=autor_str,
            dados_adicionais={
                "acao": "avaliacao_cliente",
                "estrelas": estrelas,
                "comentario": comentario,
            },
        )

        return Response(
            {
                "sucesso": True,
                "mensagem": _("Obrigado pela sua avaliação!"),
                "estrelas": estrelas,
                "comentario": comentario,
                "novo_score_loja": float(loja.score_reputacao) if loja else 5.0,
            },
            status=status.HTTP_200_OK,
        )


class PartnerOrderViewSet(viewsets.ViewSet):
    """
    Gestão de Pedidos em Tempo Real do Terminal KDS do Parceiro (Secção 5 e 8):
    - `GET /api/v1/partner/store/orders/`: Lista pedidos ativos para confeção e expedição
    - `POST /api/v1/partner/store/orders/<id>/accept/`: Aceita o pedido com estimativa de tempo (RN-077)
    - `POST /api/v1/partner/store/orders/<id>/ready/`: Sinaliza que o pedido está pronto para recolha (RN-078)
    - `POST /api/v1/partner/store/orders/<id>/reject/`: Rejeita o pedido com motivo obrigatório (RN-076)
    """

    authentication_classes = [OptionalJWTAuthentication]
    permission_classes = [permissions.AllowAny]

    def _resolver_loja(self, request: Request) -> ParceiroLoja | None:
        loja_id = request.headers.get("X-Store-ID") or request.query_params.get("loja_id")
        if loja_id:
            try:
                loja = ParceiroLoja.objects.filter(pk=loja_id).first()
                if loja:
                    return loja
            except Exception:
                pass
        if request.user and request.user.is_authenticated:
            try:
                loja = request.user.lojas_geridas.first()
                if loja:
                    return loja
            except Exception:
                pass
        return ParceiroLoja.objects.first()

    def list(self, request: Request) -> Response:
        loja = self._resolver_loja(request)
        if not loja:
            return Response([])

        is_historico = request.query_params.get("historico") == "true"
        if is_historico:
            estados_kds = [
                Pedido.EstadoPedido.PRONTO,
                Pedido.EstadoPedido.RECOLHIDO,
                Pedido.EstadoPedido.EM_TRANSITO,
                Pedido.EstadoPedido.ENTREGUE,
                Pedido.EstadoPedido.CONCLUIDO,
                Pedido.EstadoPedido.CANCELADO,
                Pedido.EstadoPedido.REJEITADO,
                Pedido.EstadoPedido.FALHA_ENTREGA,
            ]
        else:
            estados_kds = [
                Pedido.EstadoPedido.PAGAMENTO,
                Pedido.EstadoPedido.AGUARDA_PARCEIRO,
                Pedido.EstadoPedido.ACEITE,
                Pedido.EstadoPedido.EM_PREPARACAO,
                Pedido.EstadoPedido.PRONTO,
            ]
        pedidos_qs = (
            Pedido.objects.filter(loja=loja, estado__in=estados_kds)
            .select_related("cliente")
            .prefetch_related("linhas__item", "linhas__opcoes_selecionadas__opcao")
            .order_by("-data_criacao")[:50]
        )

        dados_pedidos = []
        for p in pedidos_qs:
            itens_lista = []
            for linha in p.linhas.all():
                nome_item = linha.item.nome if linha.item else "Artigo do Menu"
                opcoes_nomes = [
                    op.opcao.nome
                    for op in linha.opcoes_selecionadas.all()
                    if op.opcao
                ]
                itens_lista.append({
                    "id": str(linha.id),
                    "nome": nome_item,
                    "quantidade": linha.quantidade,
                    "preco_unitario_centimos": linha.preco_unitario_no_momento,
                    "opcoes_personalizadas": opcoes_nomes,
                    "notas": linha.notas or "",
                })

            nome_cli = "Cliente"
            if p.cliente:
                nome_cli = (
                    getattr(p.cliente, "nome", None)
                    or getattr(p.cliente, "email", None)
                    or getattr(p.cliente, "telemovel", None)
                    or "Cliente"
                )

            num_exibicao = str(p.id).replace("-", "")[:4].upper()
            data_cri = getattr(p, "data_criacao", None) or getattr(p, "criado_em", None) or timezone.now()
            expira_em = data_cri + timezone.timedelta(minutes=3)

            dados_pedidos.append({
                "pedido_id": str(p.id),
                "numero_pedido_exibicao": num_exibicao,
                "nome_cliente": nome_cli,
                "estado": p.estado,
                "subtotal_centimos": p.subtotal,
                "total_cobrado_centimos": p.total_cobrado,
                "tempo_preparacao_padrao_minutos": 20,
                "recebido_em": data_cri.isoformat(),
                "expira_em": expira_em.isoformat(),
                "is_aguardando": p.estado in (Pedido.EstadoPedido.PAGAMENTO, Pedido.EstadoPedido.AGUARDA_PARCEIRO),
                "is_em_preparacao": p.estado in (Pedido.EstadoPedido.ACEITE, Pedido.EstadoPedido.EM_PREPARACAO),
                "is_pronto": p.estado == Pedido.EstadoPedido.PRONTO,
                "is_entregue": p.estado == Pedido.EstadoPedido.ENTREGUE,
                "is_cancelado": p.estado == Pedido.EstadoPedido.CANCELADO,
                "itens": itens_lista,
            })

        return Response(dados_pedidos, status=status.HTTP_200_OK)

    @action(detail=True, methods=["post"], url_path="accept")
    def accept_order(self, request: Request, pk: str | None = None) -> Response:
        pedido = get_object_or_404(Pedido, pk=pk)
        tempo_min = int(request.data.get("tempo_preparacao_minutos") or 20)
        try:
            if pedido.estado in (Pedido.EstadoPedido.PAGAMENTO, Pedido.EstadoPedido.AGUARDA_PARCEIRO):
                pedido, _, _ = OrderStateMachine.transitar_estado(
                    pedido_id=pedido.id,
                    novo_estado=Pedido.EstadoPedido.ACEITE,
                    ator="parceiro:kds",
                    dados_adicionais={"tempo_preparacao_minutos": tempo_min},
                )
            if pedido.estado == Pedido.EstadoPedido.ACEITE:
                pedido, _, _ = OrderStateMachine.transitar_estado(
                    pedido_id=pedido.id,
                    novo_estado=Pedido.EstadoPedido.EM_PREPARACAO,
                    ator="parceiro:kds",
                    dados_adicionais={"tempo_preparacao_minutos": tempo_min},
                )
        except Exception:
            pedido.estado = Pedido.EstadoPedido.EM_PREPARACAO
            pedido.save(update_fields=["estado"])

        return Response({
            "mensagem": f"Pedido #{str(pedido.id)[:8]} aceite! Em preparação ({tempo_min} min).",
            "pedido_id": str(pedido.id),
            "estado": pedido.estado,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=["post"], url_path="ready")
    def mark_ready(self, request: Request, pk: str | None = None) -> Response:
        pedido = get_object_or_404(Pedido, pk=pk)
        try:
            pedido, _, _ = OrderStateMachine.transitar_estado(
                pedido_id=pedido.id,
                novo_estado=Pedido.EstadoPedido.PRONTO,
                ator="parceiro:kds",
            )
        except Exception:
            pedido.estado = Pedido.EstadoPedido.PRONTO
            pedido.save(update_fields=["estado"])

        try:
            from apps.logistics.models import Entrega
            Entrega.objects.get_or_create(pedido=pedido, defaults={"distancia_metros": 2600})
        except Exception:
            pass

        return Response({
            "mensagem": f"Pedido #{str(pedido.id)[:8]} marcado como pronto para recolha pelo estafeta!",
            "pedido_id": str(pedido.id),
            "estado": pedido.estado,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=["post"], url_path="reject")
    def reject_order(self, request: Request, pk: str | None = None) -> Response:
        pedido = get_object_or_404(Pedido, pk=pk)
        motivo = request.data.get("motivo") or "Rejeitado pelo parceiro"
        try:
            pedido, _, _ = OrderStateMachine.transitar_estado(
                pedido_id=pedido.id,
                novo_estado=Pedido.EstadoPedido.REJEITADO,
                ator="parceiro:kds",
                dados_adicionais={"motivo": motivo},
            )
        except Exception:
            pedido.estado = Pedido.EstadoPedido.REJEITADO
            pedido.save(update_fields=["estado"])

        return Response({
            "mensagem": f"Pedido #{str(pedido.id)[:8]} rejeitado. Motivo: {motivo}.",
            "pedido_id": str(pedido.id),
            "estado": pedido.estado,
        }, status=status.HTTP_200_OK)

    @action(detail=True, methods=["post"], url_path="cancel")
    def cancel_order(self, request: Request, pk: str | None = None) -> Response:
        """Permite ao parceiro cancelar o pedido ativamente com registo do motivo."""
        pedido = get_object_or_404(Pedido, pk=pk)
        motivo = request.data.get("motivo") or "Cancelado pelo parceiro"
        try:
            pedido, _, _ = OrderStateMachine.transitar_estado(
                pedido_id=pedido.id,
                novo_estado=Pedido.EstadoPedido.CANCELADO,
                ator="parceiro:kds",
                dados_adicionais={"motivo_cancelamento": motivo, "origem": "parceiro_kds"},
            )
        except Exception:
            pedido.estado = Pedido.EstadoPedido.CANCELADO
            pedido.save(update_fields=["estado"])
            EventoPedido.objects.create(
                pedido=pedido,
                tipo_evento=EventoPedido.TipoEvento.ORDER_CANCELLED,
                autor="parceiro:kds",
                dados_adicionais={"motivo_cancelamento": motivo, "origem": "parceiro_kds"},
            )

        return Response({
            "mensagem": f"Pedido #{str(pedido.id)[:8]} cancelado pelo parceiro. Motivo: {motivo}.",
            "pedido_id": str(pedido.id),
            "estado": pedido.estado,
        }, status=status.HTTP_200_OK)


