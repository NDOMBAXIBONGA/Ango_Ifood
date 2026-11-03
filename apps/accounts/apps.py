from django.apps import AppConfig
from django.utils.translation import gettext_lazy as _


class AccountsConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "apps.accounts"
    label = "accounts"
    verbose_name = _("Gestão de Contas e Identidade")

    def ready(self):
        import sys
        # Não executa se estiver num comando CLI administrativo como migrate, makemigrations ou collectstatic
        cmd = " ".join(sys.argv)
        if "migrate" in cmd or "makemigrations" in cmd or "collectstatic" in cmd:
            return

        try:
            from django.core.management import call_command
            from django.db import connection
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'accounts_custom_user';"
                )
                existe = cursor.fetchone()[0]
            if not existe:
                import logging
                logging.getLogger(__name__).info("Tabelas ausentes no PostgreSQL. A aplicar migrações no arranque...")
                call_command("migrate", interactive=False)
        except Exception:
            pass
