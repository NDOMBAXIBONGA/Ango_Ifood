import 'dart:async';

import 'package:delivery_mobile/core/network/app_environment_config.dart';
import 'package:delivery_mobile/features/auth/auth_repository.dart';
import 'package:delivery_mobile/features/auth/screens/phone_input_screen.dart';
import 'package:delivery_mobile/features/auth/screens/role_selection_onboarding_screen.dart';
import 'package:delivery_mobile/features/auth/storage/secure_token_storage.dart';
import 'package:delivery_mobile/features/splash/bloc/app_initialization_bloc.dart';
import 'package:delivery_mobile/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// ==============================================================================
/// INTERCEPTOR DE DIAGNÓSTICO E AUDITORIA DE REDE QA
/// ==============================================================================
class QaNetworkAuditInterceptor extends Interceptor {
  final List<NetworkAuditRecord> records = [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra['request_start_timestamp'] = DateTime.now().millisecondsSinceEpoch;
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final start = response.requestOptions.extra['request_start_timestamp'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    final latency = DateTime.now().millisecondsSinceEpoch - start;

    records.add(NetworkAuditRecord(
      url: response.requestOptions.uri.toString(),
      method: response.requestOptions.method,
      statusCode: response.statusCode ?? 200,
      latencyMs: latency,
      isSuccess: true,
      statusMessage: response.statusMessage ?? 'OK',
    ));
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final start = err.requestOptions.extra['request_start_timestamp'] as int? ??
        DateTime.now().millisecondsSinceEpoch;
    final latency = DateTime.now().millisecondsSinceEpoch - start;

    records.add(NetworkAuditRecord(
      url: err.requestOptions.uri.toString(),
      method: err.requestOptions.method,
      statusCode: err.response?.statusCode ?? 0,
      latencyMs: latency,
      isSuccess: false,
      statusMessage: '${err.type}: ${err.message}',
    ));
    super.onError(err, handler);
  }
}

class NetworkAuditRecord {
  final String url;
  final String method;
  final int statusCode;
  final int latencyMs;
  final bool isSuccess;
  final String statusMessage;

  NetworkAuditRecord({
    required this.url,
    required this.method,
    required this.statusCode,
    required this.latencyMs,
    required this.isSuccess,
    required this.statusMessage,
  });

