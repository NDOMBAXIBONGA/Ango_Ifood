"""
Configuração do Django Admin para a aplicação 'support'.
Permite gerir Tickets de Suporte, Disputas de Pedidos e Parâmetros de Configuração Operacional.
"""
from django.contrib import admin
from django.utils.translation import gettext_lazy as _
from core.admin_base import MasterModelAdmin, display
from apps.support.models import Parametro, TicketDisputa


@admin.register(TicketDisputa)
class TicketDisputaAdmin(MasterModelAdmin):
    list_display = (
        "id_curto",
        "pedido",
        "utilizador_reclamante",
        "tipo_incidente",
        "prioridade_badge",
        "estado_badge",
        "decisao",
        "data_criacao",
    )
    list_filter = ("estado", "prioridade", "tipo_incidente", "decisao", "data_criacao")
    search_fields = (
        "id",
        "pedido__id",
        "pedido__cliente__nome",
        "pedido__cliente__telemovel",
        "motivo",
    )
    readonly_fields = ("id", "data_criacao", "data_atualizacao")
    ordering = ("-data_criacao",)

    @display(
        description=_("Prioridade"),
        label={
            "ALTA": "danger",
            "MEDIA": "warning",
            "BAIXA": "info",
        },
    )
    def prioridade_badge(self, obj: TicketDisputa) -> str:
        return obj.prioridade

    @display(
        description=_("Estado"),
        label={
            "ABERTO": "warning",
            "EM_ANALISE": "info",
            "RESOLVIDO": "success",
            "REJEITADO": "secondary",
        },
    )
    def estado_badge(self, obj: TicketDisputa) -> str:
        return obj.estado

    @admin.display(description="Ticket")
    def id_curto(self, obj: TicketDisputa) -> str:
        return f"TCK-{str(obj.id)[:8].upper()}"

    @admin.display(description="Cliente / Reclamante")
    def utilizador_reclamante(self, obj: TicketDisputa) -> str:
        try:
            if obj.pedido_id and obj.pedido and getattr(obj.pedido, "cliente", None):
                return obj.pedido.cliente.nome or obj.pedido.cliente.telemovel or "-"
        except Exception:
            pass
        return "-"


from django.utils.html import format_html
from django.contrib import messages
from apps.support.models import Parametro, ParametroHistorico, AppBannerDinamico, TicketDisputa


class ParametroHistoricoInline(admin.TabularInline):
    """Inline visual de histórico e auditoria de versões com snapshots anteriores."""
    model = ParametroHistorico
    extra = 0
    can_delete = False
    readonly_fields = ("versao", "alterado_por", "ip_origem", "motivo_alteracao", "snapshot_valor", "criado_em")
    ordering = ("-versao", "-criado_em")

    def has_add_permission(self, request, obj=None):
        return False


