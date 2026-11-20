"""
Configuração Completa de Produção para Django + GeoDjango (PostGIS) + DRF + SimpleJWT + Channels + Celery.
"""
import os
from datetime import timedelta
from pathlib import Path

import environ

# ==============================================================================
# 1. DIRETÓRIOS BASE E INICIALIZAÇÃO DO DJANGO-ENVIRON
# ==============================================================================
BASE_DIR = Path(__file__).resolve().parent.parent

env = environ.Env(
    DJANGO_DEBUG=(bool, False),
    DJANGO_ALLOWED_HOSTS=(list, ["localhost", "127.0.0.1"]),
    DJANGO_CSRF_TRUSTED_ORIGINS=(list, []),
    DJANGO_CORS_ALLOWED_ORIGINS=(list, []),
    DJANGO_TIME_ZONE=(str, "UTC"),
    DJANGO_LANGUAGE_CODE=(str, "pt-pt"),
    DJANGO_LOG_LEVEL=(str, "INFO"),
    DB_CONN_MAX_AGE=(int, 60),
    DB_SSL_REQUIRE=(bool, False),
    JWT_ACCESS_TOKEN_LIFETIME_MINUTES=(int, 15),
    JWT_REFRESH_TOKEN_LIFETIME_DAYS=(int, 7),
    JWT_ROTATE_REFRESH_TOKENS=(bool, True),
    JWT_BLACKLIST_AFTER_ROTATION=(bool, True),
    DJANGO_SECURE_SSL_REDIRECT=(bool, False),
    DJANGO_SESSION_COOKIE_SECURE=(bool, True),
    DJANGO_CSRF_COOKIE_SECURE=(bool, True),
    DJANGO_SECURE_HSTS_SECONDS=(int, 0),
)

# Lê o ficheiro .env na raiz do projeto, caso exista
ENV_FILE = BASE_DIR / ".env"
if ENV_FILE.exists():
    environ.Env.read_env(str(ENV_FILE))

# ==============================================================================
# 2. SEGURANÇA E CORE
# ==============================================================================
# Suporta DJANGO_SECRET_KEY e SECRET_KEY (padrão Render), gerando fallback seguro caso ausente
SECRET_KEY = (
    env("DJANGO_SECRET_KEY", default=None)
    or env("SECRET_KEY", default=None)
    or os.environ.get("DJANGO_SECRET_KEY")
    or os.environ.get("SECRET_KEY")
)

if not SECRET_KEY:
    import secrets
    SECRET_KEY = secrets.token_urlsafe(50)

DEBUG = env.bool("DJANGO_DEBUG", default=False)
ALLOWED_HOSTS = env.list(
    "DJANGO_ALLOWED_HOSTS",
    default=[
        ".onrender.com",
        "onrender.com",
        "ango-ifood.onrender.com",
        "delivery-backend-api.onrender.com",
        "localhost",
        "127.0.0.1",
        "*",
    ],
)
CSRF_TRUSTED_ORIGINS = env.list(
    "DJANGO_CSRF_TRUSTED_ORIGINS",
    default=[
        "https://*.onrender.com",
        "https://ango-ifood.onrender.com",
        "https://delivery-backend-api.onrender.com",
    ],
)

# Deteta automaticamente o hostname externo do Render (ex.: *.onrender.com)
render_external_hostname = os.environ.get("RENDER_EXTERNAL_HOSTNAME")
if render_external_hostname:
    if render_external_hostname not in ALLOWED_HOSTS:
        ALLOWED_HOSTS.append(render_external_hostname)
    render_origin = f"https://{render_external_hostname}"
    if render_origin not in CSRF_TRUSTED_ORIGINS:
        CSRF_TRUSTED_ORIGINS.append(render_origin)

# Headers de Proxy Reverso (Nginx / Traefik / AWS ALB / Render Cloud)
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
USE_X_FORWARDED_PORT = True
APPEND_SLASH = True

