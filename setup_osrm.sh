#!/bin/bash
# ==============================================================================
# Script de Configuração e Pré-Processamento do OSRM para Angola (Delivery Pro)
# Baixa os dados OpenStreetMap de Angola (Geofabrik), gera as malhas viárias
# e inicializa o motor de rotas OSRM na porta 5000 via Docker.
# ==============================================================================

set -e

DATA_DIR="./osrm-data"
OSM_PBF_URL="https://download.geofabrik.de/africa/angola-latest.osm.pbf"
PBF_FILE="${DATA_DIR}/angola-latest.osm.pbf"
OSRM_BASE="${DATA_DIR}/angola-latest.osrm"

echo "======================================================================"
echo "🚀 INICIALIZAÇÃO DO MOTOR DE ROTAS OSRM - ANGOLA (OPENSTREETMAP)"
echo "======================================================================"

# 1. Criação do diretório de dados se não existir
mkdir -p "$DATA_DIR"

# 2. Download dos dados vetoriais de Angola do Geofabrik
if [ ! -f "$PBF_FILE" ]; then
    echo "📥 A descarregar malha viária de Angola ($OSM_PBF_URL)..."
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$PBF_FILE" "$OSM_PBF_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$PBF_FILE" "$OSM_PBF_URL"
    else
        echo "❌ Erro: curl ou wget não encontrados para efetuar o download."
        exit 1
    fi
    echo "✅ Download concluído com sucesso!"
else
    echo "ℹ️ Ficheiro $PBF_FILE já existe. A ignorar download."
fi

# 3. Pré-processamento com o perfil de condução automóvel (car.lua)
echo "⚙️ Passo 1/3: A extrair dados da malha viária (osrm-extract com car.lua)..."
docker run --rm -t -v "$(pwd)/${DATA_DIR}:/data" osrm/osrm-backend:latest osrm-extract -p /opt/car.lua /data/angola-latest.osm.pbf

echo "⚙️ Passo 2/3: A particionar os nós e arestas (osrm-partition)..."
docker run --rm -t -v "$(pwd)/${DATA_DIR}:/data" osrm/osrm-backend:latest osrm-partition /data/angola-latest.osrm

echo "⚙️ Passo 3/3: A personalizar células e pesos viários (osrm-customize)..."
docker run --rm -t -v "$(pwd)/${DATA_DIR}:/data" osrm/osrm-backend:latest osrm-customize /data/angola-latest.osrm

echo "======================================================================"
echo "🎉 PROCESSAMENTO OSRM CONCLUÍDO COM SUCESSO!"
echo "A iniciar contentores OSRM e Redis via Docker Compose..."
echo "======================================================================"

docker compose up -d osrm redis

echo ""
echo "✅ Motor de Rotas Ativo em: http://localhost:5000"
echo "✅ Teste rápido de Lubango:"
echo "   curl 'http://localhost:5000/route/v1/driving/13.4925,-14.9172;13.5010,-14.9250?overview=full'"
echo "======================================================================"