@admin.register(Parametro)
class ParametroAdmin(MasterModelAdmin):
    """
    Painel Central de Controlo de 100% dos Parâmetros do Sistema (Mobile & Web).
    Suporta branding, design system, textos, regras financeiras, flags e rollback.
    """
    list_display = (
        "categoria_badge",
        "chave",
        "tipo_badge",
        "valor_preview",
        "ambito",
        "versao_badge",
        "data_atualizacao",
    )
    list_filter = ("categoria", "tipo_dado", "ambito")
    search_fields = ("chave", "nome", "valor", "descricao", "regra_associada")
    ordering = ("categoria", "chave")
    inlines = [ParametroHistoricoInline]

    fieldsets = (
        (
            "📌 Identificação e Classificação Operacional",
            {
                "fields": (
                    "chave",
                    "nome",
                    "categoria",
                    "tipo_dado",
                    "ambito",
                    "regra_associada",
                ),
                "description": "Definição canónica do parâmetro e mapeamento funcional no ecossistema.",
            },
        ),
        (
            "🎛️ Valor e Configuração Dinâmica (Server-Driven)",
            {
                "fields": (
                    "valor",
                    "valor_numerico",
                    "valor_booleano",
                    "valor_json",
                    "ficheiro_asset",
                    "unidade",
                ),
                "description": "Preencha o campo correspondente ao 'Tipo de Dado' escolhido acima.",
            },
        ),
        (
            "📅 Vigência, Prazos e Governança",
            {
                "fields": (
                    "descricao",
                    "vigencia_inicio",
                    "vigencia_fim",
                    "versao",
                    "autor",
                ),
            },
        ),
    )

    def save_model(self, request, obj, form, change):
        """Gera automaticamente um snapshot imutável na tabela ParametroHistorico a cada alteração."""
        if change:
            try:
                antigo = Parametro.objects.get(pk=obj.pk)
                snapshot = {
                    "valor": antigo.valor,
                    "valor_numerico": str(antigo.valor_numerico) if antigo.valor_numerico else None,
                    "valor_booleano": antigo.valor_booleano,
                    "valor_json": antigo.valor_json,
                    "tipo_dado": antigo.tipo_dado,
                    "categoria": antigo.categoria,
                }
                obj.versao = (antigo.versao or 1) + 1
                obj.autor = str(request.user) if request.user.is_authenticated else "Admin"

                ip_cliente = request.META.get("HTTP_X_FORWARDED_FOR", request.META.get("REMOTE_ADDR", "127.0.0.1")).split(",")[0].strip()
                ParametroHistorico.objects.create(
                    parametro=obj,
                    versao=antigo.versao,
                    snapshot_valor=snapshot,
                    alterado_por=str(request.user),
                    ip_origem=ip_cliente,
                    motivo_alteracao=f"Edição via Django Admin: {', '.join(form.changed_data)}" if form.changed_data else "Edição manual",
                )
            except Exception as e:
                import logging
                logging.getLogger(__name__).warning("Falha ao registar histórico do parâmetro: %s", e)

        super().save_model(request, obj, form, change)

    @admin.display(description="Categoria")
    def categoria_badge(self, obj: Parametro):
        cores = {
            "BRANDING": "#8b5cf6",
            "DESIGN_SYSTEM": "#ec4899",
            "TEXTOS_CMS": "#0284c7",
            "FINANCAS_TAXAS": "#10b981",
            "LOGISTICA": "#f59e0b",
            "FEATURE_FLAGS": "#ef4444",
            "OUTRO": "#6b7280",
        }
        cor = cores.get(obj.categoria, "#6b7280")
        return format_html(
            '<span style="background-color: {}; color: white; padding: 3px 8px; border-radius: 6px; font-weight: bold; font-size: 11px;">{}</span>',
            cor,
            obj.get_categoria_display(),
        )

    @admin.display(description="Tipo")
    def tipo_badge(self, obj: Parametro):
        return format_html(
            '<span style="background-color: #f1f5f9; color: #334155; border: 1px solid #cbd5e1; padding: 2px 6px; border-radius: 4px; font-size: 11px; font-family: monospace;">{}</span>',
            obj.tipo_dado,
        )

    @admin.display(description="Valor Ativo")
    def valor_preview(self, obj: Parametro):
        try:
            if obj.tipo_dado == Parametro.TipoDado.COLOR_HEX and obj.valor and str(obj.valor).strip().startswith("#"):
                clean_hex = str(obj.valor).strip()
                return format_html(
                    '<div style="display: flex; align-items: center; gap: 6px;">'
                    '<span style="width: 14px; height: 14px; border-radius: 50%; background-color: {}; border: 1px solid #cbd5e1; display: inline-block;"></span>'
                    '<code>{}</code></div>',
                    clean_hex,
                    clean_hex,
                )
            elif obj.tipo_dado == Parametro.TipoDado.BOOLEAN:
                val = obj.get_valor_resolvido()
                return format_html(
                    '<span style="color: {}; font-weight: bold;">{}</span>',
                    "#16a34a" if val else "#dc2626",
                    "✔ Ativo" if val else "✖ Inativo",
                )
            elif obj.tipo_dado == Parametro.TipoDado.FILE_ASSET:
                try:
                    if obj.ficheiro_asset and hasattr(obj.ficheiro_asset, "url"):
                        return format_html(
                            '<a href="{}" target="_blank" style="color: #2563eb; text-decoration: underline;">Visualizar Ficheiro</a>',
                            obj.ficheiro_asset.url,
                        )
                except (ValueError, Exception):
                    pass
            val_resolvido = obj.get_valor_resolvido()
            res = str(val_resolvido) if val_resolvido is not None else ""
            if len(res) > 40:
                return res[:37] + "..."
            return res or "-"
        except Exception:
            return str(obj.valor or "-")

    @admin.display(description="Versão")
    def versao_badge(self, obj: Parametro):
        return format_html('<strong>v{}</strong>', obj.versao)