if not DEBUG:
    SECURE_SSL_REDIRECT = env.bool("DJANGO_SECURE_SSL_REDIRECT")
    SESSION_COOKIE_SECURE = env.bool("DJANGO_SESSION_COOKIE_SECURE")
    CSRF_COOKIE_SECURE = env.bool("DJANGO_CSRF_COOKIE_SECURE")
    SECURE_HSTS_SECONDS = env.int("DJANGO_SECURE_HSTS_SECONDS")
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_HSTS_PRELOAD = True
    SECURE_CONTENT_TYPE_NOSNIFF = True
    X_FRAME_OPTIONS = "DENY"

# ==============================================================================
# 3. APLICAÇÕES INSTALADAS (INSTALLED_APPS)
# ==============================================================================
# Daphne tem de estar no topo de INSTALLED_APPS para assumir o comando runserver em ASGI
DJANGO_APPS = [
    "daphne",
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "django.contrib.gis",  # Suporte nativo GeoDjango / PostGIS
]

THIRD_PARTY_APPS = [
    "rest_framework",
    "rest_framework_gis",
    "rest_framework_simplejwt",
    "rest_framework_simplejwt.token_blacklist",
    "corsheaders",
    "channels",
]

LOCAL_APPS = [
    "core",
    "apps.accounts",
    "apps.catalog",
    "apps.cart",
    "apps.orders",
    "apps.logistics",
    "apps.promotions",
    "apps.support",
    "apps.finance",
]

INSTALLED_APPS = DJANGO_APPS + THIRD_PARTY_APPS + LOCAL_APPS

# Modelo de utilizador personalizado onde o 'telemovel' é o USERNAME_FIELD (RN-001)
AUTH_USER_MODEL = "accounts.CustomUser"

# Backends de autenticação: Suporta login tanto por Telemóvel quanto por E-mail no Django Admin
AUTHENTICATION_BACKENDS = [
    "apps.accounts.backends.EmailOrPhoneBackend",
    "django.contrib.auth.backends.ModelBackend",
]

