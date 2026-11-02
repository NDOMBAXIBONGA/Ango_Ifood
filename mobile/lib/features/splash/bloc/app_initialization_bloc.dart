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

    // Passo 2: Testar handshake HTTP/SSL com a URL de produção no Render (15s timeout)
    try {
      final probeUrl = AppEnvironmentConfig.buildUrl('/api/v1/catalog/public/');
      developer.log('A executar probe de handshake em: $probeUrl (Timeout: 15s)', name: 'AppInitializationBloc');

      final response = await _dio.get(
        probeUrl,
        options: Options(
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          // Qualquer status retornado pelo servidor comprova conectividade HTTP e handshake SSL OK
          validateStatus: (status) => status != null,
        ),
      );

      final statusCode = response.statusCode ?? 200;
      developer.log(
        'Handshake com Render bem-sucedido. HTTP Status: $statusCode',
        name: 'AppInitializationBloc',
      );

      // Aguarda um instante para animação fluida da tela de splash
      await Future.delayed(const Duration(milliseconds: 400));

      emit(AppInitializationSuccess(hasPersistedToken: hasToken));
    } on DioException catch (dioErr) {
      final statusCode = dioErr.response?.statusCode;
      final responseBody = dioErr.response?.data;

      developer.log(
        '❌ [DIO HANDSHAKE ERROR] Tipo: ${dioErr.type} | Mensagem: ${dioErr.message}',
        name: 'AppInitializationBloc',
        error: dioErr,
      );

      if (statusCode != null) {
        developer.log(
          '   [HTTP STATUS CODE] $statusCode',
          name: 'AppInitializationBloc',
        );
      }
      if (responseBody != null) {
        developer.log(
          '   [RESPONSE BODY] $responseBody',
          name: 'AppInitializationBloc',
        );
      }

      String errorMessage = 'Erro ao ligar ao servidor. Verifique a sua internet.';

      if (dioErr.type == DioExceptionType.connectionTimeout ||
          dioErr.type == DioExceptionType.receiveTimeout ||
          dioErr.type == DioExceptionType.sendTimeout) {
        errorMessage = 'Tempo de resposta excedido (15s). O servidor Render pode estar a inicializar (Cold Start). Tente novamente.';
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
}

