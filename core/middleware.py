"""
Middleware de compatibilidade móvel (Dart/Flutter Dio) e proteção contra compressão Brotli (br) da Cloudflare.

Causa Raiz Resolvida:
- O cliente HTTP nativo do Dart (`dart:io` `HttpClient`) suporta apenas descompressão nativa de `gzip` e `deflate`.
- Quando o APK envia `Accept-Encoding: gzip, deflate, br` e a resposta JSON do Django tem menos de 200 bytes
  (como `/api/v1/auth/email/request/` com 184 bytes ou `/api/v1/auth/email/verify/` com 140 bytes),
  o `GZipMiddleware` padrão do Django ignora a compressão (`len(content) < 200`).
- Ao receber a resposta não comprimida do Django, a CDN da Cloudflare no Render comprime o payload com Brotli (`Content-Encoding: br`).
- O `HttpClient` do Dart não descomprime `br` e entrega os bytes binários brutos ao Dio, causando `FormatException`
  (`DioExceptionType.unknown`) que a aplicação móvel traduz como "Falha de comunicação com os servidores".

Este middleware garante que:
1. Qualquer resposta `application/json` (mesmo inferior a 200 bytes) para clientes que suportem `gzip` saia do Django
   já com `Content-Encoding: gzip`, impedindo a Cloudflare de aplicar `Content-Encoding: br`.
2. Endpoints públicos de autenticação e catálogo ignorem cabeçalhos `Authorization` expirados enviados por APKs antigos.
"""

import gzip
from django.utils.cache import patch_vary_headers


PUBLIC_PATH_FRAGMENTS = (
    "/api/v1/auth/email/",
    "/api/v1/auth/request-otp/",
    "/api/v1/auth/verify-otp/",
    "/api/v1/auth/complete-registration/",
    "/api/v1/auth/login/",
    "/api/v1/auth/google/",
    "/api/v1/auth/token/refresh/",
    "/api/v1/catalog/stores/",
    "/api/v1/catalog/public/",
    "/api/v1/system/bootstrap/",
    "/api/v1/health/",
    "/healthz/",
)


class MobileSafeGZipMiddleware:
    """
    Substituto direto do `GZipMiddleware` do Django que força `Content-Encoding: gzip`
    em todas as respostas JSON da API (mesmo < 200 bytes) quando o cliente aceita `gzip`,
    impedindo que a Cloudflare recodifique respostas curtas em Brotli (`br`).
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path_lower = (request.path_info or "").lower()

        # 1. Remove tokens JWT residuais/expirados em rotas 100% públicas para evitar HTTP 401 no DRF
        if any(frag in path_lower for frag in PUBLIC_PATH_FRAGMENTS):
            request.META.pop("HTTP_AUTHORIZATION", None)

        # 2. Normaliza Accept-Encoding removendo 'br' no contexto interno do Django
        accept_encoding = request.META.get("HTTP_ACCEPT_ENCODING", "")
        supports_gzip = "gzip" in accept_encoding.lower()

        response = self.get_response(request)

        # 3. Se já estiver comprimido ou for streaming, mantém inalterado
        if getattr(response, "streaming", False) or response.has_header("Content-Encoding"):
            return response

        # 4. Não comprime códigos sem corpo (204 No Content, 304 Not Modified, 1xx)
        if response.status_code in (204, 304) or (100 <= response.status_code < 200):
            return response

        content = getattr(response, "content", b"")
        if not content:
            return response

        content_type = response.get("Content-Type", "").lower()
        is_json_or_api = "application/json" in content_type or path_lower.startswith("/api/")

        if supports_gzip and (is_json_or_api or len(content) >= 200):
            compressed = gzip.compress(content, compresslevel=6)
            response.content = compressed
            response["Content-Encoding"] = "gzip"
            response["Content-Length"] = str(len(compressed))
            patch_vary_headers(response, ("Accept-Encoding",))

        return response