  @override
  String toString() {
    return '[$method] $url -> HTTP $statusCode (${latencyMs}ms) - $statusMessage';
  }
}

/// ==============================================================================
/// SUITE DE TESTES DE INTEGRAÇÃO & CONECTIVIDADE RENDER
/// ==============================================================================
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('QA Integration: Render Cloud Connectivity & Navigation Flow', () {
    late SecureTokenStorage tokenStorage;
    late Dio dio;
    late QaNetworkAuditInterceptor auditInterceptor;
    late AuthRepository authRepository;

    setUp(() {
      tokenStorage = SecureTokenStorage();
      auditInterceptor = QaNetworkAuditInterceptor();

      // Configura cliente Dio com interceptor de auditoria e timeout de 10s
      dio = createSecureDioClient(tokenStorage: tokenStorage);
      dio.options.connectTimeout = const Duration(seconds: 10);
      dio.options.receiveTimeout = const Duration(seconds: 10);
      dio.interceptors.add(auditInterceptor);

      authRepository = AuthRepository(
        dio: dio,
        baseUrl: '${AppEnvironmentConfig.baseHttpUrl}/api/v1/auth',
      );
    });

    testWidgets(
      'Valida handshake de rede com o Render, integridade sem tela cinzenta e transição Onboarding -> Login',
      (WidgetTester tester) async {
        debugPrint('\n======================================================');
        debugPrint('[QA-TEST] A iniciar teste de integração com: ${AppEnvironmentConfig.baseHttpUrl}');
        debugPrint('======================================================\n');

        // Requisito 1: Inicializa o aplicativo móvel com injeção de dependências reais
        await tester.pumpWidget(
          DeliveryApp(
            dio: dio,
            tokenStorage: tokenStorage,
            authRepository: authRepository,
          ),
        );

        // Aguarda a renderização do SplashScreen inicial
        await tester.pump();

        // Limite de segurança: 10 segundos para conclusão do handshake
        final stopwatch = Stopwatch()..start();
        bool handshakeCompleted = false;

        while (stopwatch.elapsedMilliseconds < 10000) {
          await tester.pump(const Duration(milliseconds: 250));

          // Verifica se o RoleSelectionOnboardingScreen já substituiu o SplashScreen
          if (find.byType(RoleSelectionOnboardingScreen).evaluate().isNotEmpty) {
            handshakeCompleted = true;
            break;
          }

          // Se detetar erro explícito no SplashScreen, interrompe imediatamente
          if (find.textContaining('Falha de Conexão').evaluate().isNotEmpty) {
            break;
          }
        }
        stopwatch.stop();

        // Requisito 3: Se o handshake demorar > 10s ou falhar, emite relatório discriminado
        if (!handshakeCompleted) {
          final auditLogBuffer = StringBuffer();
          auditLogBuffer.writeln('\n=============================================================');
          auditLogBuffer.writeln('[QA-ERROR] FALHA DE CONEXÃO OU TIMEOUT (> 10s) COM O SERVIDOR');
          auditLogBuffer.writeln('Endpoint Alvo: ${AppEnvironmentConfig.baseHttpUrl}');
          auditLogBuffer.writeln('Tempo Decorrido: ${stopwatch.elapsedMilliseconds}ms');
          auditLogBuffer.writeln('-------------------------------------------------------------');
          auditLogBuffer.writeln('Registos de Auditoria HTTP (Dio):');
          for (final record in auditInterceptor.records) {
            auditLogBuffer.writeln('  $record');
          }
          auditLogBuffer.writeln('=============================================================\n');

          fail(auditLogBuffer.toString());
        }

        debugPrint('[QA-TEST] Handshake concluído em ${stopwatch.elapsedMilliseconds}ms.');

        // Requisito 2: Validação de ausência de tela cinzenta (Crash Fallback)
        expect(
          find.byType(GlobalCrashFallbackScreen),
          findsNothing,
          reason: 'O ecrã de fallback de crash (ecrã cinzento) foi disparado indevidamente.',
        );

        expect(
          find.byType(RoleSelectionOnboardingScreen),
          findsOneWidget,
          reason: 'O ecrã de seleção de papéis deve estar visível após o handshake bem-sucedido.',
        );

        // Simula o clique na opção "Quero Comprar"
        final cardClienteFinder = find.text('Quero Comprar');
        expect(cardClienteFinder, findsOneWidget);
        await tester.tap(cardClienteFinder);
        await tester.pumpAndSettle();

        // Localiza o botão principal de confirmação
        final continueButtonFinder = find.widgetWithText(
          FilledButton,
          'Continuar como Quero Comprar',
        );

        expect(
          continueButtonFinder,
          findsOneWidget,
          reason: 'O botão de submissão do onboarding deve estar presente no ecrã.',
        );

        // Executa o clique de transição para o ecrã de telefone
        await tester.tap(continueButtonFinder);
        await tester.pumpAndSettle();

        // Valida que a transição ocorreu com sucesso para PhoneInputScreen
        expect(
          find.byType(PhoneInputScreen),
          findsOneWidget,
          reason: 'A aplicação deve navegar para o PhoneInputScreen após clicar em continuar.',
        );

        // Confirma que não houve exceções de renderização ou tela cinzenta na transição
        expect(
          find.byType(GlobalCrashFallbackScreen),
          findsNothing,
          reason: 'Nenhum crash de transição assíncrona deve ocorrer na troca de ecrã.',
        );

        debugPrint('\n[QA-REPORT] Resumo de Conectividade de Rede:');
        for (final record in auditInterceptor.records) {
          debugPrint('  ✓ $record');
        }
        debugPrint('[QA-REPORT] Teste concluído com 100% de sucesso.\n');
      },
    );
  });
}
