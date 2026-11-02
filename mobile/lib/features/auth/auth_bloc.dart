/// Gestão de Estado da Autenticação utilizando o padrão BLoC (`flutter_bloc`).
/// Coordena o fluxo de login passwordless por SMS (OTP), validação de maioridade e persistência segura de tokens JWT.

import 'dart:developer' as developer;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'auth_event.dart';
import 'auth_repository.dart';
import 'auth_state.dart';
import 'storage/secure_token_storage.dart';

export 'auth_event.dart';
export 'auth_repository.dart';
export 'auth_state.dart';
export 'storage/secure_token_storage.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthRepository _authRepository;
  final ISecureTokenStorage _tokenStorage;

  AuthBloc({
    required AuthRepository authRepository,
    required ISecureTokenStorage tokenStorage,
  })  : _authRepository = authRepository,
        _tokenStorage = tokenStorage,
        super(const AuthInitial()) {
    on<CheckAuthStatusRequested>(_onCheckAuthStatusRequested);
    on<RequestOtpRequested>(_onRequestOtpRequested);
    on<VerifyOtpSubmitted>(_onVerifyOtpSubmitted);
    on<RegistrationFormSubmitted>(_onRegistrationFormSubmitted);
    on<LogoutRequested>(_onLogoutRequested);
  }

  /// Verifica se já existem credenciais válidas persistidas localmente no arranque da aplicação.
  Future<void> _onCheckAuthStatusRequested(
    CheckAuthStatusRequested event,
    Emitter<AuthState> emit,
  ) async {
    try {
      final hasToken = await _tokenStorage.hasValidToken();
      if (hasToken) {
        final accessToken = await _tokenStorage.getAccessToken();
        final refreshToken = await _tokenStorage.getRefreshToken();

        if (accessToken != null && refreshToken != null) {
          // Cria tokens e perfil mínimo para manter a sessão ativa
          final tokens = AuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
          );

          // Em produção, pode ser feita uma chamada a /api/v1/auth/me/ para obter o perfil atualizado
          final cachedUser = UserProfile(
            id: 'cached-session',
            telemovel: '',
            nome: 'Utilizador',
            email: '',
            estado: 'ATIVO',
          );

          emit(Authenticated(tokens: tokens, user: cachedUser));
          return;
        }
      }
      emit(const Unauthenticated());
    } catch (e) {
      developer.log('Erro ao checar status de autenticação: $e', name: 'AuthBloc', error: e);
      emit(const Unauthenticated());
    }
  }

  /// Manipula o pedido de código OTP por telemóvel (RN-001, RN-002).
  Future<void> _onRequestOtpRequested(
    RequestOtpRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading(loadingMessage: 'A solicitar código de verificação...'));
    try {
      final result = await _authRepository.requestOtp(event.phone);

      emit(
        OtpSendSuccess(
          phone: result.telemovel.isNotEmpty ? result.telemovel : event.phone,
          expiraEm: result.expiraEm,
          validadeMinutos: result.validadeMinutos,
          enviosRestantesNaHora: result.enviosRestantesNaHora,
        ),
      );
    } on OtpRateLimitException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
          bloqueadoAte: e.retryAfter,
          isRateLimited: true,
        ),
      );
    } on AccountSuspendedException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
        ),
      );
    } on AuthException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
        ),
      );
    } catch (e) {
      emit(
        OtpVerificationFailure(
          message: 'Falha inesperada ao pedir código OTP: $e',
        ),
      );
    }
  }

  /// Manipula a validação do código OTP de 6 dígitos introduzido pelo utilizador (RN-002).
  Future<void> _onVerifyOtpSubmitted(
    VerifyOtpSubmitted event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading(loadingMessage: 'A validar código OTP...'));
    try {
      final result = await _authRepository.verifyOtp(event.phone, event.code);

      if (result.isRegistrationRequired) {
        // O telemóvel foi validado, mas o utilizador precisa de preencher Nome, Email e Data de Nascimento
        emit(
          RegistrationRequired(
            phone: result.phone ?? event.phone,
            message: result.message,
          ),
        );
      } else if (result.tokens != null && result.userProfile != null) {
        // Utilizador já registado: persiste os tokens JWT no armazenamento seguro (RN-006)
        await _tokenStorage.saveTokens(
          accessToken: result.tokens!.accessToken,
          refreshToken: result.tokens!.refreshToken,
        );

        emit(
          Authenticated(
            tokens: result.tokens!,
            user: result.userProfile!,
          ),
        );
      } else {
        emit(
          const OtpVerificationFailure(
            message: 'Resposta de autenticação inválida do servidor.',
          ),
        );
      }
    } on InvalidOtpException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
          tentativasRestantes: e.tentativasRestantes,
          bloqueadoAte: e.bloqueadoAte,
        ),
      );
    } on OtpExpiredException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
        ),
      );
    } on OtpRateLimitException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
          bloqueadoAte: e.retryAfter,
          isRateLimited: true,
        ),
      );
    } on AccountSuspendedException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
        ),
      );
    } on AuthException catch (e) {
      emit(
        OtpVerificationFailure(
          message: e.message,
        ),
      );
    } catch (e) {
      emit(
        OtpVerificationFailure(
          message: 'Falha inesperada na validação do código: $e',
        ),
      );
    }
  }

  /// Manipula a conclusão do registo com validação de maioridade e consentimentos (RN-003, RN-004).
  Future<void> _onRegistrationFormSubmitted(
    RegistrationFormSubmitted event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading(loadingMessage: 'A criar a sua conta...'));
    try {
      final result = await _authRepository.completeRegistration(
        phone: event.phone,
        name: event.name,
        email: event.email,
        birthDate: event.birthDate,
        termsAccepted: event.termsAccepted,
        privacyAccepted: event.privacyAccepted,
        marketingAccepted: event.marketingAccepted,
      );

      if (result.tokens != null && result.userProfile != null) {
        // Persiste as credenciais JWT finais no dispositivo (RN-006)
        await _tokenStorage.saveTokens(
          accessToken: result.tokens!.accessToken,
          refreshToken: result.tokens!.refreshToken,
        );

        emit(
          Authenticated(
            tokens: result.tokens!,
            user: result.userProfile!,
          ),
        );
      } else {
        emit(
          const RegistrationFailure(
            message: 'Falha na emissão de credenciais após registo.',
          ),
        );
      }
    } on UnderageException catch (e) {
      emit(
        RegistrationFailure(
          message: e.message,
          isUnderage: true,
        ),
      );
    } on RegistrationValidationException catch (e) {
      emit(
        RegistrationFailure(
          message: e.message,
          fieldErrors: e.fieldErrors,
        ),
      );
    } on AuthException catch (e) {
      emit(
        RegistrationFailure(
          message: e.message,
        ),
      );
    } catch (e) {
      emit(
        RegistrationFailure(
          message: 'Falha inesperada na finalização do registo: $e',
        ),
      );
    }
  }

  /// Encerra a sessão atual e elimina os tokens do armazenamento seguro.
  Future<void> _onLogoutRequested(
    LogoutRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading(loadingMessage: 'A terminar sessão...'));
    try {
      await _tokenStorage.clearTokens();
    } catch (e) {
      developer.log('Erro ao limpar tokens no logout: $e', name: 'AuthBloc', error: e);
    }
    emit(const Unauthenticated(message: 'Sessão encerrada com sucesso.'));
  }
}

