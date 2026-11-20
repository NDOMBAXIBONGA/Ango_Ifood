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
        return not SystemConfiguration.objects.exists()

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
        return f"{obj.taxa_base_entrega_aoa:,.2f} Kz"

    @admin.display(description="Valor / KM")
    def valor_km_formatado(self, obj: SystemConfiguration) -> str:
        return f"{obj.valor_km_entrega_aoa:,.2f} Kz/km"

    @admin.display(description="Comissão Marketplace")
    def comissao_marketplace_badge(self, obj: SystemConfiguration):
        return format_html(
            '<strong style="color: #2563eb;">{}%</strong>',
            obj.comissao_marketplace_percentagem,
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
    """

    list_display = (
        "plataforma",
        "versao_nome",
        "versao_codigo",
        "obrigatoria",
        "ativa",
        "criado_em",
    )
    list_filter = ("plataforma", "obrigatoria", "ativa")
    list_editable = ("obrigatoria", "ativa")
    search_fields = ("versao_nome", "versao_codigo", "notas_atualizacao")
    ordering = ("-versao_codigo", "-criado_em")

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