# ==============================================================================
# 4. MIDDLEWARE
# ==============================================================================
MIDDLEWARE = [
    # CORS em primeiro lugar absoluto para interceptar preflight OPTIONS e cabeçalhos de clientes móveis/APK
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.security.SecurityMiddleware",
    # Compressão HTTP Gzip automática para respostas JSON e estáticas em redes lentas (2G/3G/4G)
    "django.middleware.gzip.GZipMiddleware",
    "whitenoise.middleware.WhiteNoiseMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    # Middleware de Auditoria e Proteção Antifraude (Secção 6.14, RN-130 a RN-135)
    "apps.orders.fraud_engine.FraudRiskAssessmentEngine",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "config.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.debug",
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

# Servidores WSGI e ASGI (Channels)
WSGI_APPLICATION = "config.wsgi.application"
ASGI_APPLICATION = "config.asgi.application"

# ==============================================================================
# 5. BASE DE DADOS (POSTGRESQL + POSTGIS) & GEODJANGO
# ==============================================================================
# Lê DATABASE_URL (ex: postgis://user:pass@host:5432/dbname) e força explicitamente
# o motor 'django.contrib.gis.db.backends.postgis' para garantir suporte espacial.
DATABASES = {
    "default": env.db(
        "DATABASE_URL",
        default="postgis://postgres:postgres@127.0.0.1:5432/delivery_db",
        engine="django.contrib.gis.db.backends.postgis",
    )
}
# Assegura que tanto 'postgres://' como 'postgresql://' utilizem o backend PostGIS
if "postgis" in DATABASES["default"]["ENGINE"] or "postgresql" in DATABASES["default"]["ENGINE"]:
    DATABASES["default"]["ENGINE"] = "django.contrib.gis.db.backends.postgis"

DATABASES["default"]["CONN_MAX_AGE"] = env.int("DB_CONN_MAX_AGE", default=0)
DATABASES["default"]["CONN_HEALTH_CHECKS"] = True

# Suporte automático a conexões remotas seguras (ex: Render / Supabase / Neon / RDS)
if env.bool("DB_SSL_REQUIRE", default=False) or "sslmode=require" in env("DATABASE_URL", default=""):
    DATABASES["default"].setdefault("OPTIONS", {})["sslmode"] = "require"

# Suporte a caminhos explícitos para bibliotecas nativas C (GDAL / GEOS), útil em Windows/Docker customizado
GDAL_LIBRARY_PATH = env("GDAL_LIBRARY_PATH", default=None)
GEOS_LIBRARY_PATH = env("GEOS_LIBRARY_PATH", default=None)

if os.name == "nt":
    import glob
    import ctypes

    # Validação rigorosa de caminhos GDAL/GEOS definidos manualmente
    if GDAL_LIBRARY_PATH:
        if not os.path.exists(GDAL_LIBRARY_PATH):
            GDAL_LIBRARY_PATH = None
        else:
            try:
                dll_dir = os.path.dirname(GDAL_LIBRARY_PATH)
                if hasattr(os, "add_dll_directory"):
                    os.add_dll_directory(dll_dir)
                os.environ["PATH"] = dll_dir + os.pathsep + os.environ.get("PATH", "")
                ctypes.CDLL(GDAL_LIBRARY_PATH)
            except Exception:
                GDAL_LIBRARY_PATH = None

    if GEOS_LIBRARY_PATH:
        if not os.path.exists(GEOS_LIBRARY_PATH):
            GEOS_LIBRARY_PATH = None
        else:
            try:
                dll_dir = os.path.dirname(GEOS_LIBRARY_PATH)
                if hasattr(os, "add_dll_directory"):
                    os.add_dll_directory(dll_dir)
                os.environ["PATH"] = dll_dir + os.pathsep + os.environ.get("PATH", "")
                ctypes.CDLL(GEOS_LIBRARY_PATH)
            except Exception:
                GEOS_LIBRARY_PATH = None

    # Autodescoberta inteligente de GDAL no Windows
    if not GDAL_LIBRARY_PATH:
        possible_gdal = [
            *glob.glob(r"C:\OSGeo4W*\bin\gdal*.dll"),
            *glob.glob(r"C:\Program Files\PostgreSQL\*\bin\gdal*.dll"),
            *glob.glob(str(BASE_DIR / "venv" / "Lib" / "site-packages" / "**" / "gdal*.dll"), recursive=True),
        ]
        for p in possible_gdal:
            if os.path.exists(p):
                try:
                    dll_dir = os.path.dirname(p)
                    if hasattr(os, "add_dll_directory"):
                        os.add_dll_directory(dll_dir)
                    os.environ["PATH"] = dll_dir + os.pathsep + os.environ.get("PATH", "")
                    ctypes.CDLL(p)
                    GDAL_LIBRARY_PATH = p
                    break
                except Exception:
                    continue

    # Autodescoberta inteligente de GEOS no Windows (via shapely.libs no venv)
    if not GEOS_LIBRARY_PATH:
        possible_geos = glob.glob(str(BASE_DIR / "venv" / "Lib" / "site-packages" / "shapely.libs" / "geos_c*.dll"))
        for p in possible_geos:
            if os.path.exists(p):
                try:
                    dll_dir = os.path.dirname(p)
                    if hasattr(os, "add_dll_directory"):
                        os.add_dll_directory(dll_dir)
                    os.environ["PATH"] = dll_dir + os.pathsep + os.environ.get("PATH", "")
                    ctypes.CDLL(p)
                    GEOS_LIBRARY_PATH = p
                    break
                except Exception:
                    continue

# ==============================================================================
# 6. CACHE & REDIS CONFIGURATION (REDIS_URL)
# ==============================================================================
REDIS_URL = env("REDIS_URL", default=None) or os.environ.get("REDIS_URL")

# Se REDIS_URL estiver definida e não for localhost sem servidor, utiliza Redis; caso contrário, LocMemCache
if REDIS_URL and not REDIS_URL.startswith("redis://127.0.0.1") and not REDIS_URL.startswith("redis://localhost"):
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.redis.RedisCache",
            "LOCATION": env("REDIS_CACHE_URL", default=f"{REDIS_URL}/3"),
        }
    }
else:
    CACHES = {
        "default": {
            "BACKEND": "django.core.cache.backends.locmem.LocMemCache",
            "LOCATION": "delivery-default-cache",
        }
    }