@admin.register(ParametroHistorico)
class ParametroHistoricoAdmin(MasterModelAdmin):
    """Auditoria imutável com capacidade de reversão em 1 clique."""
    list_display = ("parametro", "versao", "alterado_por", "ip_origem", "motivo_alteracao", "criado_em")
    list_filter = ("alterado_por", "parametro__categoria")
    search_fields = ("parametro__chave", "alterado_por", "motivo_alteracao")
    readonly_fields = ("parametro", "versao", "snapshot_valor", "alterado_por", "ip_origem", "motivo_alteracao", "criado_em")
    actions = ["reverter_para_snapshot"]

    def has_add_permission(self, request):
        return False

    @admin.action(description="⏪ Reverter Parâmetro Selecionado para este Snapshot")
    def reverter_para_snapshot(self, request, queryset):
        total = 0
        for historico in queryset:
            historico.reverter(utilizador_solicitante=str(request.user))
            total += 1
        self.message_user(
            request,
            f"Sucesso: {total} parâmetro(s) revertido(s) com sucesso para os valores do snapshot histórico.",
            level=messages.SUCCESS,
        )


@admin.register(AppBannerDinamico)
class AppBannerDinamicoAdmin(MasterModelAdmin):
    """Painel de Gestão e Publicação de Banners e Pop-ups Dinâmicos."""
    list_display = (
        "preview_banner",
        "titulo",
        "tipo_banner_badge",
        "publico_alvo_badge",
        "ativo",
        "ordem",
        "inicio_vigencia",
        "fim_vigencia",
    )
    list_filter = ("tipo_banner", "publico_alvo", "ativo")
    list_editable = ("ativo", "ordem")
    search_fields = ("titulo", "subtitulo", "deeplink")
    ordering = ("ordem", "-criado_em")

    fieldsets = (
        (
            "🖼️ Conteúdo Visual e Ação",
            {
                "fields": (
                    "titulo",
                    "subtitulo",
                    "imagem",
                    "imagem_url_externa",
                    "deeplink",
                ),
                "description": "Textos, imagem e rota de navegação acionada ao tocar no banner.",
            },
        ),
        (
            "🎯 Segmentação e Apresentação",
            {
                "fields": (
                    "tipo_banner",
                    "publico_alvo",
                    "cor_fundo_hex",
                    "cor_texto_hex",
                    "ordem",
                    "ativo",
                ),
            },
        ),
        (
            "📅 Período de Vigência",
            {
                "fields": ("inicio_vigencia", "fim_vigencia"),
            },
        ),
    )

    @admin.display(description="Miniatura")
    def preview_banner(self, obj: AppBannerDinamico):
        url = obj.url_imagem_final
        if url:
            return format_html(
                '<img src="{}" style="width: 70px; height: 35px; object-fit: cover; border-radius: 6px; border: 1px solid #e2e8f0;" />',
                url,
            )
        return format_html(
            '<div style="width: 70px; height: 35px; border-radius: 6px; background-color: {}; color: {}; display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: bold;">BANNER</div>',
            obj.cor_fundo_hex or "#EA1D2C",
            obj.cor_texto_hex or "#FFFFFF",
        )

    @admin.display(description="Tipo de Exibição")
    def tipo_banner_badge(self, obj: AppBannerDinamico):
        cores = {
            "HOME_CAROUSEL": "#2563eb",
            "TOP_BAR_AVISO": "#f59e0b",
            "POPUP_MODAL": "#dc2626",
        }
        return format_html(
            '<span style="background-color: {}; color: white; padding: 2px 7px; border-radius: 4px; font-size: 11px; font-weight: bold;">{}</span>',
            cores.get(obj.tipo_banner, "#64748b"),
            obj.get_tipo_banner_display(),
        )

    @admin.display(description="Público-Alvo")
    def publico_alvo_badge(self, obj: AppBannerDinamico):
        return format_html(
            '<span style="background-color: #f1f5f9; color: #0f172a; border: 1px solid #cbd5e1; padding: 2px 6px; border-radius: 4px; font-size: 11px;">{}</span>',
            obj.get_publico_alvo_display(),
        )
