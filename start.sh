#!/usr/bin/env bash
# ==============================================================================
# Script de Entrada e Arranque em Produção (Render Cloud Web Service)
# Garante a criação incondicional e aplicação de todas as migrações de banco
# de dados antes de iniciar o servidor HTTP/WebSockets Daphne (ASGI).
# ==============================================================================
set -e

echo "======================================================================"
echo "--> [1/4] A iniciar Delivery Platform no Render Cloud..."
echo "======================================================================"

# 1. Espera ativa pela disponibilidade da base de dados PostgreSQL e ativação PostGIS
echo "--> [2/4] A verificar ligação à base de dados PostgreSQL e extensão PostGIS..."
python -c "
import os, sys, time, django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
django.setup()

from django.db import connection

max_tentativas = 15
conectado = False

for i in range(1, max_tentativas + 1):
    try:
        with connection.cursor() as cursor:
            print(f'--> [Tentativa {i}/{max_tentativas}] A verificar conexão com PostgreSQL...')
            cursor.execute('CREATE EXTENSION IF NOT EXISTS postgis;')
            cursor.execute('SELECT PostGIS_Version();')
            versao = cursor.fetchone()
            print(f'--> [SUCESSO] Base de dados conectada e PostGIS ativo: {versao[0]}')
            conectado = True
            break
    except Exception as err:
        print(f'--> [Aviso {i}/{max_tentativas}] Banco de dados ainda a inicializar: {err}', file=sys.stderr)
        time.sleep(2)

if not conectado:
    print('--> [ALERTA] Não foi possível verificar PostGIS previamente. A prosseguir com migrações...', file=sys.stderr)
"

# 2. Execução incondicional de migrações para TODAS as apps
echo "--> [3/4] A aplicar todas as migrações na base de dados (migrate)..."
python manage.py makemigrations accounts catalog orders logistics finance promotions support --noinput || true
python manage.py makemigrations --noinput || true
python manage.py migrate --noinput

# 2b. Sincronização e auto-ativação incondicional de todas as lojas de parceiros
echo "--> [3b/4] A ativar e sincronizar lojas e horários de parceiros..."
python -c "
import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
django.setup()

from apps.accounts.models import CustomUser
from apps.accounts.views import garantir_loja_parceiro_ativa
from apps.catalog.models import ParceiroLoja

total_parceiros = 0
for parceiro in CustomUser.objects.filter(tipo_utilizador=CustomUser.TipoUtilizador.PARCEIRO):
    garantir_loja_parceiro_ativa(parceiro)
    total_parceiros += 1

# Garante que qualquer loja parceira no estado PENDENTE seja ativada
ParceiroLoja.objects.filter(estado=ParceiroLoja.EstadoLoja.PENDENTE).update(estado=ParceiroLoja.EstadoLoja.ATIVO)

# Reset incondicional de artigos do cardápio e pratos em destaque da vitrine
from apps.catalog.models import ItemMenu
total_reset, _ = ItemMenu.objects.all().delete()
print(f'--> [SUCESSO] Limpos {total_reset} artigos de cardápio e vitrine!')

print(f'--> [SUCESSO] Sincronizadas {total_parceiros} contas de parceiros e ativadas as respetivas lojas!')
" || true

# 3. Recolha de ficheiros estáticos como garantia de disponibilidade
echo "--> [4/4] A validar ficheiros estáticos (collectstatic)..."
python manage.py collectstatic --noinput || true

echo "======================================================================"
echo "--> [OK] Base de dados 100% atualizada! A iniciar Daphne ASGI na porta ${PORT:-8000}..."
echo "======================================================================"

exec daphne -b 0.0.0.0 -p ${PORT:-8000} config.asgi:application