# ==============================================================================
# 7. DJANGO CHANNELS (REDIS CHANNEL LAYER NO RENDER)
# ==============================================================================
# Lê dinamicamente a variável REDIS_URL do Render para canais WebSockets assíncronos
if REDIS_URL and not REDIS_URL.startswith("redis://127.0.0.1") and not REDIS_URL.startswith("redis://localhost"):
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels_redis.core.RedisChannelLayer",
            "CONFIG": {
                "hosts": [env("CHANNEL_LAYERS_REDIS_URL", default=REDIS_URL)],
                "capacity": 1500,  # Máximo de mensagens em fila por canal antes de descartar
                "expiry": 60,      # Tempo de expiração de mensagens em segundos
            },
        },
    }
else:
    CHANNEL_LAYERS = {
        "default": {
            "BACKEND": "channels.layers.InMemoryChannelLayer",
        },
    }


# ==============================================================================
# 8. CELERY (REDIS BROKER & RESULT BACKEND)
# ==============================================================================
CELERY_BROKER_URL = env("CELERY_BROKER_URL", default=f"{REDIS_URL}/0")
CELERY_RESULT_BACKEND = env("CELERY_RESULT_BACKEND", default=f"{REDIS_URL}/1")
CELERY_BROKER_CONNECTION_RETRY_ON_STARTUP = True
CELERY_ACCEPT_CONTENT = ["json"]
CELERY_TASK_SERIALIZER = "json"
CELERY_RESULT_SERIALIZER = "json"
CELERY_TIMEZONE = env("DJANGO_TIME_ZONE")
CELERY_ENABLE_UTC = True
CELERY_TASK_TRACK_STARTED = True
CELERY_TASK_TIME_LIMIT = 30 * 60       # Hard limit: 30 minutos
CELERY_TASK_SOFT_TIME_LIMIT = 25 * 60  # Soft limit: 25 minutos
CELERY_WORKER_PREFETCH_MULTIPLIER = 1  # Distribuição justa para tarefas de duração variável
CELERY_TASK_ACKS_LATE = True           # Confirma apenas após execução concluída

# ==============================================================================
# 9. DJANGO REST FRAMEWORK (DRF) & SIMPLE JWT
# ==============================================================================
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": (
        "rest_framework_simplejwt.authentication.JWTAuthentication",
    ),
    "DEFAULT_PERMISSION_CLASSES": (
        "rest_framework.permissions.IsAuthenticated",
    ),
    "DEFAULT_RENDERER_CLASSES": (
        ["rest_framework.renderers.JSONRenderer"]
        if not DEBUG
        else [
            "rest_framework.renderers.JSONRenderer",
            "rest_framework.renderers.BrowsableAPIRenderer",
        ]
    ),
    "DEFAULT_PARSER_CLASSES": (
        "rest_framework.parsers.JSONParser",
        "rest_framework.parsers.MultiPartParser",
        "rest_framework.parsers.FormParser",
    ),
    "DEFAULT_PAGINATION_CLASS": "rest_framework.pagination.PageNumberPagination",
    "PAGE_SIZE": 20,
    "DEFAULT_THROTTLE_CLASSES": [
        "rest_framework.throttling.AnonRateThrottle",
        "rest_framework.throttling.UserRateThrottle",
    ],
    "DEFAULT_THROTTLE_RATES": {
        "anon": "100/minute",
        "user": "1000/minute",
    },
}

# ==============================================================================
# 11. SISTEMA ANTIFRAUDE E SEGURANÇA OPERACIONAL (Secção 6.14, RN-130 a RN-135)
# ==============================================================================
FRAUD_SCORE_THRESHOLD = env.int("FRAUD_SCORE_THRESHOLD", default=80)
FRAUD_MAX_ACCOUNTS_PER_DEVICE = env.int("FRAUD_MAX_ACCOUNTS_PER_DEVICE", default=3)
FRAUD_MAX_ACCOUNTS_PER_CARD = env.int("FRAUD_MAX_ACCOUNTS_PER_CARD", default=3)

