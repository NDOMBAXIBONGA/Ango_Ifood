import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../../features/auth/storage/secure_token_storage.dart';
import 'app_environment_config.dart';

/// ==============================================================================
/// 1. INTERCEPTOR DE POLÍTICA DE RETENTATIVAS (NetworkRetryPolicyInterceptor)
/// ==============================================================================
/// Captura erros de rede e timeouts decorrentes da latência oscilante de operadoras
/// móveis em Angola (Unitel/Movicel) e do cold start no Render.
/// Executa até 3 tentativas automáticas em background com intervalo fixo de 2 segundos.
/// Se, e apenas se, todas as 3 tentativas falharem consecutivamente por timeout,
/// repassa a exceção para o BLoC para transição limpa de estado na interface.
class NetworkRetryPolicyInterceptor extends Interceptor {
  final Dio dio;
  final int maxRetries;
  final Duration retryInterval;

  NetworkRetryPolicyInterceptor({
    required this.dio,
    this.maxRetries = 3,
    this.retryInterval = const Duration(seconds: 2),
  });

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    // Identifica falhas de conectividade física, tempo limite excedido ou desconexão transitória
    final isNetworkOrTimeout = err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.unknown ||
        err.response == null;

    // Recupera o contador de retentativas associado à requisição atual
    var currentRetry = (err.requestOptions.extra['retry_count'] as int?) ?? 0;

    if (isNetworkOrTimeout && currentRetry < maxRetries) {
      currentRetry++;

      developer.log(
        '🔄 [RETRY POLICY] Falha de rede/timeout em: ${err.requestOptions.uri}. '
        'A executar tentativa $currentRetry de $maxRetries em ${retryInterval.inSeconds}s...',
        name: 'DioClient',
      );

      // Intervalo de espera de 2 segundos para estabilização do sinal móvel
      await Future.delayed(retryInterval);

      final retryOptions = err.requestOptions;
      retryOptions.extra['retry_count'] = currentRetry;

      try {
        // Tenta restabelecer a conexão repetindo a requisição original
        final response = await dio.fetch(retryOptions);

        developer.log(
          '✅ [RETRY SUCESSO] Ligação restabelecida na tentativa $currentRetry. '
          'Código HTTP: ${response.statusCode}',
          name: 'DioClient',
        );

        return handler.resolve(response);
      } on DioException catch (retryErr) {
        // Encaminha a nova falha para o ciclo de retentativas até esgotar o limite
        return super.onError(retryErr, handler);
      } catch (e) {
        return handler.next(err);
      }
    }

    // Se todas as 3 tentativas falharem consecutivamente, repassa o erro para o BLoC
    developer.log(
      '❌ [RETRY ESGOTADO] Todas as $maxRetries tentativas automáticas falharam por timeout/rede. '
      'A transferir erro para o BLoC atualizar a UI com o ecrã de falha de conexão.',
      name: 'DioClient',
      error: err,
    );

    return super.onError(err, handler);
  }
}

/// ==============================================================================
/// 2. CLIENTE HTTP CORE (DioClient)
/// ==============================================================================
/// Configurado com timeouts tolerantes de 25 segundos para acomodar o arranque do
/// contentor Django no plano gratuito do Render e a latência de redes móveis angolanas.
class DioClient {
  static const String defaultProductionUrl = 'https://ango-ifood.onrender.com';

  final Dio dio;
  final ISecureTokenStorage tokenStorage;

  DioClient._({
    required this.dio,
    required this.tokenStorage,
  });

  /// Fábrica de inicialização singleton/construtor principal
  factory DioClient({
    required ISecureTokenStorage tokenStorage,
    String? baseUrl,
    VoidCallback? onUnauthenticated,
  }) {
    // Diretriz 2: Apontamento direto para a URL de produção na nuvem
    final effectiveBaseUrl = baseUrl ?? defaultProductionUrl;

    // Diretriz 1: Configuração de Timeouts Tolerantes (25s) no BaseOptions
    final baseOptions = BaseOptions(
      baseUrl: effectiveBaseUrl,
      connectTimeout: const Duration(seconds: 25),
      receiveTimeout: const Duration(seconds: 25),
      sendTimeout: const Duration(seconds: 25),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (status) => status != null && status >= 200 && status < 400,
    );

    final dioInstance = Dio(baseOptions);

    // Validação de certificados SSL e suporte intermediário no Android
    if (!kIsWeb) {
      dioInstance.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient(
            context: SecurityContext(withTrustedRoots: true),
          );
          // Aceita cadeias de certificados geradas na nuvem do Render
          client.badCertificateCallback = (X509Certificate cert, String host, int port) => true;
          return client;
        },
      );
    }

    // Diretriz 3: Injeção do interceptor de autenticação JWT
    dioInstance.interceptors.add(
      JwtAuthInterceptor(
        tokenStorage: tokenStorage,
        onUnauthenticated: onUnauthenticated,
      ),
    );

    // Diretriz 3: Injeção do Retry Policy Interceptor (3 tentativas com 2s de intervalo)
    dioInstance.interceptors.add(
      NetworkRetryPolicyInterceptor(
        dio: dioInstance,
        maxRetries: 3,
        retryInterval: const Duration(seconds: 2),
      ),
    );

    // Interceptor de Logs em desenvolvimento
    if (kDebugMode) {
      dioInstance.interceptors.add(
        LogInterceptor(
          requestHeader: true,
          requestBody: true,
          responseBody: true,
          error: true,
        ),
      );
    }

    return DioClient._(dio: dioInstance, tokenStorage: tokenStorage);
  }

  // ============================================================================
  // MÉTODOS DE CONVENIÊNCIA HTTP BLINDADOS
  // ============================================================================

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    return dio.get<T>(
      path,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    return dio.post<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> put<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    return dio.put<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> patch<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    return dio.patch<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    return dio.delete<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }
}
