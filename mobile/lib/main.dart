import 'dart:async';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/localization/app_localizations_pt_ao.dart';
import 'core/network/app_environment_config.dart';
import 'features/auth/auth_bloc.dart';
import 'features/auth/auth_repository.dart';
import 'features/auth/screens/role_selection_onboarding_screen.dart';
import 'features/auth/storage/secure_token_storage.dart';
import 'features/splash/bloc/app_initialization_bloc.dart';
import 'features/splash/screens/splash_screen.dart';

// ==============================================================================
// 1. PONTO DE ENTRADA E CAPTURA GLOBAL DE ERROS (runZonedGuarded)
// ==============================================================================
void main() {
  // Requisito 1: Vinculação assíncrona do framework antes de qualquer lógica
  WidgetsFlutterBinding.ensureInitialized();

  // Requisito 4: Captura de exceções e erros de renderização no Flutter Framework
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    developer.log(
      'FlutterError capturado pelo pipeline global: ${details.exceptionAsString()}',
      name: 'FlutterError.onError',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  // Requisito 3: Substituição do ecrã cinzento nativo (Blank/Grey Screen Crash)
  ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
    return GlobalCrashFallbackScreen(errorDetails: errorDetails);
  };

  // Requisito 2: Encapsulamento em runZonedGuarded para proteger o arranque do APK
  runZonedGuarded(
    () {
      // Instanciação dos serviços essenciais de infraestrutura e tokens
      final tokenStorage = SecureTokenStorage();
      final dio = createSecureDioClient(tokenStorage: tokenStorage);

      final authRepository = AuthRepository(
        dio: dio,
        baseUrl: '${AppEnvironmentConfig.baseHttpUrl}/api/v1/auth',
      );

      runApp(
        DeliveryApp(
          dio: dio,
          tokenStorage: tokenStorage,
          authRepository: authRepository,
        ),
      );
    },
    (Object error, StackTrace stackTrace) {
      developer.log(
        'Exceção assíncrona capturada em runZonedGuarded: $error',
        name: 'runZonedGuarded',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

// ==============================================================================
// 2. APLICAÇÃO PRINCIPAL (DeliveryApp)
// ==============================================================================
class DeliveryApp extends StatelessWidget {
  final Dio dio;
  final ISecureTokenStorage tokenStorage;
  final AuthRepository authRepository;

  const DeliveryApp({
    super.key,
    required this.dio,
    required this.tokenStorage,
    required this.authRepository,
  });

  @override
  Widget build(BuildContext context) {
    // Injeta os BLoCs de infraestrutura no topo da árvore para evitar erros de ProviderNotFound
    return MultiBlocProvider(
      providers: [
        BlocProvider<AppInitializationBloc>(
          create: (_) => AppInitializationBloc(
            dio: dio,
            tokenStorage: tokenStorage,
          ),
        ),
        BlocProvider<AuthBloc>(
          create: (_) => AuthBloc(
            authRepository: authRepository,
            tokenStorage: tokenStorage,
          )..add(const CheckAuthStatusRequested()),
        ),
      ],
      child: MaterialApp(
        title: 'Delivery Ango_Ifood',
        debugShowCheckedModeBanner: false,
        locale: AppLocalizationsPtAo.locale,
        supportedLocales: const [
          AppLocalizationsPtAo.locale,
        ],
        localizationsDelegates: const [
          AppLocalizationsPtAoDelegate(),
        ],
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFFEA1D2C),
          scaffoldBackgroundColor: const Color(0xFFF8FAFC),
          fontFamily: 'Roboto',
        ),
        home: const SplashScreen(),
      ),
    );
  }
}

// ==============================================================================
// 3. ECRÃ VISUAL DE FALLBACK EM CASO DE CRASH (GlobalCrashFallbackScreen)
// ==============================================================================
/// Substitui o ecrã cinzento nativo por uma interface profissional em português
/// com diagnóstico amigável e botão para reiniciar/tentar novamente.
class GlobalCrashFallbackScreen extends StatelessWidget {
  final FlutterErrorDetails errorDetails;

  const GlobalCrashFallbackScreen({
    super.key,
    required this.errorDetails,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Ícone de Alerta com cor de destaque
                  Container(
                    width: 88.0,
                    height: 88.0,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.wifi_off_rounded,
                      size: 44.0,
                      color: Color(0xFFEF4444),
                    ),
                  ),
                  const SizedBox(height: 24.0),

                  // Título amigável
                  const Text(
                    'Falha Temporária de Conexão',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22.0,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 12.0),

                  // Mensagem explicativa
                  const Text(
                    'Não foi possível inicializar os serviços de rede ou conectar aos servidores em nuvem. '
                    'Verifique a sua ligação à Internet ou tente novamente.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.5,
                      color: Color(0xFF64748B),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 32.0),

                  // Botão Intuitivo "Tentar Novamente"
                  SizedBox(
                    width: double.infinity,
                    height: 52.0,
                    child: FilledButton.icon(
                      onPressed: () {
                        // Reinicia o fluxo navegando de volta para a raiz
                        main();
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFEA1D2C),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14.0),
                        ),
                        elevation: 0,
                      ),
                      icon: const Icon(Icons.refresh_rounded, size: 20.0),
                      label: const Text(
                        'Tentar Novamente',
                        style: TextStyle(
                          fontSize: 16.0,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),

                  // Detalhe técnico visível apenas se em modo de desenvolvimento (kDebugMode)
                  if (kDebugMode) ...[
                    const SizedBox(height: 24.0),
                    Container(
                      padding: const EdgeInsets.all(12.0),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                      child: Text(
                        errorDetails.exceptionAsString(),
                        style: const TextStyle(
                          fontSize: 11.0,
                          fontFamily: 'monospace',
                          color: Color(0xFF334155),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
