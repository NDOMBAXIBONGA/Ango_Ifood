/// Arquitetura completa de Autenticação Passwordless via OTP em Flutter (`flutter_bloc` + `dio`).
///
/// Alinhada com o Backend Django REST Framework e com as Regras de Negócio:
/// - RN-001: Registo e login único por número de telemóvel (formato E.164).
/// - RN-002: Controlo de expiração (5 min), máximo de 5 tentativas e rate-limit de 3 envios/hora.
/// - RN-003: Validação de dados básicos e idade mínima (>= 18 anos) quando o utilizador está `PENDENTE`.
/// - RN-004: Recolha explícita de consentimentos (Termos, Privacidade, Marketing, Localização 2.º plano).
/// - RN-006: Gestão de tokens JWT (Access + Refresh) emitidos pelo SimpleJWT.
/// - RN-008: Tratamento de perfis suspensos/bloqueados (`403 Forbidden`).

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/app_environment_config.dart';
import 'storage/secure_token_storage.dart';

// ============================================================================
// 1. MODELOS DE DOMÍNIO E EXCEÇÕES DE AUTENTICAÇÃO
// ============================================================================

/// Representa o par de tokens JWT devolvido pelo SimpleJWT (RN-006).
@immutable
class AuthTokens extends Equatable {
  final String accessToken;
  final String refreshToken;

  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access'] as String,
      refreshToken: json['refresh'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'access': accessToken,
        'refresh': refreshToken,
      };

  @override
  List<Object?> get props => [accessToken, refreshToken];
}

/// Representa os dados resumidos do utilizador autenticado (RN-001, RN-003, RN-008).
@immutable
class AuthUser extends Equatable {
  final String id;
  final String telemovel;
  final String nome;
  final String email;
  final String estado; // ATIVO, PENDENTE, SUSPENSO
  final DateTime? dataNascimento;
  final DateTime dataCriacao;

  const AuthUser({
    required this.id,
    required this.telemovel,
    required this.nome,
    required this.email,
    required this.estado,
    this.dataNascimento,
    required this.dataCriacao,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String,
      telemovel: json['telemovel'] as String,
      nome: (json['nome'] as String?) ?? '',
      email: (json['email'] as String?) ?? '',
      estado: (json['estado'] as String?) ?? 'PENDENTE',
      dataNascimento: json['data_nascimento'] != null
          ? DateTime.tryParse(json['data_nascimento'] as String)
          : null,
      dataCriacao: DateTime.parse(json['data_criacao'] as String),
    );
  }

  @override
  List<Object?> get props => [
        id,
        telemovel,
        nome,
        email,
        estado,
        dataNascimento,
        dataCriacao,
      ];
}

/// Resposta estruturada do endpoint `/api/v1/auth/request-otp/` (RN-002).
@immutable
class OtpDispatchResult extends Equatable {
  final String telemovel;
  final DateTime expiraEm;
  final int validadeSegundos;
  final int tentativasRestantes;
  final int enviosRestantesHora;
  final String mensagem;

  const OtpDispatchResult({
    required this.telemovel,
    required this.expiraEm,
    required this.validadeSegundos,
    required this.tentativasRestantes,
    required this.enviosRestantesHora,
    required this.mensagem,
  });

  factory OtpDispatchResult.fromJson(Map<String, dynamic> json) {
    return OtpDispatchResult(
      telemovel: json['telemovel'] as String,
      expiraEm: DateTime.parse(json['expira_em'] as String),
      validadeSegundos: (json['validade_segundos'] as num?)?.toInt() ?? 300,
      tentativasRestantes: (json['tentativas_restantes'] as num?)?.toInt() ?? 5,
      enviosRestantesHora: (json['envios_restantes_hora'] as num?)?.toInt() ?? 0,
      mensagem: (json['mensagem'] as String?) ?? 'Código OTP enviado com sucesso.',
    );
  }

  @override
  List<Object?> get props => [
        telemovel,
        expiraEm,
        validadeSegundos,
        tentativasRestantes,
        enviosRestantesHora,
        mensagem,
      ];
}

/// Resposta estruturada dos endpoints `/api/v1/auth/verify-otp/` e `/api/v1/auth/complete-registration/`.
@immutable
class OtpVerificationResult extends Equatable {
  final bool requiresRegistrationCompletion;
  final AuthTokens tokens;
  final AuthUser user;
  final String mensagem;

