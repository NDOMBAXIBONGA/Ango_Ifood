import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../../features/auth/storage/secure_token_storage.dart';
import 'app_environment_config.dart';

/// ==============================================================================
/// INTERCEPTOR DE REPETIÇÃO AUTOMÁTICA COM RECUO EXPONENCIAL (Retry Policy)
/// ==============================================================================
/// Executa até 3 tentativas automáticas com recuo exponencial (1s, 2s, 4s)
/// antes de repassar qualquer exceção de rede para a interface gráfica.
class ExponentialBackoffRetryInterceptor extends Interceptor {
  final Dio dio;
  final int maxRetries;
  final Duration initialDelay;

  ExponentialBackoffRetryInterceptor({
    required this.dio,
    this.maxRetries = 3,
    this.initialDelay = const Duration(seconds: 1),
  });

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final isTimeoutOrNetwork = err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.connectionError;

    var retryCount = (err.requestOptions.extra['retry_count'] as int?) ?? 0;

    if (isTimeoutOrNetwork && retryCount < maxRetries) {
      retryCount++;
      // Recuo exponencial: 1s -> 2s -> 4s
      final delay = initialDelay * (1 << (retryCount - 1));

      developer.log(
        '⚠️ [RETRY POLICY] Falha de rede em ${err.requestOptions.uri}. '
        'A executar tentativa $retryCount de $maxRetries com recuo de ${delay.inSeconds}s...',
        name: 'DioClient',
      );

      await Future.delayed(delay);

      final retryOptions = err.requestOptions;
      retryOptions.extra['retry_count'] = retryCount;

      try {
        final response = await dio.fetch(retryOptions);
        return handler.resolve(response);
      } on DioException catch (retryErr) {
        return super.onError(retryErr, handler);
      } catch (e) {
        return handler.next(err);
      }
    }

    return super.onError(err, handler);
  }
}

/// ==============================================================================
/// CLIENTE HTTP DIO DE ALTA RESILIÊNCIA (DioClient)
/// ==============================================================================
/// Configurado especificamente para o mercado angolano com tolerância a latência
/// móvel (20 segundos de timeout), política de repetição com recuo exponencial
/// e corrotina de despertar para lidar com o estado "Sleep" do Render.
class DioClient {
  final Dio dio;
  final ISecureTokenStorage tokenStorage;

  DioClient._({
    required this.dio,
    required this.tokenStorage,
  });

