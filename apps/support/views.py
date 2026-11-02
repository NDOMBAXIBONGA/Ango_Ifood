"""
Views e ViewSets da aplicação 'support' (Mediação de Disputas, Helpdesk e Auditoria).
Módulo: apps/support/views.py

Implementa com rigor técnico:
- RN-106: Validação de alçadas e limites de compensação por perfil (Agente <= 3.000 Kz);
- RN-138 a RN-142: Gestão, mediação e registo imutável de decisões de suporte;
- RN-142: Bloqueio estrito de mutação (PUT, PATCH, DELETE) para conformidade e integridade probatória de auditoria.
"""
from __future__ import annotations

import logging
from typing import Any

from rest_framework import permissions, status, viewsets
from rest_framework.decorators import action
from rest_framework.request import Request
from rest_framework.response import Response

from apps.support.models import TicketDisputa
from apps.support.serializers import (
    DisputeResolutionInputSerializer,
    TicketDisputaCreateSerializer,
    TicketDisputaSerializer,
)
from apps.support.services import (
    CompensationLimitExceededError,
    DisputeResolutionService,
    DisputeServiceError,
)

logger = logging.getLogger("support.views")


class DisputeResolutionViewSet(viewsets.ModelViewSet):
    """
    ViewSet para consulta, abertura e resolução de disputas operacionais e incidentes de suporte.

    Conformidade com RN-142 (Auditoria Imutável):
    Os métodos HTTP PUT, PATCH e DELETE são terminantemente bloqueados retornando HTTP 405 Method Not Allowed.
    Nenhuma decisão histórica ou ticket de incidente pode ser alterado ou apagado após a persistência.
    """

    queryset = (
        TicketDisputa.objects.all()
        .select_related("pedido", "autor_decisao", "supervisor_aprovador")
        .order_by("-data_criacao")
    )
    serializer_class = TicketDisputaSerializer
    permission_classes = [permissions.IsAuthenticated]
    http_method_names = ["get", "post", "head", "options"]

    def get_serializer_class(self):
        if self.action == "create":
            return TicketDisputaCreateSerializer
        elif self.action == "resolve":
            return DisputeResolutionInputSerializer
        return TicketDisputaSerializer

    def update(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        RN-142: Bloqueia expressamente atualizações completas (HTTP PUT).
        """
        return Response(
            {
                "detail": "RN-142: Atualização de tickets de disputa proibida. Decisões de suporte são estritamente imutáveis.",
                "codigo": "IMMUTABLE_SUPPORT_AUDIT",
            },
            status=status.HTTP_405_METHOD_NOT_ALLOWED,
        )

    def partial_update(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        RN-142: Bloqueia expressamente atualizações parciais (HTTP PATCH).
        """
        return Response(
            {
                "detail": "RN-142: Modificação parcial de tickets de disputa proibida. Decisões de suporte são estritamente imutáveis.",
                "codigo": "IMMUTABLE_SUPPORT_AUDIT",
            },
            status=status.HTTP_405_METHOD_NOT_ALLOWED,
        )

    def destroy(self, request: Request, *args: Any, **kwargs: Any) -> Response:
        """
        RN-142: Bloqueia expressamente a eliminação de tickets (HTTP DELETE).
        """
        return Response(
            {
                "detail": "RN-142: Eliminação de tickets de suporte proibida. Os registos são permanentes para efeitos de auditoria legal e financeira.",
                "codigo": "DELETION_FORBIDDEN",
            },
            status=status.HTTP_405_METHOD_NOT_ALLOWED,
        )

    @action(detail=False, methods=["post"], url_path="resolve")
    def resolve(self, request: Request) -> Response:
        """
        POST /api/v1/support/disputes/resolve/
        Regista formalmente a resolução de uma disputa contratual ou técnica entre cliente e parceiro (RN-141).

        Regras Aplicadas:
        - RN-106: Se o utilizador autenticado for Agente, valida se compensacao_valor <= 3.000 Kz (300.000 cêntimos).
          Se exceder, exige a identificação prévia de um Supervisor (supervisor_aprovador_id).
        - RN-141: Grava a decisão (Procedente_Cliente, Procedente_Parceiro, Improcedente) fundamentada.
        - RN-142: Gravação imutável no modelo TicketDisputa, auditoria com o autor da decisão e evento no histórico do pedido.
        - Secção 7.3: Lançamento de compensação no livro-razão caso proceda indemnização financeira.
        """
        serializer = DisputeResolutionInputSerializer(
            data=request.data, context={"request": request}
        )
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        try:
            resultado = DisputeResolutionService.resolver_disputa(
                pedido_id=data["pedido_id"],
                decisao=data["decisao"],
                motivo_justificacao=data["motivo_justificacao"],
                compensacao_valor=data.get("compensacao_valor", 0),
                autor=request.user,
                supervisor_aprovador=data.get("supervisor_aprovador"),
                tipo_incidente=data.get(
                    "tipo_incidente", TicketDisputa.TipoIncidente.DISPUTA_COMERCIAL
                ),
                prioridade=data.get(
                    "prioridade", TicketDisputa.PrioridadeTicket.MEDIA
                ),
                ticket_id=data.get("ticket_id"),
            )
            return Response(resultado, status=status.HTTP_200_OK)

        except CompensationLimitExceededError as exc:
            logger.warning(
                "RN-106: Tentativa de compensação acima da alçada por %s: %s",
                request.user.email,
                exc.mensagem,
            )
            return Response(
                {
                    "erro": exc.mensagem,
                    "codigo": exc.codigo,
                    "detalhes": exc.detalhes,
                },
                status=status.HTTP_403_FORBIDDEN,
            )

        except DisputeServiceError as exc:
            logger.error("Erro na resolução de disputa: %s", exc.mensagem)
            return Response(
                {
                    "erro": exc.mensagem,
                    "codigo": exc.codigo,
                    "detalhes": exc.detalhes,
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

