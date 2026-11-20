"""
Classe Base Obrigatória de Governança e Auditoria para o Django Admin.
Delivery Pro — Controlo Total, Otimização de Performance e Prevenção de Fraudes.
"""
from __future__ import annotations

import csv
import logging
from datetime import datetime
from typing import Any, List, Optional, Sequence

from django.contrib import admin, messages
from django.contrib.admin.models import CHANGE, DELETION, LogEntry
from django.contrib.contenttypes.models import ContentType
from django.core.exceptions import PermissionDenied
from django.db import models
from django.http import HttpRequest, HttpResponse
from django.utils import timezone
from django.utils.encoding import force_str

logger = logging.getLogger(__name__)


def get_client_ip(request: HttpRequest) -> str:
    """Extrai o IP real do cliente mesmo por trás de proxies reversos (Nginx/Cloudflare)."""
    x_forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR")
    if x_forwarded_for:
        return x_forwarded_for.split(",")[0].strip()
    return request.META.get("REMOTE_ADDR", "0.0.0.0")


class MasterModelAdmin(admin.ModelAdmin):
    """
    Classe Administrativa Base Obrigatória para todas as entidades do sistema.
    
    Funcionalidades Nativas:
    1. Auditoria Automática de Alterações com IP e Identidade.
    2. Bloqueio de Exclusão Destrutiva em Modelos Críticos (Soft Delete).
    3. Otimização de Consultas (list_select_related, show_full_result_count).
    4. Exportação Padronizada para CSV com suporte nativo a caracteres especiais (UTF-8 com BOM).
    """
    # Performance padrão para bases de dados em crescimento rápido
    list_per_page = 30
    show_full_result_count = False

    # Flag de Proteção contra Perda Acidental de Dados
    protected_from_deletion: bool = False
    enable_soft_delete: bool = True

    # Ações globais disponíveis em todas as tabelas
    actions = ["export_to_csv"]

    def get_actions(self, request: HttpRequest) -> dict:
        """Bloqueia a ação massiva 'delete_selected' em modelos com proteção de integridade."""
        actions = super().get_actions(request)
        if self.protected_from_deletion:
            if "delete_selected" in actions:
                del actions["delete_selected"]
        return actions

    def has_delete_permission(self, request: HttpRequest, obj: Optional[Any] = None) -> bool:
        """Impede a eliminação física de registos protegidos (financeiros, pedidos, logs)."""
        if self.protected_from_deletion:
            return False
        return super().has_delete_permission(request, obj)

    def save_model(self, request: HttpRequest, obj: Any, form: Any, change: bool) -> None:
        """
        Trilha de Auditoria: Atribui automaticamente autoria e regista no LogEntry do Django
        a mutação detalhada com o endereço IP do administrador.
        """
        user = request.user if request.user.is_authenticated else None

        if hasattr(obj, "atualizado_por"):
            obj.atualizado_por = user
        if not change and hasattr(obj, "criado_por"):
            obj.criado_por = user

        ip_addr = get_client_ip(request)
        logger.info(
            f"[ADMIN AUDIT] Mutação em {self.model._meta.label} (ID: {getattr(obj, 'pk', 'Novo')}) "
            f"por {user} a partir do IP {ip_addr} (Ação: {'Edição' if change else 'Criação'})."
        )

        super().save_model(request, obj, form, change)

        # Registo de LogEntry detalhado com IP
        try:
            modificacoes = []
            if change and form.changed_data:
                for field_name in form.changed_data:
                    modificacoes.append(f"{field_name}: '{form.cleaned_data.get(field_name)}'")
            detalhe = f"[IP: {ip_addr}] " + (f"Campos: {', '.join(modificacoes)}" if modificacoes else "Registo guardado.")

            LogEntry.objects.log_action(
                user_id=request.user.pk,
                content_type_id=ContentType.objects.get_for_model(self.model).pk,
                object_id=str(obj.pk),
                object_repr=force_str(obj)[:200],
                action_flag=CHANGE,
                change_message=detalhe,
            )
        except Exception as exc:
            logger.warning(f"[ADMIN AUDIT] Falha ao gravar LogEntry: {exc}")

    def delete_model(self, request: HttpRequest, obj: Any) -> None:
        """
        Soft Delete Automatizado: Em vez de apagar os dados da base de dados,
        desativa o registo (is_active = False) se o modelo suportar esta coluna.
        """
        if self.protected_from_deletion:
            raise PermissionDenied("Este registo é protegido contra exclusão para fins de auditoria e conformidade fiscal.")

        ip_addr = get_client_ip(request)
        if self.enable_soft_delete and hasattr(obj, "is_active"):
            obj.is_active = False
            if hasattr(obj, "atualizado_por"):
                obj.atualizado_por = request.user
            obj.save(update_fields=["is_active", "atualizado_por"] if hasattr(obj, "atualizado_por") else ["is_active"])

            logger.warning(
                f"[ADMIN AUDIT] Exclusão LÓGICA (Soft Delete) em {self.model._meta.label} "
                f"(ID: {obj.pk}) por {request.user} a partir do IP {ip_addr}."
            )
            messages.warning(request, f"Registo #{obj.pk} desativado com sucesso (Soft Delete preservado).")

            try:
                LogEntry.objects.log_action(
                    user_id=request.user.pk,
                    content_type_id=ContentType.objects.get_for_model(self.model).pk,
                    object_id=str(obj.pk),
                    object_repr=force_str(obj)[:200],
                    action_flag=DELETION,
                    change_message=f"[IP: {ip_addr}] Exclusão Lógica (is_active=False).",
                )
            except Exception:
                pass
        else:
            logger.warning(
                f"[ADMIN AUDIT] Exclusão FÍSICA em {self.model._meta.label} (ID: {obj.pk}) "
                f"por {request.user} a partir do IP {ip_addr}."
            )
            super().delete_model(request, obj)

    @admin.action(description="📥 Exportar Registos Selecionados para CSV (Excel/Sheets)")
    def export_to_csv(self, request: HttpRequest, queryset: models.QuerySet) -> HttpResponse:
        """
        Gera um ficheiro CSV estruturado com codificação UTF-8 com BOM (\ufeff),
        garantindo abertura correta de carateres angolanos/portugueses no Excel e LibreOffice.
        """
        meta = self.model._meta
        timestamp = timezone.now().strftime("%Y%m%d_%H%M%S")
        filename = f"{meta.app_label}_{meta.model_name}_export_{timestamp}.csv"

        response = HttpResponse(content_type="text/csv; charset=utf-8")
        response["Content-Disposition"] = f'attachment; filename="{filename}"'

        # UTF-8 BOM para garantir correta exibição de acentos no Microsoft Excel
        response.write("\ufeff".encode("utf-8"))

        writer = csv.writer(response, delimiter=";", quoting=csv.QUOTE_MINIMAL)

        # Determina os campos a exportar
        field_names = [field.name for field in meta.fields if not field.is_relation and "password" not in field.name]
        headers = [meta.get_field(f).verbose_name.title() for f in field_names]
        writer.writerow(headers)

        for obj in queryset:
            row = []
            for field in field_names:
                val = getattr(obj, field, "")
                if isinstance(val, datetime):
                    val = val.strftime("%Y-%m-%d %H:%M:%S")
                elif val is None:
                    val = ""
                row.append(str(val))
            writer.writerow(row)

        logger.info(f"[ADMIN EXPORT] Utilizador {request.user} exportou {queryset.count()} linhas de {meta.label}.")
        return response


