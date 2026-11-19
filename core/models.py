"""
Modelos Centrais de Governança, Auditoria e Configuração Global do Sistema.
Delivery Pro — Gestão Dinâmica sem Necessidade de Reiniciar Servidor.
"""
from __future__ import annotations

import logging
from decimal import Decimal
from typing import Any

from django.conf import settings
from django.core.cache import cache
from django.db import models

logger = logging.getLogger(__name__)

CACHE_SYSTEM_CONFIG_KEY = "system_configuration_global_v1"
CACHE_SYSTEM_CONFIG_TIMEOUT = 300  # 5 minutos


class AuditedModel(models.Model):
    """
    Classe base abstrata para modelos que exigem trilha de auditoria completa,
    rastreabilidade de autoria e suporte a exclusão lógica (Soft Delete).
    """
    criado_em = models.DateTimeField(
        auto_now_add=True,
        verbose_name="Criado em",
        help_text="Data e hora exata da inserção no banco de dados.",
    )
    atualizado_em = models.DateTimeField(
        auto_now=True,
        verbose_name="Atualizado em",
        help_text="Data e hora da última mutação de dados.",
    )
    is_active = models.BooleanField(
        default=True,
        db_index=True,
        verbose_name="Ativo / Não Excluído",
        help_text="Desmarque para exclusão lógica. Preserva a integridade relacional e fiscal.",
    )
    criado_por = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="%(app_label)s_%(class)s_criados",
        verbose_name="Criado por",
    )
    atualizado_por = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="%(app_label)s_%(class)s_atualizados",
        verbose_name="Atualizado por",
    )

    class Meta:
        abstract = True


