#!/usr/bin/env bash
# ==============================================================================
# Script de Build Automatizado para o Render (Web Service)
# Plataforma: Delivery (Ango_Ifood)
# Stack: Django 5 + GeoDjango (PostGIS) + DRF + Channels (Daphne) + WhiteNoise
# ==============================================================================

set -o errexit
set -o pipefail
set -o nounset

echo "======================================================================"
echo "--> [1/4] A iniciar pipeline de build no Render..."
echo "======================================================================"

# 1. Atualização do pip e instalação das dependências do projeto
echo "--> [2/4] A atualizar o pip e a instalar dependências do requirements.txt..."
python -m pip install --upgrade pip
pip install -r requirements.txt

# 2. Tentativa preliminar de migrações na fase de build (caso o banco esteja acessível)
echo "--> [3/4] A executar verificação preliminar de migrações..."
python manage.py makemigrations core accounts catalog orders logistics finance promotions support --noinput || true
python manage.py makemigrations --noinput || true
python manage.py migrate --noinput || echo "--> [Nota] Banco de dados inacessível na rede de build. As migrações serão aplicadas no arranque via start.sh / preDeployCommand."

# 3. Recolha de todos os ficheiros estáticos para CDN/WhiteNoise
echo "--> [4/4] A recolher ficheiros estáticos (collectstatic)..."
python manage.py collectstatic --noinput --clear

echo "======================================================================"
echo "--> Build concluído com sucesso no Render! Pronto para iniciar."
echo "======================================================================"