  const OtpVerificationResult({
    required this.requiresRegistrationCompletion,
    required this.tokens,
    required this.user,
    required this.mensagem,
  });

  factory OtpVerificationResult.fromJson(Map<String, dynamic> json) {
    return OtpVerificationResult(
      requiresRegistrationCompletion:
          (json['requires_registration_completion'] as bool?) ?? false,
      tokens: AuthTokens.fromJson(json['tokens'] as Map<String, dynamic>),
      user: AuthUser.fromJson(json['utilizador'] as Map<String, dynamic>),
      mensagem: (json['mensagem'] as String?) ?? '',
    );
  }

  @override
  List<Object?> get props => [
        requiresRegistrationCompletion,
        tokens,
        user,
        mensagem,
      ];
}

/// Exceção de domínio para erros de autenticação, rate-limit (RN-002) ou suspensão (RN-008).
@immutable
class AuthApiException implements Exception {
  final String message;
  final String? errorCode;
  final int? statusCode;
  final int? remainingAttempts;
  final DateTime? blockedUntil;

  const AuthApiException({
    required this.message,
    this.errorCode,
    this.statusCode,
    this.remainingAttempts,
    this.blockedUntil,
  });

  @override
  String toString() =>
      'AuthApiException(statusCode: $statusCode, errorCode: $errorCode, message: $message)';
}

// ============================================================================
// 2. REPOSITÓRIO DE AUTENTICAÇÃO (AuthRepository com Dio)
// ============================================================================

class AuthRepository {
  final Dio _dio;

  AuthRepository({
    Dio? dio,
    String baseUrl = AppEnvironmentConfig.baseHttpUrl,
  }) : _dio = dio ??
            createSecureDioClient(
              tokenStorage: SecureTokenStorage(),
            );