class SystemConfiguration(models.Model):
    """
    Configuração Global do Sistema (Padrão Singleton).
    Permite que o Superadministrador configure taxas, regras de frete,
    comissões e Feature Flags diretamente pelo Django Admin em tempo real.
    """
    # -------------------------------------------------------------------------
    # 1. PARÂMETROS DE LOGÍSTICA & FRETE (ANGOLA - AOA)
    # -------------------------------------------------------------------------
    taxa_base_entrega_aoa = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("500.00"),
        verbose_name="Taxa Base de Entrega (AOA)",
        help_text="Tarifa inicial de partida cobrada ao cliente.",
    )
    valor_km_entrega_aoa = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("150.00"),
        verbose_name="Valor por KM de Entrega (AOA/km)",
        help_text="Valor cobrado por cada quilómetro percorrido.",
    )
    fator_correcao_urbana = models.FloatField(
        default=1.30,
        verbose_name="Fator de Correção Urbana (Fallback)",
        help_text="Multiplicador sobre distância em linha reta caso o OSRM esteja indisponível.",
    )
    raio_maximo_entrega_km = models.DecimalField(
        max_digits=6,
        decimal_places=2,
        default=Decimal("25.00"),
        verbose_name="Raio Máximo de Entrega (KM)",
        help_text="Distância viária máxima permitida para despacho de corridas.",
    )
    tempo_tolerancia_estafeta_minutos = models.PositiveIntegerField(
        default=7,
        verbose_name="Tolerância de Espera do Estafeta (Minutos)",
        help_text="Tempo que o estafeta deve aguardar no local antes de reportar ausência (RN-096).",
    )

    # -------------------------------------------------------------------------
    # 2. PARÂMETROS DE MARKETPLACE & MONETIZAÇÃO
    # -------------------------------------------------------------------------
    comissao_marketplace_percentagem = models.DecimalField(
        max_digits=5,
        decimal_places=2,
        default=Decimal("12.00"),
        verbose_name="Comissão do Marketplace (%)",
        help_text="Percentual retido pela plataforma sobre as vendas das lojas parceiras.",
    )
    taxa_servico_fixa_aoa = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("100.00"),
        verbose_name="Taxa de Serviço Fixa por Pedido (AOA)",
        help_text="Tarifa operacional cobrada ao consumidor final por cada pedido submetido.",
    )
    valor_minimo_saque_aoa = models.DecimalField(
        max_digits=10,
        decimal_places=2,
        default=Decimal("2000.00"),
        verbose_name="Valor Mínimo para Saque (AOA)",
        help_text="Montante mínimo acumulado na carteira para solicitar repasse bancário.",
    )

    # -------------------------------------------------------------------------
    # 3. FEATURE FLAGS OPERACIONAIS (TEMPO REAL)
    # -------------------------------------------------------------------------
    entregas_ativas = models.BooleanField(
        default=True,
        verbose_name="Entregas Ativas no Sistema",
        help_text="Se desativado, o marketplace pausa temporariamente novos pedidos com frete.",
    )
    modo_manutencao = models.BooleanField(
        default=False,
        verbose_name="Modo de Manutenção Ativo",
        help_text="Interrompe o fluxo transacional de clientes para manutenções programadas.",
    )
    mensagem_manutencao = models.CharField(
        max_length=255,
        default="A plataforma está em manutenção temporária para melhorias operacionais. Voltamos em breve!",
        verbose_name="Mensagem de Manutenção",
    )
    permitir_pagamento_dinheiro = models.BooleanField(
        default=True,
        verbose_name="Permitir Dinheiro (Cash on Delivery)",
        help_text="Permite ao cliente pagar em numerário no ato da entrega.",
    )
    permitir_pagamento_multicaixa_express = models.BooleanField(
        default=True,
        verbose_name="Permitir Multicaixa Express (MCX)",
        help_text="Habilita pagamentos eletrónicos via Gateway EMIS / MCX.",
    )
    permitir_pagamento_carteira = models.BooleanField(
        default=True,
        verbose_name="Permitir Saldo em Carteira Digital",
        help_text="Permite debitar do saldo interno pré-carregado.",
    )
    exigir_pin_entrega = models.BooleanField(
        default=True,
        verbose_name="Exigir PIN de Entrega (RN-095)",
        help_text="Exige que o cliente forneça o código de 4 dígitos ao estafeta para finalizar o pedido.",
    )

    # -------------------------------------------------------------------------
    # 4. METADADOS E AUDITORIA DO SINGLETON
    # -------------------------------------------------------------------------
    atualizado_em = models.DateTimeField(
        auto_now=True,
        verbose_name="Última Atualização",
    )
    atualizado_por = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        verbose_name="Atualizado por",
    )

    class Meta:
        verbose_name = "Configuração Global do Sistema"
        verbose_name_plural = "Configuração Global do Sistema"

    def __str__(self) -> str:
        return f"Configurações Globais (Ativação: {'Manutenção' if self.modo_manutencao else 'Operacional'})"

    def save(self, *args: Any, **kwargs: Any) -> None:
        """Garante que apenas 1 registo (Singleton, pk=1) exista na base de dados."""
        self.pk = 1
        super().save(*args, **kwargs)
        # Invalidação imediata do cache para propagação instantânea a todos os workers
        cache.delete(CACHE_SYSTEM_CONFIG_KEY)
        logger.info("[GOVERNANCE] Configurações do sistema atualizadas e cache invalidado.")

    def delete(self, *args: Any, **kwargs: Any) -> tuple[int, dict[str, int]]:
        """Impede a eliminação do Singleton."""
        logger.warning("[GOVERNANCE] Tentativa de eliminação bloqueada para SystemConfiguration.")
        return 0, {}

    @classmethod
    def get_settings(cls) -> "SystemConfiguration":
        """
        Retorna as configurações do sistema com cache em memória (Redis).
        Se ainda não existir no banco, cria o registo com os valores padrão.
        """
        config = cache.get(CACHE_SYSTEM_CONFIG_KEY)
        if config is not None:
            return config

        config, _ = cls.objects.get_or_create(pk=1)
        cache.set(CACHE_SYSTEM_CONFIG_KEY, config, timeout=CACHE_SYSTEM_CONFIG_TIMEOUT)
        return config
