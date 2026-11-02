from django.apps import AppConfig
from django.utils.translation import gettext_lazy as _


class LogisticsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.logistics"
    label = "logistics"
    verbose_name = _("Despacho, Estafetas e Logística")
