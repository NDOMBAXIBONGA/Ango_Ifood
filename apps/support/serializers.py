"""
Serializers da aplicação 'support' (Mediação de Disputas, Incidentes e Auditoria).
Módulo: apps/support/serializers.py

Implementa com rigor técnico:
- RN-106: Limite de compensação por perfil (Agente <= 3.000 Kz / 300.000 cêntimos; exige supervisor_aprovador_id se exceder);
- RN-138 a RN-142: Resolução formal e auditável de disputas associadas a pedidos;
- Secção 8.1 / RN-059: Valores em números inteiros (cêntimos de Kz).
"""
from __future__ import annotations

import uuid
from typing import Any

from rest_framework import serializers

from apps.accounts.models import CustomUser
from apps.orders.models import Pedido
from apps.support.models import TicketDisputa
from apps.support.services import DisputeResolutionService


class TicketDisputaSerializer(serializers.ModelSerializer):
    """
    Serializer de visualização e auditoria de tickets e disputas operacionais (RN-141, RN-142).
    Todos os campos são somente de leitura para preservar a imutabilidade na API.
    """

    autor_decisao_email = serializers.EmailField(
        source="autor_decisao.email", read_only=True, default=None
    )
    autor_decisao_nome = serializers.CharField(
        source="autor_decisao.nome", read_only=True, default=None
    )
    supervisor_aprovador_email = serializers.EmailField(
        source="supervisor_aprovador.email", read_only=True, default=None
    )
    supervisor_aprovador_nome = serializers.CharField(
        source="supervisor_aprovador.nome", read_only=True, default=None
    )
    pedido_id = serializers.UUIDField(source="pedido.id", read_only=True)
    compensacao_valor_formatado_kz = serializers.SerializerMethodField()

    class Meta:
        model = TicketDisputa
        fields = [
            "id",
            "pedido",
            "pedido_id",
            "tipo_incidente",
            "prioridade",
            "motivo",
            "estado",
            "decisao",
            "motivo_justificacao",
            "compensacao_valor",
            "compensacao_valor_formatado_kz",
            "autor_decisao",
            "autor_decisao_email",
            "autor_decisao_nome",
            "supervisor_aprovador",
            "supervisor_aprovador_email",
            "supervisor_aprovador_nome",
            "is_alerta_escalado",
            "data_resolucao",
            "data_criacao",
            "data_atualizacao",
        ]
        read_only_fields = fields

    def get_compensacao_valor_formatado_kz(self, obj: TicketDisputa) -> str:
        """Formata o valor monetário de cêntimos para Kz."""
        return f"{obj.compensacao_valor / 100:.2f} Kz"


class TicketDisputaCreateSerializer(serializers.ModelSerializer):
    """
    Serializer para abertura de novos tickets/incidentes de suporte (RN-138, RN-140).
    """

    pedido_id = serializers.UUIDField(write_only=True, required=True)

    class Meta:
        model = TicketDisputa
        fields = [
            "id",
            "pedido_id",
            "tipo_incidente",
            "prioridade",
            "motivo",
            "data_criacao",
        ]
        read_only_fields = ["id", "data_criacao"]

    def validate_pedido_id(self, value: uuid.UUID) -> uuid.UUID:
        if not Pedido.objects.filter(pk=value).exists():
            raise serializers.ValidationError(
                f"Pedido com ID '{value}' não foi encontrado."
            )
        return value

    def create(self, validated_data: dict[str, Any]) -> TicketDisputa:
        pedido_id = validated_data.pop("pedido_id")
        pedido = Pedido.objects.get(pk=pedido_id)
        return TicketDisputa.objects.create(
            pedido=pedido,
            estado=TicketDisputa.EstadoTicket.ABERTO,
            **validated_data,
        )


