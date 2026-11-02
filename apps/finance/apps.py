"""
Configuração da aplicação 'finance' do Django.
"""
from django.apps import AppConfig
from django.utils.translation import gettext_lazy as _


class FinanceConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.finance"
    verbose_name = _("Finanças, Auditoria e Livro Razão (Ledger)")

