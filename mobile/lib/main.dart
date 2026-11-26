import 'dart:async';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/localization/app_localizations_pt_ao.dart';
import 'core/network/app_environment_config.dart';
import 'core/services/app_config_service.dart';
import 'core/services/update_service.dart';
import 'core/theme/theme.dart';
import 'core/widgets/maintenance_mode_screen.dart';
import 'features/auth/auth_bloc.dart';
import 'features/catalog/customer_catalog_screens.dart';
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

  // Requisito 3: Tratamento seguro de exceções de renderização sem sobreposição de ecrãs nem ecrã preto
  ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
    developer.log(
      'Erro de renderização capturado: ${errorDetails.exceptionAsString()}',
      name: 'ErrorWidget.builder',
      error: errorDetails.exception,
      stackTrace: errorDetails.stack,
    );
    if (kDebugMode) {
      return ErrorWidget(errorDetails.exception);
    }
    return Material(
      color: Colors.white,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.storefront_rounded,
                  size: 48,
                  color: Color(0xFFEA1D2C),
                ),
                const SizedBox(height: 12),
                const Text(
                  'A carregar conteúdo da loja...',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  errorDetails.exceptionAsString(),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

  // Requisito 2: Encapsulamento em runZonedGuarded para proteger o arranque do APK
  runZonedGuarded(
    () async {
      // 1. Carregamento instantâneo do cache de parâmetros (Offline-First / 0ms)
      await AppConfigService.instance.loadCachedConfig();

      // Sincronização em segundo plano das configurações remotas (ETag HTTP 304)
      unawaited(
        AppConfigService.instance.syncWithRemote(
          customBaseUrl: AppEnvironmentConfig.baseHttpUrl,
        ),
      );

      // Instanciação dos serviços essenciais de infraestrutura e tokens
      final tokenStorage = SecureTokenStorage();
      final dio = createSecureDioClient(tokenStorage: tokenStorage);

      final authRepository = AuthRepository(
        dio: dio,
        baseUrl: '${AppEnvironmentConfig.baseHttpUrl}/api/v1/auth',
      );

      // Warm-up não bloqueante em segundo plano para acordar o contentor Render no arranque do APK
      unawaited(
        dio.get('${AppEnvironmentConfig.baseHttpUrl}/api/v1/health/').then((_) {
          developer.log('Servidor Render acordado e operacional.', name: 'Warmup');
        }).catchError((_) {}),
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
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class DeliveryApp extends StatefulWidget {
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
  State<DeliveryApp> createState() => _DeliveryAppState();
}

class _DeliveryAppState extends State<DeliveryApp> {
  @override
  void initState() {
    super.initState();
    // Inicialização do observador de ciclo de vida para verificação OTA / Kill Switch
    UpdateService.instance.initLifecycleObserver(navigatorKey: rootNavigatorKey);
  }

  @override
  void dispose() {
    UpdateService.instance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppConfigService.instance,
      builder: (context, _) {
        final configService = AppConfigService.instance;
        final dynamicTheme = configService.buildDynamicThemeData();

        // Injeta os BLoCs de infraestrutura no topo da árvore para evitar erros de ProviderNotFound
        return MultiBlocProvider(
          providers: [
            BlocProvider<AppInitializationBloc>(
              create: (_) => AppInitializationBloc(
                dio: widget.dio,
                tokenStorage: widget.tokenStorage,
              ),
            ),
            BlocProvider<AuthBloc>(
              create: (_) => AuthBloc(
                authRepository: widget.authRepository,
                tokenStorage: widget.tokenStorage,
              )..add(const CheckAuthStatusRequested()),
            ),
          ],
          child: RepositoryProvider<CatalogRepository>.value(
            value: CatalogRepository(
              dio: widget.dio,
              baseUrl: AppEnvironmentConfig.baseHttpUrl,
            ),
            child: MaterialApp(
              navigatorKey: rootNavigatorKey,
              title: configService.branding.appName.isNotEmpty
                  ? configService.branding.appName
                  : 'Delivery Ango_Ifood',
              debugShowCheckedModeBanner: false,
              locale: AppLocalizationsPtAo.locale,
              supportedLocales: const [
                AppLocalizationsPtAo.locale,
                Locale('pt', 'PT'),
                Locale('pt', 'BR'),
                Locale('en', 'US'),
              ],
              localizationsDelegates: const [
                AppLocalizationsPtAoDelegate(),
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: dynamicTheme,
              home: configService.isMaintenanceActive
                  ? MaintenanceModeScreen(message: configService.maintenanceMessage)
                  : const SplashScreen(),
            ),
          ),
        );
      },
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
    // Utiliza Material sólido para cobrir totalmente a tela com 100% de opacidade,
    // eliminando qualquer transparência que permitia ver os widgets de trás.
    return Material(
      color: const Color(0xFFF8FAFC),
      child: SafeArea(
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
                    decoration: const BoxDecoration(
                      color: Color(0x1FEF4444),
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
      );
  }
}