# ==============================================================================
# 12. CONFIGURAÇÃO DE E-MAILS TRANSACIONAIS (GMAIL SMTP / BREVO)
# ==============================================================================
DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL", default="jobdealmeida016@gmail.com")
BREVO_SENDER_EMAIL = env("BREVO_SENDER_EMAIL", default="jobdealmeida016@gmail.com")
BREVO_API_KEY = env("BREVO_API_KEY", default="")

# Suporte nativo ao Gmail SMTP oficial (Garante 100% entrega na Caixa Principal)
# Basta adicionar GMAIL_APP_PASSWORD nas variáveis de ambiente do Render para ativar
EMAIL_BACKEND = env("EMAIL_BACKEND", default="django.core.mail.backends.smtp.EmailBackend")
EMAIL_HOST = env("EMAIL_HOST", default="smtp.gmail.com")
EMAIL_PORT = env.int("EMAIL_PORT", default=587)
EMAIL_USE_TLS = env.bool("EMAIL_USE_TLS", default=True)
EMAIL_HOST_USER = env("EMAIL_HOST_USER", default="jobdealmeida016@gmail.com")
EMAIL_HOST_PASSWORD = env("EMAIL_HOST_PASSWORD", default=env("GMAIL_APP_PASSWORD", default=""))

# Desativado em produção por segurança para não expor o código OTP nas respostas JSON
EXPOSE_OTP_HINT = env.bool("EXPOSE_OTP_HINT", default=False)




SIMPLE_JWT = {
    "ACCESS_TOKEN_LIFETIME": timedelta(minutes=env.int("JWT_ACCESS_TOKEN_LIFETIME_MINUTES")),
    "REFRESH_TOKEN_LIFETIME": timedelta(days=env.int("JWT_REFRESH_TOKEN_LIFETIME_DAYS")),
    "ROTATE_REFRESH_TOKENS": env.bool("JWT_ROTATE_REFRESH_TOKENS"),
    "BLACKLIST_AFTER_ROTATION": env.bool("JWT_BLACKLIST_AFTER_ROTATION"),
    "UPDATE_LAST_LOGIN": True,
    "ALGORITHM": "HS256",
    "SIGNING_KEY": SECRET_KEY,
    "AUTH_HEADER_TYPES": ("Bearer",),
    "AUTH_HEADER_NAME": "HTTP_AUTHORIZATION",
    "USER_ID_FIELD": "id",
    "USER_ID_CLAIM": "user_id",
}

# ==============================================================================
# 10. CORS (CROSS-ORIGIN RESOURCE SHARING) & SEGURANÇA MOBILE
# ==============================================================================
# Para consumo de APIs REST por aplicações móveis nativas (Flutter APK Release)
# e clientes Web, permite todas as origens por padrão com suporte a credenciais.
CORS_ALLOW_ALL_ORIGINS = env.bool("CORS_ALLOW_ALL_ORIGINS", default=True)
CORS_ALLOWED_ORIGINS = env.list("DJANGO_CORS_ALLOWED_ORIGINS", default=[])
CORS_ALLOW_CREDENTIALS = True

# Cabeçalhos HTTP permitidos nas requisições do Flutter/Dio
CORS_ALLOW_HEADERS = [
    "accept",
    "accept-encoding",
    "authorization",
    "content-type",
    "dnt",
    "origin",
    "user-agent",
    "x-csrftoken",
    "x-requested-with",
]

# Métodos HTTP permitidos
CORS_ALLOW_METHODS = [
    "DELETE",
    "GET",
    "OPTIONS",
    "PATCH",
    "POST",
    "PUT",
]

# ==============================================================================
# 11. VALIDAÇÃO DE PASSWORDS, INTERNACIONALIZAÇÃO E FICHEIROS ESTÁTICOS
# ==============================================================================
AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {"NAME": "django.contrib.auth.password_validation.MinimumLengthValidator", "OPTIONS": {"min_length": 10}},
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

LANGUAGE_CODE = env("DJANGO_LANGUAGE_CODE")
TIME_ZONE = env("DJANGO_TIME_ZONE")
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"
STATICFILES_DIRS = [BASE_DIR / "static"] if (BASE_DIR / "static").exists() else []

