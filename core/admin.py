"""
Admin para Configurações Globais do Sistema (SystemConfiguration).
Delivery Pro — Painel de Gestão Dinâmica em Tempo Real.
"""
from __future__ import annotations

from typing import Any, Optional

from django.contrib import admin
from django.http import HttpRequest
from django.utils.html import format_html

from core.admin_base import MasterModelAdmin
from core.models import AppVersion, SystemConfiguration


@admin.register(SystemConfiguration)
class SystemConfigurationAdmin(MasterModelAdmin):
    """
    Administração da Configuração Global do Sistema.
    Controlo de Regras de Negócio e Feature Flags sem alteração de código.
    """
    protected_from_deletion = True
    enable_soft_delete = False

    list_display = (
        "status_operacional_badge",
        "taxa_base_formatada",
        "valor_km_formatado",
        "comissao_marketplace_badge",
        "entregas_status_badge",
        "atualizado_em",
        "atualizado_por",
    )

    readonly_fields = ("atualizado_em", "atualizado_por")

    fieldsets = (
        (
            "🛑 Estado Global da Plataforma & Manutenção",
            {
                "fields": (
                    "modo_manutencao",
                    "mensagem_manutencao",
                    "entregas_ativas",
                ),
                "description": "Ative o modo de manutenção para bloquear novas transações durante manutenções planeadas.",
            },
        ),
        (
            "🛵 Logística e Regras de Frete (AOA - Kwanzas)",
            {
                "fields": (
                    "taxa_base_entrega_aoa",
                    "valor_km_entrega_aoa",
                    "fator_correcao_urbana",
                    "raio_maximo_entrega_km",
                    "tempo_tolerancia_estafeta_minutos",
                    "exigir_pin_entrega",
                ),
                "description": "Parâmetros aplicados dinamicamente no cálculo da API OSRM e tolerância operacional do estafeta.",
            },
        ),
        (
            "💰 Marketplace e Monetização",
            {
                "fields": (
                    "comissao_marketplace_percentagem",
                    "taxa_servico_fixa_aoa",
                    "valor_minimo_saque_aoa",
                ),
                "description": "Comissões retidas nas vendas e limites financeiros de repasse para parceiros.",
            },
        ),
        (
            "💳 Métodos de Pagamento Habilitados (Feature Flags)",
            {
                "fields": (
                    "permitir_pagamento_dinheiro",
                    "permitir_pagamento_multicaixa_express",
                    "permitir_pagamento_carteira",
                ),
                "description": "Ligue ou desligue gateways de pagamento em tempo real.",
            },
        ),
        (
            "🕒 Auditoria de Governança",
            {
                "fields": ("atualizado_em", "atualizado_por"),
                "classes": ("collapse",),
            },
        ),
    )

    def has_add_permission(self, request: HttpRequest) -> bool:
        """Padrão Singleton: Não permite criar mais de uma instância de configuração."""
        try:
            return not SystemConfiguration.objects.exists()
        except Exception:
            return False

    def has_delete_permission(self, request: HttpRequest, obj: Optional[Any] = None) -> bool:
        """A configuração mestre do sistema nunca pode ser apagada."""
        return False

    @admin.display(description="Status Operacional")
    def status_operacional_badge(self, obj: SystemConfiguration):
        if obj.modo_manutencao:
            return format_html(
                '<span style="background-color: #ef4444; color: white; padding: 4px 10px; border-radius: 9999px; font-weight: bold; font-size: 11px;">🛠️ MANUTENÇÃO ATIVA</span>'
            )
        return format_html(
            '<span style="background-color: #22c55e; color: white; padding: 4px 10px; border-radius: 9999px; font-weight: bold; font-size: 11px;">🟢 OPERACIONAL</span>'
        )

    @admin.display(description="Taxa Base")
    def taxa_base_formatada(self, obj: SystemConfiguration) -> str:
        if obj.taxa_base_entrega_aoa is not None:
            try:
                return f"{obj.taxa_base_entrega_aoa:,.2f} Kz"
            except (ValueError, TypeError):
                return f"{obj.taxa_base_entrega_aoa} Kz"
        return "0,00 Kz"

    @admin.display(description="Valor / KM")
    def valor_km_formatado(self, obj: SystemConfiguration) -> str:
        if obj.valor_km_entrega_aoa is not None:
            try:
                return f"{obj.valor_km_entrega_aoa:,.2f} Kz/km"
            except (ValueError, TypeError):
                return f"{obj.valor_km_entrega_aoa} Kz/km"
        return "0,00 Kz/km"

    @admin.display(description="Comissão Marketplace")
    def comissao_marketplace_badge(self, obj: SystemConfiguration):
        val = obj.comissao_marketplace_percentagem if obj.comissao_marketplace_percentagem is not None else 0
        return format_html(
            '<strong style="color: #2563eb;">{}%</strong>',
            val,
        )

    @admin.display(description="Entregas Ativas")
    def entregas_status_badge(self, obj: SystemConfiguration):
        if obj.entregas_ativas:
            return format_html('<span style="color: #16a34a; font-weight: bold;">✔ Ativas</span>')
        return format_html('<span style="color: #dc2626; font-weight: bold;">✖ Pausadas</span>')


