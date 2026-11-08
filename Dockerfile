# ==============================================================================
# DOCKERFILE MULTI-STAGE OTIMIZADO PARA PRODUÇÃO (PYTHON 3.12+ & GEODJANGO)
# ==============================================================================
# Estágio 1: Builder (Compilação de dependências e wheels)
# Estágio 2: Runner / Final (Ambiente de execução mínimo e seguro com utilizador não-root)
# ==============================================================================

# ------------------------------------------------------------------------------
# ESTÁGIO 1: BUILDER
# ------------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS builder

# Variáveis de ambiente para o build Python
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=off \
    PIP_DISABLE_PIP_VERSION_CHECK=on \
    POETRY_VERSION=1.8.4

WORKDIR /build

# Instalação de ferramentas de compilação e dependências nativas para C/C++ e GDAL
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    libpq-dev \
    libgdal-dev \
    gdal-bin \
    libgeos-dev \
    libproj-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Configuração dos cabeçalhos do GDAL para compilação de bindings
ENV CPLUS_INCLUDE_PATH=/usr/include/gdal \
    C_INCLUDE_PATH=/usr/include/gdal

# Instalação do Poetry para exportação determinística
RUN pip install "poetry==${POETRY_VERSION}"

# Cópia dos ficheiros de especificação de dependências
COPY pyproject.toml poetry.lock* requirements.txt ./

# Compilação e geração de wheels na pasta /build/wheels
RUN pip wheel --no-cache-dir --wheel-dir /build/wheels -r requirements.txt


# ------------------------------------------------------------------------------
# ESTÁGIO 2: RUNNER (IMAGEM FINAL DE PRODUÇÃO)
# ------------------------------------------------------------------------------
FROM python:3.12-slim-bookworm AS runner

# Metadados e variáveis de ambiente em runtime
LABEL maintainer="Equipa DevOps & Arquitetura <devops@delivery.platform>" \
      version="1.0.0" \
      description="Contentor de produção para a Delivery Platform (Django, PostGIS, Channels e Celery)"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH="/app" \
    PORT=8000 \
    CPLUS_INCLUDE_PATH=/usr/include/gdal \
    C_INCLUDE_PATH=/usr/include/gdal

WORKDIR /app

# Instalação das dependências nativas de sistema em runtime para suporte geoespacial (GeoDjango/PostGIS)
RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils \
    libproj-dev \
    gdal-bin \
    libgdal-dev \
    libgeos-c1v5 \
    postgis \
    libpq5 \
    curl \
    netcat-traditional \
    && rm -rf /var/lib/apt/lists/*

# Criação de utilizador e grupo não-root para execução segura (Princípio do Menor Privilégio)
RUN groupadd -g 1000 appgroup && \
    useradd -u 1000 -g appgroup -s /bin/bash -m appuser

# Instalação dos wheels pré-compilados do estágio builder
COPY --from=builder /build/wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels /wheels/* && \
    rm -rf /wheels

# Criação dos diretórios estáticos, media e logs com permissões adequadas
RUN mkdir -p /app/staticfiles /app/media /app/logs && \
    chown -R appuser:appgroup /app

# Cópia do código-fonte da aplicação com propriedade do utilizador appuser
COPY --chown=appuser:appgroup . /app

# Transição para o utilizador não-root por motivos de conformidade de segurança
USER appuser

# Exposição da porta da aplicação
EXPOSE 8000

# Healthcheck do contentor HTTP ultra-rápido
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/healthz/ || exit 1

# Comando de arranque por defeito em produção (Gunicorn com workers ASGI Uvicorn para HTTP e WebSockets)
CMD ["gunicorn", "config.asgi:application", \
     "-k", "uvicorn.workers.UvicornWorker", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "4", \
     "--worker-connections", "1000", \
     "--max-requests", "2000", \
     "--max-requests-jitter", "200", \
     "--timeout", "60", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]