STORAGES = {
    "default": {
        "BACKEND": "django.core.files.storage.FileSystemStorage",
    },
    "staticfiles": {
        "BACKEND": "whitenoise.storage.CompressedManifestStaticFilesStorage",
    },
}

MEDIA_URL = "/media/"
MEDIA_ROOT = BASE_DIR / "media"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# ==============================================================================
# 11.1 OTIMIZAÇÃO DE UPLOAD DE MÍDIA E LIMITES DE TRANSMISSÃO
# ==============================================================================
# Permite uploads de imagens e vídeos de vitrine até 50 MB sem travar Daphne / Render
DATA_UPLOAD_MAX_MEMORY_SIZE = 50 * 1024 * 1024  # 50 MB
FILE_UPLOAD_MAX_MEMORY_SIZE = 50 * 1024 * 1024  # 50 MB
DATA_UPLOAD_MAX_NUMBER_FIELDS = 2000

# ==============================================================================
# 12. LOGGING ESTRUTURADO PARA PRODUÇÃO (CONSOLA / CONTENTORES)
# ==============================================================================
LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "verbose": {
            "format": "[{asctime}] {levelname} [{name}:{lineno}] [PID:{process}]: {message}",
            "style": "{",
        },
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "formatter": "verbose",
        },
    },
    "root": {
        "handlers": ["console"],
        "level": env("DJANGO_LOG_LEVEL"),
    },
    "loggers": {
        "django": {
            "handlers": ["console"],
            "level": env("DJANGO_LOG_LEVEL"),
            "propagate": False,
        },
        "django.db.backends": {
            "handlers": ["console"],
            "level": "WARNING",
            "propagate": False,
        },
        "celery": {
            "handlers": ["console"],
            "level": env("DJANGO_LOG_LEVEL"),
            "propagate": False,
        },
    },
}

# ==============================================================================
# 11. SISTEMA ANTIFRAUDE E SEGURANÇA OPERACIONAL (Secção 6.14, RN-130 a RN-135)
# ==============================================================================
FRAUD_SCORE_THRESHOLD = env.int("FRAUD_SCORE_THRESHOLD", default=80)
FRAUD_MAX_ACCOUNTS_PER_DEVICE = env.int("FRAUD_MAX_ACCOUNTS_PER_DEVICE", default=3)
FRAUD_MAX_ACCOUNTS_PER_CARD = env.int("FRAUD_MAX_ACCOUNTS_PER_CARD", default=3)

# ==============================================================================
# 12. CONFIGURAÇÃO DE E-MAILS TRANSACIONAIS (GMAIL SMTP / BREVO)
# ==============================================================================
DEFAULT_FROM_EMAIL = env("DEFAULT_FROM_EMAIL", default="jobdealmeida016@gmail.com")
BREVO_SENDER_EMAIL = env("BREVO_SENDER_EMAIL", default="jobdealmeida016@gmail.com")
BREVO_API_KEY = env("BREVO_API_KEY", default="")

# Suporte nativo ao Gmail SMTP oficial (Garante 100% entrega na Caixa Principal)
# Basta adicionar GMAIL_APP_PASSWORD nas variáveis de ambiente do Render para ativar
EMAIL_BACKEND = env("EMAIL_BACKEND", default="django.core.mail.backends.smtp.EmailBackend")
EMAIL_HOST = env("EMAIL_HOST", default="smtp.gmail.com")
EMAIL_PORT = env.int("EMAIL_PORT", default=587)
EMAIL_USE_TLS = env.bool("EMAIL_USE_TLS", default=True)
EMAIL_HOST_USER = env("EMAIL_HOST_USER", default="jobdealmeida016@gmail.com")
EMAIL_HOST_PASSWORD = env("EMAIL_HOST_PASSWORD", default=env("GMAIL_APP_PASSWORD", default=""))

# Desativado em produção por segurança para não expor o código OTP nas respostas JSON
EXPOSE_OTP_HINT = env.bool("EXPOSE_OTP_HINT", default=False)