class ImmutableFinancialAdmin(MasterModelAdmin):
    """
    Especialização para Registos Financeiros e Ledger (Livro-Razão).
    Imutabilidade garantida: Proíbe edições diretas e exclusões físicas.
    """
    protected_from_deletion = True
    enable_soft_delete = False

    def has_add_permission(self, request: HttpRequest) -> bool:
        """Lançamentos no ledger devem ser gerados pelas transações de negócio ou ações auditadas."""
        return request.user.is_superuser

    def has_change_permission(self, request: HttpRequest, obj: Optional[Any] = None) -> bool:
        """Registos financeiros são somente leitura (Read-Only) para prevenir fraudes contábeis."""
        return False

    def get_readonly_fields(self, request: HttpRequest, obj: Optional[Any] = None) -> Sequence[str]:
        """Todos os campos do modelo passam a ser estritamente de visualização."""
        return [f.name for f in self.model._meta.fields]


class AutoMasterAdmin(MasterModelAdmin):
    """
    Administrador Gerado Automaticamente para qualquer Modelo Órfão detetado.
    Garante visibilidade instantânea sem deixar nenhuma tabela fora da supervisão do admin.
    Utiliza métodos dinâmicos de runtime para garantir conformidade total com o system check do Django.
    """
    list_display = ("__str__",)
    list_filter = ()
    search_fields = ()

    def get_list_display(self, request: HttpRequest) -> Sequence[str]:
        campos = [
            f.name
            for f in self.model._meta.fields
            if not f.is_relation and "password" not in f.name and "secret" not in f.name
        ]
        return tuple(campos[:7]) or ("__str__",)

    def get_list_filter(self, request: HttpRequest) -> Sequence[str]:
        filtros = [
            f.name
            for f in self.model._meta.fields
            if isinstance(f, (models.BooleanField, models.DateField, models.DateTimeField))
        ]
        return tuple(filtros[:3])

    def get_search_fields(self, request: HttpRequest) -> Sequence[str]:
        buscas = [
            f.name
            for f in self.model._meta.fields
            if isinstance(f, (models.CharField, models.EmailField, models.UUIDField))
        ]
        return tuple(buscas[:3])
