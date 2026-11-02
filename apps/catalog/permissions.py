"""
Permissões personalizadas do Django REST Framework para o Portal do Parceiro.
Implementa os requisitos de segurança e validação de perfil (RN-011, RN-019).
"""
from django.utils.translation import gettext_lazy as _
from rest_framework import permissions
from rest_framework.exceptions import PermissionDenied

from apps.accounts.models import CustomUser
from apps.catalog.models import ParceiroLoja


class IsActivePartner(permissions.BasePermission):
    """
    RN-011 / RN-019: Exige autenticação JWT e valida que o utilizador autenticado
    possui perfil de Parceiro ativo e loja com status 'ATIVO' (ou 'PAUSADO', mas não 'PENDENTE' nem 'SUSPENSO').
    """

    message = _("RN-011: Apenas parceiros comerciais com conta e loja ativas podem aceder a esta funcionalidade.")

    def has_permission(self, request, view) -> bool:
        user = request.user
        if not user or not user.is_authenticated:
            return False

        if user.is_staff:
            return True

        # Valida estado da conta do utilizador (RN-008)
        if user.estado != CustomUser.EstadoConta.ATIVO:
            raise PermissionDenied(
                _("RN-008: A sua conta de utilizador não se encontra ativa.")
            )

        # Consulta a loja gerida pelo parceiro (RN-010, RN-011)
        loja_id = (
            request.headers.get("X-Store-ID")
            or request.query_params.get("loja_id")
            or (request.data.get("loja") if isinstance(request.data, dict) else None)
        )

        qs = ParceiroLoja.objects.filter(proprietario=user)
        if loja_id:
            loja = qs.filter(pk=loja_id).first()
        else:
            loja = qs.first()

        if loja is None:
            raise PermissionDenied(
                _("RN-011: O utilizador não possui nenhuma loja parceira vinculada à sua conta.")
            )

        if loja.estado == ParceiroLoja.EstadoLoja.PENDENTE:
            raise PermissionDenied(
                _("RN-011: A sua loja encontra-se em aprovação documental pendente. Aguarde validação pelas Operações.")
            )

        if loja.estado == ParceiroLoja.EstadoLoja.SUSPENSO:
            raise PermissionDenied(
                _("RN-019: A sua loja encontra-se suspensa por infração operacional ou de qualidade.")
            )

        # Anexa a loja validada ao request para acesso rápido nas views
        request.parceiro_loja = loja
        return True