  /// RN-001 / RN-002: Solicita o envio de um código OTP de 6 dígitos para o [phone].
  /// Comunica com `POST /api/v1/auth/request-otp/`.
  Future<OtpDispatchResult> requestOtp(String phone) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/auth/request-otp/',
        data: {'telemovel': phone.trim()},
      );

      final data = response.data;
      if (data == null) {
        throw const AuthApiException(
          message: 'Resposta vazia do servidor ao solicitar código OTP.',
        );
      }

      return OtpDispatchResult.fromJson(data);
    } on DioException catch (e) {
      throw _handleDioException(e);
    } catch (e) {
      if (e is AuthApiException) rethrow;
      throw AuthApiException(
        message: 'Erro inesperado ao solicitar OTP: $e',
      );
    }
  }

  /// RN-001 / RN-002 / RN-006: Valida o [code] OTP para o [phone].
  /// Comunica com `POST /api/v1/auth/verify-otp/`.
  Future<OtpVerificationResult> verifyOtp(String phone, String code) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/auth/verify-otp/',
        data: {
          'telemovel': phone.trim(),
          'codigo_otp': code.trim(),
        },
      );

      final data = response.data;
      if (data == null) {
        throw const AuthApiException(
          message: 'Resposta vazia do servidor ao verificar código OTP.',
        );
      }

      final result = OtpVerificationResult.fromJson(data);
      // Configura o header Authorization com o token JWT emitido (RN-006)
      _setAuthorizationHeader(result.tokens.accessToken);
      return result;
    } on DioException catch (e) {
      throw _handleDioException(e);
    } catch (e) {
      if (e is AuthApiException) rethrow;
      throw AuthApiException(
        message: 'Erro inesperado ao validar código OTP: $e',
      );
    }
  }

  /// RN-003 / RN-004: Completa os dados básicos obrigatórios de um utilizador com estado `PENDENTE`.
  /// Comunica com `POST /api/v1/auth/complete-registration/`.
  Future<OtpVerificationResult> completeRegistration({
    required String accessToken,
    required String nome,
    required String email,
    required DateTime dataNascimento,
    required bool termosUtilizacao,
    required bool politicaPrivacidade,
    bool marketing = false,
    bool localizacaoSegundoPlano = false,
  }) async {
    try {
      _setAuthorizationHeader(accessToken);

      final formattedBirthDate =
          '${dataNascimento.year.toString().padLeft(4, '0')}-'
          '${dataNascimento.month.toString().padLeft(2, '0')}-'
          '${dataNascimento.day.toString().padLeft(2, '0')}';

      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/auth/complete-registration/',
        data: {
          'nome': nome.trim(),
          'email': email.trim(),
          'data_nascimento': formattedBirthDate,
          'termos_utilizacao': termosUtilizacao,
          'politica_privacidade': politicaPrivacidade,
          'marketing': marketing,
          'localizacao_segundo_plano': localizacaoSegundoPlano,
        },
      );

      final data = response.data;
      if (data == null) {
        throw const AuthApiException(
          message: 'Resposta vazia do servidor ao concluir o registo.',
        );
      }

      final result = OtpVerificationResult.fromJson(data);
      _setAuthorizationHeader(result.tokens.accessToken);
      return result;
    } on DioException catch (e) {
      throw _handleDioException(e);
    } catch (e) {
      if (e is AuthApiException) rethrow;
      throw AuthApiException(
        message: 'Erro inesperado ao completar registo: $e',
      );
    }
  }

  void _setAuthorizationHeader(String accessToken) {
    _dio.options.headers['Authorization'] = 'Bearer $accessToken';
  }

  /// Converte falhas de rede, timeouts e erros de validação DRF (400, 403, 429, 500)
  /// numa instância tipada de [AuthApiException].
  AuthApiException _handleDioException(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const AuthApiException(
          message:
              'Tempo limite de ligação esgotado. Verifique a sua ligação à Internet e tente novamente.',
          errorCode: 'network_timeout',
        );
      case DioExceptionType.connectionError:
        return const AuthApiException(
          message:
              'Sem ligação ao servidor. Verifique se está ligado à Internet.',
          errorCode: 'connection_error',
        );
      case DioExceptionType.cancel:
        return const AuthApiException(
          message: 'O pedido foi cancelado.',
          errorCode: 'request_cancelled',
        );
      case DioExceptionType.badCertificate:
        return const AuthApiException(
          message: 'Falha de segurança na validação do certificado TLS (Secção 9.2).',
          errorCode: 'bad_certificate',
        );
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
      default:
        final statusCode = error.response?.statusCode;
        final responseData = error.response?.data;

        if (responseData is Map<String, dynamic>) {
          final errorCode = responseData['erro'] as String?;
          final detail = (responseData['detalhe'] ?? responseData['detail']) as String?;
          final tentativas = (responseData['tentativas_restantes'] as num?)?.toInt();
          final bloqueadoAteStr = responseData['bloqueado_ate'] as String?;
          final blockedUntil =
              bloqueadoAteStr != null ? DateTime.tryParse(bloqueadoAteStr) : null;

          if (detail != null && detail.isNotEmpty) {
            return AuthApiException(
              message: detail,
              errorCode: errorCode,
              statusCode: statusCode,
              remainingAttempts: tentativas,
              blockedUntil: blockedUntil,
            );
          }

          // Extrai erros de validação de campos do DRF (ex: telemovel, data_nascimento < 18 anos)
          final fieldErrors = <String>[];
          responseData.forEach((key, value) {
            if (value is List && value.isNotEmpty) {
              fieldErrors.add('${value.first}');
            } else if (value is String) {
              fieldErrors.add(value);
            }
          });

          if (fieldErrors.isNotEmpty) {
            return AuthApiException(
              message: fieldErrors.join('\n'),
              errorCode: errorCode ?? 'validation_error',
              statusCode: statusCode,
            );
          }
        }

        return AuthApiException(
          message: 'Erro de comunicação com o servidor (HTTP ${statusCode ?? 'desconhecido'}).',
          statusCode: statusCode,
        );
    }
  }
}

// ============================================================================
// 3. EVENTOS DO BLOC (AuthEvent)
// ============================================================================

@immutable
sealed class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

/// Evento disparado quando o utilizador solicita o envio do código OTP para o telemóvel (RN-001, RN-002).
final class RequestOtpEvent extends AuthEvent {
  final String phone;

  const RequestOtpEvent({required this.phone});

  @override
  List<Object?> get props => [phone];
}

/// Evento disparado quando o utilizador introduz o código OTP de 6 dígitos recebido por SMS (RN-002).
final class VerifyOtpEvent extends AuthEvent {
  final String phone;
  final String code;

  const VerifyOtpEvent({
    required this.phone,
    required this.code,
  });

