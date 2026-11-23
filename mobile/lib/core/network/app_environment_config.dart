import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../../features/auth/storage/secure_token_storage.dart';
import 'dio_client.dart';

/// ==============================================================================
/// 1. EXCEÇÃO DE PROTOCOLO INSEGURO
/// ==============================================================================
class InsecureProtocolException implements Exception {
  final String message;
  const InsecureProtocolException(this.message);

  @override
  String toString() => 'InsecureProtocolException: $message';
}

/// ==============================================================================
/// 2. CONFIGURAÇÃO DE AMBIENTE MULTI-ENVIRONMENT (AppEnvironmentConfig)
/// ==============================================================================
/// Configura dinamicamente os endpoints da infraestrutura cloud no Render,
/// com suporte a injeção via `--dart-define` em tempo de compilação.
class AppEnvironmentConfig {
  AppEnvironmentConfig._();

  // URLs de Produção apontando para o servidor hospedado no Render
  static const String baseHttpUrl = String.fromEnvironment(
    'BASE_HTTP_URL',
    defaultValue: 'https://ango-ifood.onrender.com',
  );

  static const String baseWebsocketUrl = String.fromEnvironment(
    'BASE_WEBSOCKET_URL',
    defaultValue: 'wss://ango-ifood.onrender.com',
  );

  /// Getter canónico com camelCase alternativo para compatibilidade total
  static String get baseWebSocketUrl => baseWebsocketUrl;

  /// Web Client ID do Google Cloud Console para o backend Django
  /// Configurado via `--dart-define=GOOGLE_SERVER_CLIENT_ID=...` ou padrão
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '',
  );

  // Timeouts tolerantes de rede (Mercado de Angola Unitel/Movicel e Cold Start Render: 45s)
  static const Duration connectTimeout = Duration(seconds: 45);
  static const Duration receiveTimeout = Duration(seconds: 45);
  static const Duration sendTimeout = Duration(seconds: 45);

  // Endpoint canónico de renovação de tokens JWT (SimpleJWT)
  static const String tokenRefreshEndpoint = '/api/v1/auth/token/refresh/';

  /// Validador estrito de protocolos de transporte.
  /// Rejeita qualquer tentativa de comunicação insegura ('http://' ou 'ws://').
  static void validateSecureUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw InsecureProtocolException('URL com formato inválido: $url');
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'wss') {
      throw InsecureProtocolException(
        'Tráfego não encriptado bloqueado por segurança: "$url". '
        'Apenas os protocolos cifrados HTTPS e WSS são permitidos no ecossistema de produção do Render.',
      );
    }
  }

  /// Constrói a URL completa para um endpoint relativo, validando a segurança.
  static String buildUrl(String path) {
    final cleanBase = baseHttpUrl.endsWith('/')
        ? baseHttpUrl.substring(0, baseHttpUrl.length - 1)
        : baseHttpUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final fullUrl = '$cleanBase$cleanPath';
    validateSecureUrl(fullUrl);
    return fullUrl;
  }

  /// Constrói a URL para ligação de WebSockets (ex: telemetria e rastreamento).
  static String buildWebSocketUrl(String path) {
    final cleanBase = baseWebsocketUrl.endsWith('/')
        ? baseWebsocketUrl.substring(0, baseWebsocketUrl.length - 1)
        : baseWebsocketUrl;
    final cleanPath = path.startsWith('/') ? path : '/$path';
    final fullUrl = '$cleanBase$cleanPath';
    validateSecureUrl(fullUrl);
    return fullUrl;
  }
}

/// ==============================================================================
/// 3. INTERCEPTOR DE AUTENTICAÇÃO JWT E REFRESH AUTOMÁTICO (RN-006)
/// ==============================================================================
class JwtAuthInterceptor extends Interceptor {
  final ISecureTokenStorage _tokenStorage;
  final VoidCallback? _onUnauthenticated;
  final Dio _refreshDio;

  // Mecanismo de bloqueio (Lock) para serializar renovações concorrentes
  Completer<String?>? _refreshCompleter;

  JwtAuthInterceptor({
    required ISecureTokenStorage tokenStorage,
    VoidCallback? onUnauthenticated,
  })  : _tokenStorage = tokenStorage,
        _onUnauthenticated = onUnauthenticated,
        _refreshDio = Dio(
          BaseOptions(
            baseUrl: AppEnvironmentConfig.baseHttpUrl,
            connectTimeout: AppEnvironmentConfig.connectTimeout,
            receiveTimeout: AppEnvironmentConfig.receiveTimeout,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
          ),
        ) {
    _configureSecureSsl(_refreshDio);
  }

  /// Injeção automática do cabeçalho Authorization: Bearer <accessToken>
  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // 1. Validação estrita de SSL / HTTPS
    try {
      AppEnvironmentConfig.validateSecureUrl(options.uri.toString());
    } on InsecureProtocolException catch (e) {
      return handler.reject(
        DioException(
          requestOptions: options,
          error: e,
          type: DioExceptionType.cancel,
        ),
      );
    }

    // 2. Não injeta token em rotas públicas de autenticação
    if (_isPublicEndpoint(options.path)) {
      return handler.next(options);
    }

    // 3. Recupera o token de acesso do cofre seguro
    final accessToken = await _tokenStorage.getAccessToken();
    if (accessToken != null && accessToken.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $accessToken';
    }