# ==============================================================================
# 2. ADMINISTRAÇÃO DE VERSÕES MÓVEIS (OTA / KILL SWITCH)
# ==============================================================================
@admin.register(AppVersion)
class AppVersionAdmin(MasterModelAdmin):
    """
    Painel de Gestão e Publicação de Versões Móveis (Android APK & iOS IPA).
    Suporta Kill Switch remoto (atualizações forçadas) e gestão de links OTA.
    Resiliente a campos nulos ou vazios.
    """

    list_display = (
        "plataforma_badge",
        "versao_nome_display",
        "versao_codigo_display",
        "obrigatoria",
        "ativa",
        "criado_em",
    )
    list_filter = ("plataforma", "obrigatoria", "ativa")
    list_editable = ("obrigatoria", "ativa")
    search_fields = ("versao_nome", "versao_codigo", "notas_atualizacao")
    ordering = ("-versao_codigo", "-criado_em")

    @admin.display(description="Plataforma")
    def plataforma_badge(self, obj: AppVersion):
        plat = obj.plataforma or "App"
        cor = "#16a34a" if plat == "ANDROID" else ("#0284c7" if plat == "IOS" else "#64748b")
        return format_html(
            '<span style="background-color: {}; color: white; padding: 3px 8px; border-radius: 6px; font-weight: bold; font-size: 11px;">{}</span>',
            cor,
            plat,
        )

    @admin.display(description="Versão")
    def versao_nome_display(self, obj: AppVersion):
        return obj.versao_nome or "1.0.0"

    @admin.display(description="Build")
    def versao_codigo_display(self, obj: AppVersion):
        return obj.versao_codigo if obj.versao_codigo is not None else 1

    fieldsets = (
        (
            "📱 Informações da Versão",
            {
                "fields": (
                    "plataforma",
                    "versao_nome",
                    "versao_codigo",
                    "notas_atualizacao",
                ),
                "description": "Dados da build da aplicação (nome semântico e número incremental de build).",
            },
        ),
        (
            "📦 Ficheiros e Links de Download",
            {
                "fields": (
                    "ficheiro_instalacao",
                    "url_pagina_web",
                ),
                "description": "Upload direto do ficheiro (.apk para Android ou .ipa para iOS) ou link alternativo de distribuição.",
            },
        ),
        (
            "🛑 Controlo de Bloqueio (Kill Switch)",
            {
                "fields": (
                    "obrigatoria",
                    "ativa",
                ),
                "description": "Ative 'Obrigatória' para ativar o modo Kill Switch e impedir a execução de versões legadas.",
            },
        ),
    )
