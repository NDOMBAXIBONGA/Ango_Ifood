#!/usr/bin/env bash
# ==============================================================================
# Script de Build Automatizado para o Render (Web Service)
# Plataforma: Delivery (Ango_Ifood)
# Stack: Django 5 + GeoDjango (PostGIS) + DRF + Channels (Daphne) + WhiteNoise
# ==============================================================================

# Passo 1: Aborta a execução instantaneamente caso qualquer comando falhe
set -o errexit
set -o pipefail
set -o nounset

echo "======================================================================"
echo "--> [1/5] A iniciar pipeline de build no Render..."
echo "======================================================================"

# Passo 2: Atualização do pip e instalação das dependências do projeto
echo "--> [2/5] A atualizar o pip e a instalar dependências do requirements.txt..."
python -m pip install --upgrade pip
pip install -r requirements.txt

# Passo 5: Habilitação preliminar da extensão PostGIS no PostgreSQL
# Garante que tipos geométricos (PointField, PolygonField) existam antes do migrate
echo "--> [3/5] A verificar e inicializar extensão espacial PostGIS..."
python -c "
import os
import sys
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings')
django.setup()

from django.db import connection

try:
    with connection.cursor() as cursor:
        print('--> A executar CREATE EXTENSION IF NOT EXISTS postgis...')
        cursor.execute('CREATE EXTENSION IF NOT EXISTS postgis;')
        cursor.execute('SELECT PostGIS_Full_Version();')
        versao = cursor.fetchone()
        print(f'--> PostGIS verificado e ativo: {versao[0]}')
except Exception as erro:
    print(f'--> Aviso na ativação de PostGIS via cursor: {erro}', file=sys.stderr)
"

# Passo 4: Execução atómica das migrações do banco de dados
echo "--> [4/5] A aplicar migrações na base de dados PostgreSQL..."
python manage.py makemigrations accounts --noinput || true
python manage.py makemigrations --noinput || true
python manage.py migrate --noinput

# Passo 3: Recolha de todos os ficheiros estáticos para CDN/WhiteNoise
echo "--> [5/5] A recolher ficheiros estáticos (collectstatic)..."
python manage.py collectstatic --noinput --clear

echo "======================================================================"
echo "--> Build concluído com sucesso no Render! Pronto para iniciar."
echo "======================================================================"

