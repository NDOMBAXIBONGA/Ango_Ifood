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
    emit(const AppInitializationInProgress(
      statusMessage: 'A verificar integridade e armazenamento local...',
    ));

    // Passo 1: Verificar se o armazenamento seguro (KeyStore/KeyChain) responde
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

    emit(const AppInitializationInProgress(
      statusMessage: 'A estabelecer ligação segura com o Render Cloud...',
    ));

    // Passo 2: Testar handshake HTTP/SSL com endpoint leve de saúde no Render (/api/v1/health/)
    try {
      final probeUrl = AppEnvironmentConfig.buildUrl('/api/v1/health/');
      developer.log('A executar probe de handshake em: $probeUrl (Timeout: 20s)', name: 'AppInitializationBloc');

      final response = await _dio.get(
        probeUrl,
        options: Options(
          sendTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final statusCode = response.statusCode ?? 200;
      developer.log(
        'Handshake com Render bem-sucedido. HTTP Status: $statusCode',
        name: 'AppInitializationBloc',
      );

      await Future.delayed(const Duration(milliseconds: 300));
      emit(AppInitializationSuccess(hasPersistedToken: hasToken));
    } on DioException catch (dioErr) {
      final statusCode = dioErr.response?.statusCode;
      final responseBody = dioErr.response?.data;

      developer.log(
        '❌ [DIO HANDSHAKE ERROR] Tipo: ${dioErr.type} | Mensagem: ${dioErr.message}',
        name: 'AppInitializationBloc',
        error: dioErr,
      );

      // Tratamento específico de Cold Start / Sleep do Render: Tenta o loop de despertar
      final isTimeout = dioErr.type == DioExceptionType.connectionTimeout ||
          dioErr.type == DioExceptionType.receiveTimeout ||
          dioErr.type == DioExceptionType.sendTimeout ||
          dioErr.type == DioExceptionType.connectionError;

      if (isTimeout) {
        emit(const AppInitializationInProgress(
          statusMessage: 'A acordar o servidor cloud no Render...',
        ));

        // Corrotina de pings intermitentes para acordar o servidor adormecido
        final awake = await _wakeUpRenderLoop(emit);
        if (awake) {
          emit(AppInitializationSuccess(hasPersistedToken: hasToken));
          return;
        }
      }

      String errorMessage = 'Erro ao ligar ao servidor. Verifique a sua internet.';

      if (isTimeout) {
        errorMessage = 'O servidor Render está a acordar (Cold Start). Toque em "Tentar Novamente" para sincronizar.';
      } else if (dioErr.type == DioExceptionType.badResponse) {
        errorMessage = 'Servidor respondeu com código $statusCode. Tente novamente em instantes.';
      }

      emit(AppInitializationFailure(errorMessage));
    } catch (e, stack) {
      developer.log(
        'Exceção inesperada no handshake: $e',
        name: 'AppInitializationBloc',
        error: e,
        stackTrace: stack,
      );

      emit(const AppInitializationFailure(
        'Erro ao ligar ao servidor. Verifique a sua internet.',
      ));
    }
  }

  /// Corrotina assíncrona de pings repetidos a /api/v1/health/ para acordar contentores adormecidos
  Future<bool> _wakeUpRenderLoop(Emitter<AppInitializationState> emit) async {
    final healthUrl = AppEnvironmentConfig.buildUrl('/api/v1/health/');
    final stopwatch = Stopwatch()..start();
    int attempt = 0;

    developer.log('🚀 A iniciar loop de despertar do Render...', name: 'AppInitializationBloc');

    while (stopwatch.elapsedMilliseconds < 50000) {
      attempt++;
      final elapsedSec = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(0);

      emit(AppInitializationInProgress(
        statusMessage: 'A acordar servidor no Render (${elapsedSec}s decorridos)...',
      ));

      try {
        final pingResponse = await _dio.get(
          healthUrl,
          options: Options(
            sendTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 6),
            validateStatus: (status) => status != null && status < 500,
          ),
        );

        if (pingResponse.statusCode != null && pingResponse.statusCode! < 500) {
          developer.log(
            '✅ Servidor Render acordou após ${elapsedSec}s e $attempt tentativas!',
            name: 'AppInitializationBloc',
          );
          return true;
        }
      } catch (_) {
        // Contentor ainda a inicializar
      }

      await Future.delayed(const Duration(seconds: 2));
    }

    return false;
  }
}

