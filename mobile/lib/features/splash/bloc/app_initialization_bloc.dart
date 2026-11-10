import 'dart:async';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_environment_config.dart';
import '../../auth/storage/secure_token_storage.dart';

// ==============================================================================
// 1. EVENTOS DO BLoC (AppInitializationEvent)
// ==============================================================================
abstract class AppInitializationEvent extends Equatable {
  const AppInitializationEvent();

  @override
  List<Object?> get props => [];
}

/// Disparado logo após o render do SplashScreen para arrancar as verificações de ecossistema
class InitializeAppConfig extends AppInitializationEvent {
  const InitializeAppConfig();
}

/// Disparado pelo utilizador ao clicar em "Tentar Novamente" em caso de falha de conexão
class RetryAppConfig extends AppInitializationEvent {
  const RetryAppConfig();
}

// ==============================================================================
// 2. ESTADOS DO BLoC (AppInitializationState)
// ==============================================================================
abstract class AppInitializationState extends Equatable {
  const AppInitializationState();

  @override
  List<Object?> get props => [];
}

class AppInitializationInitial extends AppInitializationState {
  const AppInitializationInitial();
}

class AppInitializationInProgress extends AppInitializationState {
  final String statusMessage;
  const AppInitializationInProgress({
    this.statusMessage = 'A conectar aos servidores cloud...',
  });

  @override
  List<Object?> get props => [statusMessage];
}

class AppInitializationSuccess extends AppInitializationState {
  final bool hasPersistedToken;

  const AppInitializationSuccess({
    required this.hasPersistedToken,
  });

  @override
  List<Object?> get props => [hasPersistedToken];
}

class AppInitializationFailure extends AppInitializationState {
  final String errorMessage;

  const AppInitializationFailure(this.errorMessage);

  @override
  List<Object?> get props => [errorMessage];
}

// ==============================================================================
// 3. IMPLEMENTAÇÃO DO BLOC (AppInitializationBloc)
// ==============================================================================
class AppInitializationBloc
    extends Bloc<AppInitializationEvent, AppInitializationState> {
  final Dio _dio;
  final ISecureTokenStorage _tokenStorage;

  AppInitializationBloc({
    required Dio dio,
    required ISecureTokenStorage tokenStorage,
  })  : _dio = dio,
        _tokenStorage = tokenStorage,
        super(const AppInitializationInitial()) {
    on<InitializeAppConfig>(_onInitializeAppConfig);
    on<RetryAppConfig>(_onRetryAppConfig);
  }

  Future<void> _onInitializeAppConfig(
    InitializeAppConfig event,
    Emitter<AppInitializationState> emit,
  ) async {
    await _performEcosystemHandshake(emit);
  }

  Future<void> _onRetryAppConfig(
    RetryAppConfig event,
    Emitter<AppInitializationState> emit,
  ) async {
    await _performEcosystemHandshake(emit);
  }

  /// Executa o handshake atómico de rede e validação do armazenamento local
  Future<void> _performEcosystemHandshake(
    Emitter<AppInitializationState> emit,
  ) async {
    // Passo 1: Verificar se o armazenamento seguro (KeyStore/KeyChain) responde (sub-10ms)
    bool hasToken = false;
    try {
      hasToken = await _tokenStorage.hasValidToken();
      developer.log(
        'Armazenamento seguro validado. Possui token: $hasToken',
        name: 'AppInitializationBloc',
      );
    } catch (e, stackTrace) {
      developer.log(
        'Falha crítica ao ler armazenamento seguro: $e',
        name: 'AppInitializationBloc',
        error: e,
        stackTrace: stackTrace,
      );
      emit(const AppInitializationFailure(
        'Falha de integridade no armazenamento seguro do dispositivo. Tente reiniciar a aplicação.',
      ));
      return;
    }

    // DISPARO ASSÍNCRONO NÃO-BLOQUEANTE DE WARM-UP (Render Cloud)
    // Desperta o contentor em background sem forçar o utilizador a esperar na Splash Screen
    final probeUrl = AppEnvironmentConfig.buildUrl('/api/v1/health/');
    unawaited(
      _dio.get(
        probeUrl,
        options: Options(
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          validateStatus: (status) => status != null && status < 500,
        ),
      ).then((r) {
        developer.log('⚡ Warm-up do servidor concluído em background (Status: ${r.statusCode})', name: 'AppInitializationBloc');
      }).catchError((err) {
        developer.log('⚠️ Warm-up background em andamento: $err', name: 'AppInitializationBloc');
      }),
    );

    // Se o utilizador NÃO possui sessão (ecrã inicial de boas-vindas / seleção de papel):
    // Entra IMEDIATAMENTE após animação visual fluida de 350ms!
    if (!hasToken) {
      await Future.delayed(const Duration(milliseconds: 350));
      emit(const AppInitializationSuccess(hasPersistedToken: false));
      return;
    }

    // Se possui token guardado, faz verificação rápida de conectividade (máximo 4s)
    emit(const AppInitializationInProgress(
      statusMessage: 'A sincronizar dados da sua conta...',
    ));

    try {
      final response = await _dio.get(
        probeUrl,
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final statusCode = response.statusCode ?? 200;
      developer.log(
        'Sincronização rápida bem-sucedida. HTTP Status: $statusCode',
        name: 'AppInitializationBloc',
      );
    } catch (e) {
      developer.log(
        'Aviso: Servidor a acordar em background. A permitir entrada imediata com sessão guardada.',
        name: 'AppInitializationBloc',
      );
    }

    await Future.delayed(const Duration(milliseconds: 250));
    emit(const AppInitializationSuccess(hasPersistedToken: true));
  }
}

