"""
Inicialização do Celery para o projeto Django.
"""
import os
from celery import Celery

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

app = Celery("delivery")

# Lê todas as chaves com o prefixo 'CELERY_' a partir do settings.py
app.config_from_object("django.conf:settings", namespace="CELERY")

# Descobre automaticamente tasks.py em todas as INSTALLED_APPS
app.autodiscover_tasks()
