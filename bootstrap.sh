#!/usr/bin/env bash
# ==============================================================================
# Script de Inicialização (Bootstrap) para Projeto Django + PostGIS + DRF + Channels + Celery
# ==============================================================================
set -euo pipefail

echo "======================================================================"
echo " [1/6] A verificar dependências de sistema para GeoDjango (PostGIS)..."
echo "======================================================================"
if command -v apt-get >/dev/null 2>&1; then
    echo "-> Sistema Debian/Ubuntu detetado. A verificar bibliotecas GDAL, GEOS e PROJ..."
    if ! command -v gdal-config >/dev/null 2>&1; then
        echo "-> A instalar binários do GeoDjango (requer sudo)..."
        sudo apt-get update
        sudo apt-get install -y binutils libproj-dev gdal-bin libgdal-dev libgeos-dev postgresql-client
    else
        echo "-> GDAL já instalado ($(gdal-config --version))."
    fi
elif command -v brew >/dev/null 2>&1; then
    echo "-> macOS (Homebrew) detetado. A verificar bibliotecas GDAL, GEOS e PROJ..."
    brew list gdal &>/dev/null || brew install gdal geos proj libpq
else
    echo "-> Aviso: Certifique-se de que GDAL, GEOS e PROJ estão instalados no sistema."
fi

echo "======================================================================"
echo " [2/6] A configurar o ambiente virtual Python (.venv)..."
echo "======================================================================"
PYTHON_BIN=${PYTHON_BIN:-python3}
if [ ! -d ".venv" ]; then
    $PYTHON_BIN -m venv .venv
    echo "-> Ambiente virtual '.venv' criado com sucesso."
fi

# Ativar o ambiente virtual
source .venv/bin/activate

echo "======================================================================"
echo " [3/6] A atualizar pip e instalar dependências..."
echo "======================================================================"
pip install --upgrade pip setuptools wheel
pip install -r requirements.txt

echo "======================================================================"
echo " [4/6] A preparar estrutura de diretórios e ficheiro .env..."
echo "======================================================================"
mkdir -p apps static media templates

if [ ! -f ".env" ]; then
    cp .env.example .env
    # Gerar automaticamente uma SECRET_KEY criptograficamente segura
    GENERATED_KEY=$(python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())")
    sed -i.bak "s|DJANGO_SECRET_KEY=.*|DJANGO_SECRET_KEY=${GENERATED_KEY}|g" .env && rm -f .env.bak
    echo "-> Ficheiro '.env' criado a partir de '.env.example' com SECRET_KEY gerada."
else
    echo "-> Ficheiro '.env' já existe. A manter configuração atual."
fi

echo "======================================================================"
echo " [5/6] A validar configuração do Django (System Check)..."
echo "======================================================================"
python manage.py check

echo "======================================================================"
echo " [6/6] A executar migrações e recolha de estáticos (se BD disponível)..."
echo "======================================================================"
if python manage.py migrate --noinput; then
    python manage.py collectstatic --noinput
    echo "-> Base de dados PostGIS migrada e ficheiros estáticos recolhidos com sucesso!"
else
    echo "-> Aviso: Não foi possível ligar à base de dados PostgreSQL/PostGIS neste momento."
    echo "   Verifique a variável DATABASE_URL no ficheiro .env e certifique-se de que a extensão"
    echo "   'CREATE EXTENSION IF NOT EXISTS postgis;' está ativa na base de dados."
fi

echo "======================================================================"
echo " Inicialização concluída!"
echo " - Servidor ASGI (Daphne): daphne -b 0.0.0.0 -p 8000 config.asgi:application"
echo " - Worker Celery:          celery -A config worker -l INFO"
echo "======================================================================"