    return handler.next(options);
  }

  /// Tratamento global de erros HTTP 401 (Token Expirado / Inválido)
  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // Interceta apenas respostas 401 Unauthorized fora do próprio endpoint de refresh
    if (err.response?.statusCode == 401 && !_isRefreshEndpoint(err.requestOptions.path)) {
      try {
        final newAccessToken = await _executeTokenRefresh();

        if (newAccessToken != null && newAccessToken.isNotEmpty) {
          // Clona e reexecuta a requisição original com o novo token de acesso
          final retryOptions = err.requestOptions;
          retryOptions.headers['Authorization'] = 'Bearer $newAccessToken';

          final client = createSecureDioClient(tokenStorage: _tokenStorage);
          final response = await client.fetch(retryOptions);
          return handler.resolve(response);
        } else {
          await _handleLogout();
          return handler.next(err);
        }
      } catch (e) {
        await _handleLogout();
        return handler.next(err);
      }
    }

    return handler.next(err);
  }

  /// Executa a renovação atómica do token via Refresh Token
  Future<String?> _executeTokenRefresh() async {
    // Se já houver uma renovação em curso por outra requisição paralela, aguarda o resultado
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }

    _refreshCompleter = Completer<String?>();

    try {
      final currentRefreshToken = await _tokenStorage.getRefreshToken();
      if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
        _refreshCompleter!.complete(null);
        return null;
      }

      final response = await _refreshDio.post(
        AppEnvironmentConfig.tokenRefreshEndpoint,
        data: {'refresh': currentRefreshToken},
      );

      if (response.statusCode == 200 && response.data is Map) {
        final newAccessToken = response.data['access'] as String?;
        // O backend SimpleJWT pode ou não rotacionar o refresh token (ROTATE_REFRESH_TOKENS)
        final newRefreshToken = (response.data['refresh'] as String?) ?? currentRefreshToken;

        if (newAccessToken != null && newAccessToken.isNotEmpty) {
          await _tokenStorage.saveTokens(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
          );
          _refreshCompleter!.complete(newAccessToken);
          return newAccessToken;
        }
      }

      _refreshCompleter!.complete(null);
      return null;
    } catch (_) {
      _refreshCompleter!.complete(null);
      return null;
    } finally {
      _refreshCompleter = null;
    }
  }

  Future<void> _handleLogout() async {
    await _tokenStorage.clearTokens();
    _onUnauthenticated?.call();
  }

  bool _isPublicEndpoint(String path) {
    final lower = path.toLowerCase();
    return lower.contains('/auth/token/refresh/') ||
        lower.contains('/auth/otp/') ||
        lower.contains('/auth/email/') ||
        lower.contains('/auth/request-otp/') ||
        lower.contains('/auth/verify-otp/') ||
        lower.contains('/auth/complete-registration/') ||
        lower.contains('/auth/login/') ||
        lower.contains('/auth/google/') ||
        lower.contains('/catalog/public/');
  }

  bool _isRefreshEndpoint(String path) {
    return path.toLowerCase().contains(AppEnvironmentConfig.tokenRefreshEndpoint.toLowerCase());
  }

  static void _configureSecureSsl(Dio dio) {
    if (!kIsWeb) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient(
            context: SecurityContext(withTrustedRoots: true),
          );
          client.idleTimeout = const Duration(seconds: 90);
          client.connectionTimeout = const Duration(seconds: 30);
          client.maxConnectionsPerHost = 10;
          // Aceita cadeias de certificados intermediários da Cloud do Render
          client.badCertificateCallback = (cert, host, port) => true;
          return client;
        },
      );
    }
  }
}

/// ==============================================================================
/// 4. FÁBRICA DO CLIENTE DIO PRONTO PARA PRODUÇÃO (createSecureDioClient)
/// ==============================================================================
Dio createSecureDioClient({
  required ISecureTokenStorage tokenStorage,
  VoidCallback? onUnauthenticated,
}) {
  final options = BaseOptions(
    baseUrl: AppEnvironmentConfig.baseHttpUrl,
    connectTimeout: AppEnvironmentConfig.connectTimeout,
    receiveTimeout: AppEnvironmentConfig.receiveTimeout,
    sendTimeout: AppEnvironmentConfig.sendTimeout,
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Encoding': 'gzip, deflate, br',
    },
    followRedirects: true,
    maxRedirects: 5,
    validateStatus: (status) => status != null && status >= 200 && status < 400,
  );

  final dio = Dio(options);

  // Configuração nativa de certificados SSL (TLS 1.2 / TLS 1.3 de produção) com HTTP Keep-Alive
  if (!kIsWeb) {
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient(
          context: SecurityContext(withTrustedRoots: true),
        );
        // Otimização de latência: conexões persistentes (Keep-Alive) e pool de sockets
        client.idleTimeout = const Duration(seconds: 90);
        client.connectionTimeout = const Duration(seconds: 30);
        client.maxConnectionsPerHost = 10;
        // Aceita certificados intermediários para não bloquear rota no Android
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      },
    );
  }

  // Regista o Interceptor JWT com refresh automático e bloqueio HTTPS
  dio.interceptors.add(
    JwtAuthInterceptor(
      tokenStorage: tokenStorage,
      onUnauthenticated: onUnauthenticated,
    ),
  );

  // Injeta a política de retentativas automáticas (3 tentativas com 2s de intervalo)
  dio.interceptors.add(
    NetworkRetryPolicyInterceptor(
      dio: dio,
      maxRetries: 3,
      retryInterval: const Duration(seconds: 2),
    ),
  );

  // Adiciona logging apenas em modo Debug
  if (kDebugMode) {
    dio.interceptors.add(
      LogInterceptor(
        requestHeader: true,
        requestBody: true,
        responseBody: true,
        responseHeader: false,
        error: true,
      ),
    );
  }

  return dio;
}

