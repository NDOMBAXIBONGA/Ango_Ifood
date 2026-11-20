#!/usr/bin/env python
"""Utilitário de linha de comandos do Django para tarefas administrativas."""
import os
import sys


def main() -> None:
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")
    # Compatibilidade GeoDjango/GDAL automática no Windows (permite createsuperuser, migrate, runserver)
    try:
        from core.windows_gdal_shim import ensure_gdal_compatibility
        ensure_gdal_compatibility()
    except Exception:
        pass

    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc:
        raise ImportError(
            "Não foi possível importar o Django. Tem a certeza de que está instalado e "
            "disponível na variável de ambiente PYTHONPATH? Esqueceu-se de ativar o ambiente virtual?"
        ) from exc
    execute_from_command_line(sys.argv)


if __name__ == "__main__":
    main()