  @override
  List<Object?> get props => [phone, code];
}

/// Evento disparado quando um novo utilizador (em estado `PENDENTE`) submete os dados básicos
/// obrigatórios (RN-003: idade >= 18 anos) e consentimentos (RN-004).
final class CompleteRegistrationEvent extends AuthEvent {
  final String accessToken;
  final String nome;
  final String email;
  final DateTime dataNascimento;
  final bool termosUtilizacao;
  final bool politicaPrivacidade;
  final bool marketing;
  final bool localizacaoSegundoPlano;

  const CompleteRegistrationEvent({
    required this.accessToken,
    required this.nome,
    required this.email,
    required this.dataNascimento,
    required this.termosUtilizacao,
    required this.politicaPrivacidade,
    this.marketing = false,
    this.localizacaoSegundoPlano = false,
  });

  @override
  List<Object?> get props => [
        accessToken,
        nome,
        email,
        dataNascimento,
        termosUtilizacao,
        politicaPrivacidade,
        marketing,
        localizacaoSegundoPlano,
      ];
}

// ============================================================================
// 4. ESTADOS DO BLOC (AuthState)
// ============================================================================

@immutable
sealed class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

/// Estado inicial antes de qualquer interação de autenticação.
final class AuthInitial extends AuthState {
  const AuthInitial();
}

/// Estado de carregamento durante chamadas assíncronas à API.
final class AuthLoading extends AuthState {
  const AuthLoading();
}

/// Estado emitido quando o SMS com o código OTP foi enviado com sucesso (RN-002).
final class OtpSendSuccess extends AuthState {
  final String phone;
  final DateTime expiresAt;
  final int remainingAttempts;
  final int remainingHourlySends;
  final String message;

  const OtpSendSuccess({
    required this.phone,
    required this.expiresAt,
    required this.remainingAttempts,
    required this.remainingHourlySends,
    required this.message,
  });

  @override
  List<Object?> get props => [
        phone,
        expiresAt,
        remainingAttempts,
        remainingHourlySends,
        message,
      ];
}

/// Estado emitido quando o utilizador está totalmente autenticado e com perfil ativo (RN-001, RN-006).
final class AuthAuthenticated extends AuthState {
  final AuthUser user;
  final AuthTokens tokens;

  const AuthAuthenticated({
    required this.user,
    required this.tokens,
  });

  @override
  List<Object?> get props => [user, tokens];
}

/// Estado emitido quando o OTP foi validado, mas o utilizador é novo (`PENDENTE`)
/// e necessita de completar Nome, Email, Data de Nascimento (>= 18 anos) e Consentimentos (RN-003, RN-004).
final class RegistrationRequired extends AuthState {
  final AuthUser pendingUser;
  final AuthTokens onboardingTokens;
  final String message;

  const RegistrationRequired({
    required this.pendingUser,
    required this.onboardingTokens,
    required this.message,
  });

  @override
  List<Object?> get props => [pendingUser, onboardingTokens, message];
}

/// Estado emitido em caso de erro de validação, OTP expirado/inválido, bloqueio (RN-002),
/// suspensão de conta (RN-008) ou falha de rede.
final class AuthError extends AuthState {
  final String message;
  final String? errorCode;
  final int? statusCode;
  final int? remainingAttempts;
  final DateTime? blockedUntil;

  const AuthError({
    required this.message,
    this.errorCode,
    this.statusCode,
    this.remainingAttempts,
    this.blockedUntil,
  });

  @override
  List<Object?> get props => [
        message,
        errorCode,
        statusCode,
        remainingAttempts,
        blockedUntil,
      ];
}