  /// Fábrica de inicialização do DioClient com timeouts e interceptores
  factory DioClient({
    required ISecureTokenStorage tokenStorage,
    String? baseUrl,
    VoidCallback? onUnauthenticated,
  }) {
    final effectiveBaseUrl = baseUrl ?? AppEnvironmentConfig.baseHttpUrl;

    // Configurações resilientes para o mercado angolano: 20 segundos de timeout
    final options = BaseOptions(
      baseUrl: effectiveBaseUrl,
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      validateStatus: (status) => status != null && status >= 200 && status < 300,
    );

    final dioInstance = Dio(options);

    // Configuração de adaptador I/O nativo para lidar com validação de certificados SSL no Android
    if (!kIsWeb) {
      dioInstance.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient(
            context: SecurityContext(withTrustedRoots: true),
          );
          // Aceita certificados SSL intermediários do Render e ambientes de teste
          client.badCertificateCallback = (X509Certificate cert, String host, int port) {
            return true;
          };
          return client;
        },
      );
    }

    // Regista o interceptor JWT e controlo de sessão
    dioInstance.interceptors.add(
      JwtAuthInterceptor(
        tokenStorage: tokenStorage,
        onUnauthenticated: onUnauthenticated,
      ),
    );

    // Regista o mecanismo de repetição automática com recuo exponencial (3 tentativas)
    dioInstance.interceptors.add(
      ExponentialBackoffRetryInterceptor(
        dio: dioInstance,
        maxRetries: 3,
        initialDelay: const Duration(seconds: 1),
      ),
    );

    // Logging de requisições e respostas
    dioInstance.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          developer.log(
            '--> [DIO REQ] ${options.method} ${options.uri}',
            name: 'DioClient',
          );
          return handler.next(options);
        },
        onResponse: (response, handler) {
          developer.log(
            '<-- [DIO RESP ${response.statusCode}] ${response.requestOptions.uri}',
            name: 'DioClient',
          );
          return handler.next(response);
        },
        onError: (DioException err, handler) {
          developer.log(
            '<-- [DIO ERROR] [${err.type}] URI: ${err.requestOptions.uri}',
            name: 'DioClient',
            error: err,
          );
          if (err.response != null) {
            developer.log(
              '    [STATUS CODE] ${err.response?.statusCode}',
              name: 'DioClient',
            );
            developer.log(
              '    [RESPONSE BODY] ${err.response?.data}',
              name: 'DioClient',
            );
          }
          return handler.next(err);
        },
      ),
    );

    return DioClient._(dio: dioInstance, tokenStorage: tokenStorage);
  }

  /// Corrotina assíncrona de despertar do contentor Render (Sleep/Cold Start Handler)
  /// Envia pacotes intermitentes (pings) em loop para /api/v1/health/ até retornar HTTP 200
  Future<bool> wakeUpRenderService({
    void Function(String message, int elapsedSeconds)? onProgress,
    Duration maxDuration = const Duration(seconds: 60),
    Duration pingInterval = const Duration(seconds: 2),
  }) async {
    final healthUrl = AppEnvironmentConfig.buildUrl('/api/v1/health/');
    final stopwatch = Stopwatch()..start();
    int attempt = 0;

    developer.log(
      '🚀 A iniciar corrotina de despertar (Wake-up Ping Loop) do Render em: $healthUrl',
      name: 'DioClient',
    );

    while (stopwatch.elapsed < maxDuration) {
      attempt++;
      final elapsedSec = stopwatch.elapsed.inSeconds;

      onProgress?.call(
        'A acordar o servidor na cloud ($elapsedSec s)...',
        elapsedSec,
      );

      try {
        final response = await dio.get(
          healthUrl,
          options: Options(
            connectTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 6),
            validateStatus: (status) => status != null && status < 500,
          ),
        );

        if (response.statusCode != null && response.statusCode! < 500) {
          developer.log(
            '✅ Servidor acordou com sucesso! Código HTTP ${response.statusCode} em ${elapsedSec}s.',
            name: 'DioClient',
          );
          return true;
        }
      } catch (e) {
        developer.log(
          '⏳ Servidor ainda a iniciar contentor no Render (Tentativa $attempt | ${elapsedSec}s)...',
          name: 'DioClient',
        );
      }

      await Future.delayed(pingInterval);
    }

    developer.log('❌ Tempo limite de despertar excedido (60s).', name: 'DioClient');
    return false;
  }

  /// Executa o aperto de mão (handshake) com diagnóstico de rede discriminado
  Future<HandshakeResult> executeHandshake({
    String probePath = '/api/v1/health/',
  }) async {
    final targetUrl = AppEnvironmentConfig.buildUrl(probePath);
    developer.log(
      'A iniciar handshake HTTP/SSL com Render em: $targetUrl (Timeout: 20s)',
      name: 'DioClient',
    );

    try {
      final response = await dio.get(
        targetUrl,
        options: Options(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (status) => status != null,
        ),
      );

      final statusCode = response.statusCode ?? 200;
      developer.log(
        'Handshake bem-sucedido com Render Cloud. Código HTTP: $statusCode',
        name: 'DioClient',
      );

      return HandshakeResult(
        isSuccess: true,
        statusCode: statusCode,
        message: 'Ligação estabelecida com sucesso.',
        data: response.data,
      );
    } on DioException catch (dioErr) {
      final statusCode = dioErr.response?.statusCode;
      final responseBody = dioErr.response?.data;

      if (dioErr.type == DioExceptionType.connectionTimeout ||
          dioErr.type == DioExceptionType.receiveTimeout ||
          dioErr.type == DioExceptionType.sendTimeout) {
        developer.log(
          '❌ [TIMEOUT] O servidor no Render demorou mais de 20s para responder.',
          name: 'DioClient',
        );
        developer.log('   Código HTTP retornado: ${statusCode ?? "Sem resposta"}', name: 'DioClient');
        developer.log('   Corpo do erro: $responseBody', name: 'DioClient');

        return HandshakeResult(
          isSuccess: false,
          statusCode: statusCode ?? 408,
          message: 'Tempo limite de conexão excedido (20s). O servidor Render pode estar adormecido.',
          errorDetails: dioErr.message,
        );
      }

      if (dioErr.type == DioExceptionType.badResponse) {
        developer.log('❌ [BAD RESPONSE] Código: $statusCode | Corpo: $responseBody', name: 'DioClient');
        return HandshakeResult(
          isSuccess: false,
          statusCode: statusCode ?? 500,
          message: 'Erro retornado pelo servidor ($statusCode).',
          errorDetails: responseBody?.toString(),
        );
      }

      return HandshakeResult(
        isSuccess: false,
        statusCode: statusCode ?? 0,
        message: 'Erro ao ligar ao servidor. Verifique a sua internet.',
        errorDetails: dioErr.message,
      );
    } catch (e) {
      return HandshakeResult(
        isSuccess: false,
        statusCode: 0,
        message: 'Falha inesperada de comunicação.',
        errorDetails: e.toString(),
      );
    }
  }
}

/// Resultado do Handshake com diagnóstico discriminado
class HandshakeResult {
  final bool isSuccess;
  final int statusCode;
  final String message;
  final dynamic data;
  final String? errorDetails;

  const HandshakeResult({
    required this.isSuccess,
    required this.statusCode,
    required this.message,
    this.data,
    this.errorDetails,
  });

  @override
  String toString() {
    return 'HandshakeResult(success: $isSuccess, HTTP $statusCode, msg: $message)';
  }
}
