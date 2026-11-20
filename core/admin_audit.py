"""
Módulo de Auditoria e Auto-Descoberta de Modelos Órfãos.
Delivery Pro — Governança e Controlo Total sobre Todas as Entidades do Banco de Dados.
"""
from __future__ import annotations

import logging
from typing import Set

from django.apps import apps
from django.contrib import admin

logger = logging.getLogger(__name__)

# Aplicações proprietárias do projeto sob governança estrita
LOCAL_APPS: Set[str] = {
    "accounts",
    "catalog",
    "orders",
    "logistics",
    "finance",
    "support",
    "promotions",
    "core",
}


def audit_and_register_orphaned_models() -> int:
    """
    Varre as aplicações do projeto.
    Identifica qualquer modelo de dados que não possua uma classe correspondente
    no Django Admin e efetua o registo automático via AutoMasterAdmin.
    
    Retorna a quantidade de modelos auto-registados.
    """
    from core.admin_base import AutoMasterAdmin

    all_models = apps.get_models()
    registered_models = set(admin.site._registry.keys())
    auto_registered_count = 0

    for model in all_models:
        meta = model._meta

        # Audita estritamente aplicações locais e modelos gerenciados
        if meta.app_label not in LOCAL_APPS or not meta.managed:
            continue

        if model not in registered_models:
            try:
                # Criar dinamicamente uma classe herdada de AutoMasterAdmin
                custom_admin_class = type(
                    f"Auto_{meta.app_label}_{meta.model_name}_Admin",
                    (AutoMasterAdmin,),
                    {},
                )
                admin.site.register(model, custom_admin_class)
                auto_registered_count += 1
                logger.warning(
                    f"[ADMIN AUDIT] Modelo '{meta.label}' registado automaticamente para controlo total."
                )
            except admin.sites.AlreadyRegistered:
                pass
            except Exception as exc:
                logger.error(
                    f"[ADMIN AUDIT] Falha ao auto-registar modelo '{meta.label}': {exc}"
                )

    if auto_registered_count > 0:
        logger.info(
            f"[ADMIN AUDIT] Auditoria concluída: {auto_registered_count} modelo(s) órfão(s) incorporado(s) à governança."
        )

    return auto_registered_count