// ============================================================================
// 5. IMPLEMENTAÇÃO DO BLOC (AuthBloc)
// ============================================================================

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthRepository _authRepository;

  AuthBloc({required AuthRepository authRepository})
      : _authRepository = authRepository,
        super(const AuthInitial()) {
    on<RequestOtpEvent>(_onRequestOtp);
    on<VerifyOtpEvent>(_onVerifyOtp);
    on<CompleteRegistrationEvent>(_onCompleteRegistration);
  }

  /// Processa [RequestOtpEvent]:
  /// `AuthLoading` -> `OtpSendSuccess` | `AuthError`
  Future<void> _onRequestOtp(
    RequestOtpEvent event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      final dispatchResult = await _authRepository.requestOtp(event.phone);
      emit(
        OtpSendSuccess(
          phone: dispatchResult.telemovel,
          expiresAt: dispatchResult.expiraEm,
          remainingAttempts: dispatchResult.tentativasRestantes,
          remainingHourlySends: dispatchResult.enviosRestantesHora,
          message: dispatchResult.mensagem,
        ),
      );
    } on AuthApiException catch (e) {
      emit(
        AuthError(
          message: e.message,
          errorCode: e.errorCode,
          statusCode: e.statusCode,
          remainingAttempts: e.remainingAttempts,
          blockedUntil: e.blockedUntil,
        ),
      );
    } catch (e) {
      emit(
        AuthError(
          message: 'Não foi possível enviar o código OTP: $e',
        ),
      );
    }
  }

  /// Processa [VerifyOtpEvent]:
  /// `AuthLoading` -> `RegistrationRequired` (se novo/pendente) | `AuthAuthenticated` (se ativo) | `AuthError`
  Future<void> _onVerifyOtp(
    VerifyOtpEvent event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());
    try {
      final verificationResult = await _authRepository.verifyOtp(
        event.phone,
        event.code,
      );

      if (verificationResult.requiresRegistrationCompletion) {
        emit(
          RegistrationRequired(
            pendingUser: verificationResult.user,
            onboardingTokens: verificationResult.tokens,
            message: verificationResult.mensagem,
          ),
        );
      } else {
        emit(
          AuthAuthenticated(
            user: verificationResult.user,
            tokens: verificationResult.tokens,
          ),
        );
      }
    } on AuthApiException catch (e) {
      emit(
        AuthError(
          message: e.message,
          errorCode: e.errorCode,
          statusCode: e.statusCode,
          remainingAttempts: e.remainingAttempts,
          blockedUntil: e.blockedUntil,
        ),
      );
    } catch (e) {
      emit(
        AuthError(
          message: 'Erro ao validar o código OTP: $e',
        ),
      );
    }
  }

  /// Processa [CompleteRegistrationEvent]:
  /// Valida localmente a idade mínima de 18 anos (RN-003) e os consentimentos obrigatórios (RN-004)
  /// antes de submeter à API: `AuthLoading` -> `AuthAuthenticated` | `AuthError`
  Future<void> _onCompleteRegistration(
    CompleteRegistrationEvent event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading());

    // Validação preventiva no cliente para RN-003 (idade mínima de 18 anos)
    final hoje = DateTime.now();
    int idade = hoje.year - event.dataNascimento.year;
    if (hoje.month < event.dataNascimento.month ||
        (hoje.month == event.dataNascimento.month &&
            hoje.day < event.dataNascimento.day)) {
      idade--;
    }

    if (idade < 18) {
      emit(
        const AuthError(
          message:
              'RN-003: Tem de ter pelo menos 18 anos de idade para criar uma conta.',
          errorCode: 'underage_user',
          statusCode: 400,
        ),
      );
      return;
    }

    // Validação preventiva no cliente para RN-004 (consentimentos obrigatórios)
    if (!event.termosUtilizacao || !event.politicaPrivacidade) {
      emit(
        const AuthError(
          message:
              'RN-004: Deve aceitar os Termos de Utilização e a Política de Privacidade.',
          errorCode: 'missing_consents',
          statusCode: 400,
        ),
      );
      return;
    }

    try {
      final result = await _authRepository.completeRegistration(
        accessToken: event.accessToken,
        nome: event.nome,
        email: event.email,
        dataNascimento: event.dataNascimento,
        termosUtilizacao: event.termosUtilizacao,
        politicaPrivacidade: event.politicaPrivacidade,
        marketing: event.marketing,
        localizacaoSegundoPlano: event.localizacaoSegundoPlano,
      );

      emit(
        AuthAuthenticated(
          user: result.user,
          tokens: result.tokens,
        ),
      );
    } on AuthApiException catch (e) {
      emit(
        AuthError(
          message: e.message,
          errorCode: e.errorCode,
          statusCode: e.statusCode,
          remainingAttempts: e.remainingAttempts,
          blockedUntil: e.blockedUntil,
        ),
      );
    } catch (e) {
      emit(
        AuthError(
          message: 'Erro ao concluir o registo: $e',
        ),
      );
    }
  }
}