class DisputeResolutionInputSerializer(serializers.Serializer):
    """
    Serializer de entrada para o endpoint POST /api/v1/support/disputes/resolve/.
    Aplica validações de alçada de compensação por perfil (RN-106) e exigências de fundamentação (RN-141, RN-142).
    """

    pedido_id = serializers.UUIDField(
        required=True,
        help_text="UUID do pedido em disputa.",
    )
    ticket_id = serializers.UUIDField(
        required=False,
        allow_null=True,
        help_text="UUID opcional de um ticket pré-existente.",
    )
    decisao = serializers.ChoiceField(
        choices=TicketDisputa.DecisaoDisputa.choices,
        required=True,
        help_text="Decisão da disputa: Procedente_Cliente, Procedente_Parceiro, Improcedente.",
    )
    motivo_justificacao = serializers.CharField(
        required=True,
        min_length=10,
        trim_whitespace=True,
        help_text="RN-142: Justificação fundamentada da decisão (mínimo 10 caracteres).",
    )
    compensacao_valor = serializers.IntegerField(
        required=False,
        default=0,
        min_value=0,
        help_text="RN-059: Valor da compensação em cêntimos inteiros (ex: 300.000 cêntimos = 3.000 Kz).",
    )
    supervisor_aprovador_id = serializers.UUIDField(
        required=False,
        allow_null=True,
        default=None,
        help_text="RN-106: ID do supervisor obrigatório se compensacao_valor > 3.000 Kz.",
    )
    tipo_incidente = serializers.ChoiceField(
        choices=TicketDisputa.TipoIncidente.choices,
        required=False,
        default=TicketDisputa.TipoIncidente.DISPUTA_COMERCIAL,
        help_text="RN-138 / RN-140: Classificação do incidente.",
    )
    prioridade = serializers.ChoiceField(
        choices=TicketDisputa.PrioridadeTicket.choices,
        required=False,
        default=TicketDisputa.PrioridadeTicket.MEDIA,
        help_text="RN-139: Prioridade com SLA de escalamento emergencial.",
    )

    def validate_pedido_id(self, value: uuid.UUID) -> uuid.UUID:
        if not Pedido.objects.filter(pk=value).exists():
            raise serializers.ValidationError(
                f"Pedido com ID '{value}' não foi encontrado no sistema."
            )
        return value

    def validate_ticket_id(self, value: uuid.UUID | None) -> uuid.UUID | None:
        if value and not TicketDisputa.objects.filter(pk=value).exists():
            raise serializers.ValidationError(
                f"Ticket de Disputa com ID '{value}' não existe."
            )
        return value

    def validate(self, attrs: dict[str, Any]) -> dict[str, Any]:
        """
        RN-106 (Limites de Compensação por Perfil):
        Valida se o utilizador autenticado (request.user) possui perfil de 'Agente'.
        Se o compensacao_valor exceder o limite de 3.000 Kz (300.000 cêntimos) e o utilizador
        não for Supervisor, barra a gravação e exige o ID de um Supervisor válido.
        """
        request = self.context.get("request")
        user = getattr(request, "user", None) if request else None

        compensacao_valor = attrs.get("compensacao_valor", 0)
        supervisor_aprovador_id = attrs.get("supervisor_aprovador_id")

        limite_agente = DisputeResolutionService.obter_limite_compensacao_agente()
        eh_supervisor = DisputeResolutionService.verificar_eh_supervisor(user) if user else False

        # Se não for Supervisor e exceder o teto do perfil Agente (RN-106)
        if compensacao_valor > limite_agente and not eh_supervisor:
            if not supervisor_aprovador_id:
                raise serializers.ValidationError(
                    {
                        "supervisor_aprovador_id": (
                            f"RN-106: O valor de compensação ({compensacao_valor} cêntimos = {compensacao_valor / 100:.2f} Kz) "
                            f"ultrapassa o teto permitido para o perfil Agente ({limite_agente} cêntimos = {limite_agente / 100:.2f} Kz). "
                            "É obrigatório fornecer o 'supervisor_aprovador_id' com perfil de Supervisor para autorização."
                        )
                    }
                )

            try:
                supervisor = CustomUser.objects.get(pk=supervisor_aprovador_id)
            except CustomUser.DoesNotExist:
                raise serializers.ValidationError(
                    {
                        "supervisor_aprovador_id": (
                            f"RN-106: Utilizador aprovador com ID '{supervisor_aprovador_id}' não foi encontrado."
                        )
                    }
                )

            if not DisputeResolutionService.verificar_eh_supervisor(supervisor):
                raise serializers.ValidationError(
                    {
                        "supervisor_aprovador_id": (
                            f"RN-106: O utilizador '{supervisor.email}' indicado no 'supervisor_aprovador_id' "
                            "não possui credenciais nem permissões de Supervisor no sistema."
                        )
                    }
                )

            attrs["supervisor_aprovador"] = supervisor
        elif supervisor_aprovador_id:
            # Caso tenha sido passado opcionalmente mesmo dentro do limite
            try:
                supervisor = CustomUser.objects.get(pk=supervisor_aprovador_id)
                if DisputeResolutionService.verificar_eh_supervisor(supervisor):
                    attrs["supervisor_aprovador"] = supervisor
            except CustomUser.DoesNotExist:
                pass

        return attrs

