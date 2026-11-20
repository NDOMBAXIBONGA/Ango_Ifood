# Garante compatibilidade do GeoDjango/GDAL no Windows para migrações e comandos locais
try:
    from core.windows_gdal_shim import ensure_gdal_compatibility
    ensure_gdal_compatibility()
except Exception:
    pass

# Importa a app Celery sempre que o módulo celery estiver instalado no ambiente (virtualenv).
# Evita crash de ModuleNotFoundError caso o Celery ainda esteja em processo de instalação.
try:
    from .celery import app as celery_app
    __all__ = ("celery_app",)
except ImportError:
    celery_app = None
    __all__ = ()

