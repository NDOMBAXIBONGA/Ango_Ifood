# ==============================================================================
# Script de Inicialização (PowerShell) para Projeto Django + PostGIS + DRF + Channels + Celery
# ==============================================================================
$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " [1/5] A configurar o ambiente virtual Python (.venv)..." -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

if (-not (Test-Path ".venv")) {
    python -m venv .venv
    Write-Host "-> Ambiente virtual '.venv' criado com sucesso." -ForegroundColor Green
}

& .\.venv\Scripts\Activate.ps1

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " [2/5] A atualizar pip e instalar dependências..." -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
python -m pip install --upgrade pip setuptools wheel
pip install -r requirements.txt

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " [3/5] A preparar estrutura de diretórios e ficheiro .env..." -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "apps", "static", "media", "templates" | Out-Null

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    $SecretKey = python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
    (Get-Content ".env") -replace "DJANGO_SECRET_KEY=.*", "DJANGO_SECRET_KEY=$SecretKey" | Set-Content ".env"
    Write-Host "-> Ficheiro '.env' criado com uma DJANGO_SECRET_KEY gerada automaticamente." -ForegroundColor Green
} else {
    Write-Host "-> Ficheiro '.env' já existe. A manter configuração atual." -ForegroundColor Yellow
}

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " [4/5] Nota sobre GeoDjango (PostGIS) no Windows" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Certifique-se de que o OSGeo4W (GDAL/GEOS/PROJ) está instalado e defina"
Write-Host "GDAL_LIBRARY_PATH e GEOS_LIBRARY_PATH no ficheiro .env caso não estejam no PATH."

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " [5/5] Inicialização concluída!" -ForegroundColor Green
Write-Host " - Servidor ASGI (Daphne): daphne -b 0.0.0.0 -p 8000 config.asgi:application"
Write-Host " - Worker Celery (Windows): celery -A config worker -l INFO --pool=solo"
Write-Host "======================================================================" -ForegroundColor Cyan
