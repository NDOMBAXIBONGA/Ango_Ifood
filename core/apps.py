"""
Configuração da Aplicação Core com Verificação Ativa de Governança na Inicialização.
"""
from __future__ import annotations

import logging
from django.apps import AppConfig

logger = logging.getLogger(__name__)


class CoreConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "core"
    verbose_name = "Governança e Controlo Central"

    def ready(self) -> None:
        """
        Executado quando o Django é inicializado.
        Garante que o autodiscover do admin é executado e realiza a varredura
        ativa para bloquear modelos órfãos fora do painel administrativo.
        """
        try:
            from django.contrib import admin
            # 1. Garante que todos os módulos admin.py de todas as apps foram descobertos
            admin.autodiscover()

            # 2. Executa a auditoria e incorpora qualquer modelo não registado
            from core.admin_audit import audit_and_register_orphaned_models
            audit_and_register_orphaned_models()
        except Exception as exc:
            logger.error(f"[CORE READY] Erro ao executar auditoria de governança do Admin: {exc}")
