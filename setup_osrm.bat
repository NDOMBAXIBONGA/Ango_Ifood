@echo off
REM ==============================================================================
REM Script de Configuração e Pré-Processamento do OSRM para Angola no Windows
REM ==============================================================================

set DATA_DIR=osrm-data
set OSM_PBF_URL=https://download.geofabrik.de/africa/angola-latest.osm.pbf
set PBF_FILE=%DATA_DIR%\angola-latest.osm.pbf

echo ======================================================================
echo INICIALIZACAO DO MOTOR DE ROTAS OSRM - ANGOLA (OPENSTREETMAP)
echo ======================================================================

if not exist "%DATA_DIR%" mkdir "%DATA_DIR%"

if not exist "%PBF_FILE%" (
    echo Descarregando malha viaria de Angola do Geofabrik...
    curl -L -o "%PBF_FILE%" "%OSM_PBF_URL%"
) else (
    echo Ficheiro %PBF_FILE% ja existe. A ignorar download.
)

echo Passo 1/3: osrm-extract com car.lua...
docker run --rm -t -v "%cd%/%DATA_DIR%:/data" osrm/osrm-backend:latest osrm-extract -p /opt/car.lua /data/angola-latest.osm.pbf

echo Passo 2/3: osrm-partition...
docker run --rm -t -v "%cd%/%DATA_DIR%:/data" osrm/osrm-backend:latest osrm-partition /data/angola-latest.osrm

echo Passo 3/3: osrm-customize...
docker run --rm -t -v "%cd%/%DATA_DIR%:/data" osrm/osrm-backend:latest osrm-customize /data/angola-latest.osrm

echo Iniciando OSRM e Redis via Docker Compose...
docker compose up -d osrm redis

echo OSRM ativo em http://localhost:5000
pause
