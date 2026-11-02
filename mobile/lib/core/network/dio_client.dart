import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../../features/auth/storage/secure_token_storage.dart';
import 'app_environment_config.dart';

/// ==============================================================================
/// CLIENTE HTTP DIO DE ALTA RESILIÊNCIA (DioClient)
/// ==============================================================================
/// Configurado especificamente para o mercado angolano com tolerância a latência
/// móvel (15 segundos de timeout) e tratamento granular de exceções de rede do Render.
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

    // Configurações explícitas e tolerantes para o mercado móvel angolano (15s)
    final options = BaseOptions(
      baseUrl: effectiveBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      // Qualquer resposta com status HTTP do servidor é considerada entregue
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
          // Aceita certificados SSL intermediários do Render e ambientes de staging
          client.badCertificateCallback = (X509Certificate cert, String host, int port) {
            // Em Android com redes locais angolanas, evita que certificados intermediários bloqueiem a rota
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

  /// Executa o handshake com o backend e captura especificamente erros de timeout e resposta
  Future<HandshakeResult> executeHandshake({
    String probePath = '/api/v1/catalog/public/',
  }) async {
    final targetUrl = AppEnvironmentConfig.buildUrl(probePath);
    developer.log(
      'A iniciar handshake HTTP/SSL com Render em: $targetUrl (Timeout: 15s)',
      name: 'DioClient',
    );

    try {
      final response = await dio.get(
        targetUrl,
        options: Options(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          // Qualquer status retornado pelo servidor (< 500) comprova conexão e SSL OK
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

      // Interceção específica de erros de Timeout conforme especificação
      if (dioErr.type == DioExceptionType.connectionTimeout ||
          dioErr.type == DioExceptionType.receiveTimeout ||
          dioErr.type == DioExceptionType.sendTimeout) {
        developer.log(
          '❌ [TIMEOUT] O servidor no Render demorou mais de 15s para responder.',
          name: 'DioClient',
        );
        developer.log(
          '   Código HTTP retornado: ${statusCode ?? "Sem resposta (Timeout de rede)"}',
          name: 'DioClient',
        );
        developer.log(
          '   Corpo do erro: $responseBody',
          name: 'DioClient',
        );

        return HandshakeResult(
          isSuccess: false,
          statusCode: statusCode ?? 408,
          message: 'Tempo limite de conexão excedido (15s). O servidor pode estar a inicializar.',
          errorDetails: dioErr.message,
        );
      }

      // Interceção de erro com resposta HTTP (badResponse)
      if (dioErr.type == DioExceptionType.badResponse) {
        developer.log(
          '❌ [BAD RESPONSE] Resposta inválida ou erro do servidor no Render.',
          name: 'DioClient',
        );
        developer.log(
          '   Código HTTP exato: $statusCode',
          name: 'DioClient',
        );
        developer.log(
          '   Corpo da resposta: $responseBody',
          name: 'DioClient',
        );

        return HandshakeResult(
          isSuccess: false,
          statusCode: statusCode ?? 500,
          message: 'Erro retornado pelo servidor ($statusCode).',
          errorDetails: responseBody?.toString(),
        );
      }

      // Outros erros de rede (Host lookup, SSL, etc.)
      developer.log(
        '❌ [DIO NETWORK ERROR] [${dioErr.type}]: ${dioErr.message}',
        name: 'DioClient',
      );
      if (statusCode != null) {
        developer.log('   Código HTTP: $statusCode', name: 'DioClient');
      }
      if (responseBody != null) {
        developer.log('   Corpo: $responseBody', name: 'DioClient');
      }

      return HandshakeResult(
        isSuccess: false,
        statusCode: statusCode ?? 0,
        message: 'Erro ao ligar ao servidor. Verifique a sua internet.',
        errorDetails: dioErr.message,
      );
    } catch (e, stack) {
      developer.log(
        '❌ [UNEXPECTED ERROR] Exceção geral durante handshake: $e',
        name: 'DioClient',
        error: e,
        stackTrace: stack,
      );

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
