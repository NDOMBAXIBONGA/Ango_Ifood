/// Gestão de Estado da Autenticação utilizando o padrão BLoC (`flutter_bloc`).
/// Coordena o fluxo de login passwordless por SMS (OTP), validação de maioridade e persistência segura de tokens JWT.

import 'dart:convert';
import 'dart:developer' as developer;
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'auth_event.dart';
import 'auth_repository.dart';
import 'auth_state.dart';
import 'exceptions/auth_exceptions.dart';
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
    on<RetryAuthRequested>(_onRetryAuthRequested);
    on<SendEmailOtpEvent>(_onSendEmailOtpEvent);
    on<VerifyEmailOtpSubmitted>(_onVerifyEmailOtpSubmitted);
    on<GoogleLoginSubmitted>(_onGoogleLoginSubmitted);
    on<LoginWithPasswordRequested>(_onLoginWithPasswordRequested);
    on<UpdateUserProfileEvent>(_onUpdateUserProfileEvent);
  }

  /// Guarda de forma atómica os tokens JWT, o papel funcional e o JSON completo do perfil.
  Future<void> _persistAuthenticatedSession({
    required AuthTokens tokens,
    required UserProfile user,
  }) async {
    await _tokenStorage.saveTokens(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      userRole: user.tipoUtilizador,
    );
    try {
      await _tokenStorage.saveUserProfileJson(jsonEncode(user.toJson()));
    } catch (_) {}
  }

  /// Extrai claims do payload JWT caso o JSON do perfil ainda não esteja em cache.
  UserProfile _decodeUserFromJwtOrFallback({
    required String jwtToken,
    String? storedRole,
  }) {
    try {
      final parts = jwtToken.split('.');
      if (parts.length == 3) {
        final normalized = base64Url.normalize(parts[1]);
        final payloadStr = utf8.decode(base64Url.decode(normalized));
        final payload = jsonDecode(payloadStr);
        if (payload is Map<String, dynamic>) {
          final nomeClaim = (payload['nome'] ?? '').toString().trim();
          return UserProfile(
            id: (payload['user_id'] ?? payload['id'] ?? 'cached-session').toString(),
            telemovel: (payload['telemovel'] ?? '').toString(),
            nome: nomeClaim.isNotEmpty ? nomeClaim : 'Cliente',
            email: (payload['email'] ?? '').toString(),
            estado: (payload['estado'] ?? 'ATIVO').toString(),
            tipoUtilizador: (payload['tipo_utilizador'] ?? storedRole ?? 'CLIENTE')
                .toString()
                .toUpperCase(),
          );
        }
      }
    } catch (_) {}
    return UserProfile(
      id: 'cached-session',
      telemovel: '',
      nome: 'Cliente',
      email: '',
      estado: 'ATIVO',
      tipoUtilizador: (storedRole ?? 'CLIENTE').toUpperCase(),
    );
  }

  void _onRetryAuthRequested(
    RetryAuthRequested event,
    Emitter<AuthState> emit,
  ) {
    emit(const AuthInitial());
  }

  /// Verifica se já existem credenciais válidas persistidas localmente no arranque da aplicação
  /// e sincroniza os dados reais do perfil a partir do backend (`/api/v1/auth/profile/`).
  Future<void> _onCheckAuthStatusRequested(
    CheckAuthStatusRequested event,
    Emitter<AuthState> emit,
  ) async {
    try {
      final hasToken = await _tokenStorage.hasValidToken();
      if (hasToken) {
        final accessToken = await _tokenStorage.getAccessToken();
        final refreshToken = await _tokenStorage.getRefreshToken() ?? '';
        final storedRole = await _tokenStorage.getUserRole();

        if (accessToken != null && accessToken.isNotEmpty) {
          final tokens = AuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
          );

          // 1. Tenta restaurar o perfil completo guardado localmente (0ms)
          UserProfile? cachedUser;
          final cachedJson = await _tokenStorage.getUserProfileJson();
          if (cachedJson != null && cachedJson.isNotEmpty) {
            try {
              final decoded = jsonDecode(cachedJson);
              if (decoded is Map<String, dynamic>) {
                cachedUser = UserProfile.fromJson(decoded);
              }
            } catch (_) {}
          }

          // 2. Se não houver JSON guardado, decodifica os claims do próprio token JWT (refresh/access)
          cachedUser ??= _decodeUserFromJwtOrFallback(
            jwtToken: refreshToken.isNotEmpty ? refreshToken : accessToken,
            storedRole: storedRole,
          );

          emit(Authenticated(tokens: tokens, user: cachedUser));

          // 3. Sincroniza o perfil atualizado diretamente com o backend (/api/v1/auth/profile/)
          final freshProfile = await _authRepository.fetchCurrentUserProfile(
            accessToken: accessToken,
          );
          if (freshProfile != null) {
            final latestAccess = await _tokenStorage.getAccessToken() ?? accessToken;
            final latestRefresh = await _tokenStorage.getRefreshToken() ?? refreshToken;
            final updatedTokens = AuthTokens(
              accessToken: latestAccess,
              refreshToken: latestRefresh,
            );
            await _persistAuthenticatedSession(
              tokens: updatedTokens,
              user: freshProfile,
            );
            emit(Authenticated(tokens: updatedTokens, user: freshProfile));
          }
          return;
        }
      }
      emit(const Unauthenticated());
    } catch (e) {
      developer.log('Erro ao checar status de autenticação: $e', name: 'AuthBloc', error: e);
      emit(const Unauthenticated());
    }
  }

  /// Atualiza o UserProfile em memória e no armazenamento seguro após edição no Perfil.
  Future<void> _onUpdateUserProfileEvent(
    UpdateUserProfileEvent event,
    Emitter<AuthState> emit,
  ) async {
    final current = state;
    if (current is Authenticated) {
      await _persistAuthenticatedSession(
        tokens: current.tokens,
        user: event.user,
      );
      emit(Authenticated(tokens: current.tokens, user: event.user));
    } else {
      final accessToken = await _tokenStorage.getAccessToken() ?? '';
      final refreshToken = await _tokenStorage.getRefreshToken() ?? '';
      if (accessToken.isNotEmpty) {
        final tokens = AuthTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
        );
        await _persistAuthenticatedSession(
          tokens: tokens,
          user: event.user,
        );
        emit(Authenticated(tokens: tokens, user: event.user));
      }
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
          otpHint: result.otpHint,
        ),
      );
    } on AccountAlreadyExistsException catch (e) {
      emit(
        AccountAlreadyExists(
          email: e.email.isNotEmpty ? e.email : event.phone,
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
    } on DioException catch (e) {
      final isNetwork = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError;

      developer.log(
        'Erro DioException em RequestOtpRequested: [${e.type}] ${e.message}',
        name: 'AuthBloc',
        error: e,
      );

      if (isNetwork) {
        emit(
          const AuthNetworkFailure(
            message: 'Falha Temporária de Conexão. Verifique a sua ligação com a internet e tente novamente.',
          ),
        );
      } else {
        emit(
          OtpVerificationFailure(
            message: e.response?.data?['detail']?.toString() ??
                e.message ??
                'Falha de comunicação com o servidor.',
          ),
        );
      }
    } on AuthException catch (e) {
      if (e is AuthNetworkException) {
        emit(
          AuthNetworkFailure(
            message: e.message,
          ),
        );
      } else {
        emit(
          OtpVerificationFailure(
            message: e.message,
          ),
        );
      }
    } catch (e) {
      emit(
        const AuthNetworkFailure(
          message: 'Falha Temporária de Conexão. Não foi possível contactar os servidores.',
        ),
      );
    }
  }

  /// Manipula o pedido de código OTP por e-mail (com código de 6 dígitos).
  Future<void> _onSendEmailOtpEvent(
    SendEmailOtpEvent event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading(loadingMessage: 'A enviar código de verificação para o e-mail...'));
    try {
      final result = await _authRepository.requestEmailOtp(event.email);

      emit(
        OtpSendSuccess(
          phone: event.email,
          expiraEm: result.expiraEm,
          validadeMinutos: result.validadeMinutos,
          enviosRestantesNaHora: result.enviosRestantesNaHora,
          otpHint: result.otpHint,
        ),
      );
    } on AccountAlreadyExistsException catch (e) {
      emit(
        AccountAlreadyExists(
          email: e.email.isNotEmpty ? e.email : event.email,
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
    } on DioException catch (e) {
      final isNetwork = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError;

      developer.log(
        'Erro DioException em SendEmailOtpEvent: [${e.type}] ${e.message}',
        name: 'AuthBloc',
        error: e,
      );

      if (isNetwork) {
        emit(
          const AuthNetworkFailure(
            message: 'Falha Temporária de Conexão. Verifique a sua ligação com a internet e tente novamente.',
          ),
        );
      } else {
        emit(
          OtpVerificationFailure(
            message: e.response?.data?['detail']?.toString() ??
                e.message ??
                'Falha de comunicação com o servidor ao enviar código para o e-mail.',
          ),
        );
      }
    } on AuthException catch (e) {
      if (e is AuthNetworkException) {
        emit(
          AuthNetworkFailure(
            message: e.message,
          ),
        );
      } else {
        emit(
          OtpVerificationFailure(
            message: e.message,
          ),
        );
      }
    } catch (e) {
      emit(
        const AuthNetworkFailure(
          message: 'Falha Temporária de Conexão. Não foi possível contactar os servidores.',
        ),
      );
    }
  }

  /// Manipula a validação do código OTP de 6 dígitos recebido por e-mail.
  Future<void> _onVerifyEmailOtpSubmitted(
    VerifyEmailOtpSubmitted event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading(loadingMessage: 'A validar código de confirmação...'));
    try {
      final result = await _authRepository.verifyEmailOtp(event.email, event.otp);
      if (result.isRegistrationRequired) {
        emit(OtpVerifiedSuccess(email: event.email));
      } else if (result.tokens != null && result.userProfile != null) {
        await _persistAuthenticatedSession(
          tokens: result.tokens!,
          user: result.userProfile!,
        );
        emit(Authenticated(tokens: result.tokens!, user: result.userProfile!));
      } else {
        emit(OtpVerifiedSuccess(email: event.email));
      }
    } on DioException catch (e) {
      final isNetwork = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError;

      developer.log(
        'Erro DioException em VerifyEmailOtpSubmitted: [${e.type}] ${e.message}',
        name: 'AuthBloc',
        error: e,
      );

      if (isNetwork) {
        emit(
          const AuthNetworkFailure(
            message: 'Falha Temporária de Conexão. Verifique a sua ligação com a internet e tente novamente.',
          ),
        );
      } else {
        emit(
          OtpVerificationFailure(
            message: e.response?.data?['detalhe']?.toString() ??
                e.response?.data?['detail']?.toString() ??
                'Falha ao validar código de confirmação.',
          ),
        );
      }
    } on AuthException catch (e) {
      if (e is AuthNetworkException) {
        emit(
          AuthNetworkFailure(
            message: e.message,
          ),
        );
      } else {
        emit(
          OtpVerificationFailure(
            message: e.message,
          ),
        );
      }
    } catch (e) {
      emit(
        OtpVerificationFailure(
          message: 'Erro inesperado ao validar código: $e',
        ),
      );
    }
  }

  /// Manipula a autenticação social com Google Sign-In.
  Future<void> _onGoogleLoginSubmitted(
    GoogleLoginSubmitted event,
    Emitter<AuthState> emit,
  ) async {
    if (event.token == null || event.token!.isEmpty) {
      emit(const OtpVerificationFailure(message: 'Autenticação Google cancelada ou sem token válido.'));
      return;
    }

    emit(const AuthLoading(loadingMessage: 'A autenticar com a Google...'));
    try {
      final result = await _authRepository.authenticateWithGoogle(event.token!);
      if (result.tokens != null && result.userProfile != null) {
        await _persistAuthenticatedSession(
          tokens: result.tokens!,
          user: result.userProfile!,
        );
        emit(Authenticated(tokens: result.tokens!, user: result.userProfile!));
      } else {
        emit(const OtpVerificationFailure(message: 'Resposta inválida do servidor ao autenticar com a Google.'));
      }
    } on AuthException catch (e) {
      emit(OtpVerificationFailure(message: e.message));
    } catch (e) {
      emit(OtpVerificationFailure(message: 'Erro ao validar login social com a Google: $e'));
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
        // Utilizador já registado: persiste os tokens JWT e perfil no armazenamento seguro (RN-006)
        await _persistAuthenticatedSession(
          tokens: result.tokens!,
          user: result.userProfile!,
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
    } on AccountAlreadyExistsException catch (e) {
      emit(
        AccountAlreadyExists(
          email: e.email.isNotEmpty ? e.email : event.phone,
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
      if (e is AuthNetworkException) {
        emit(
          AuthNetworkFailure(
            message: e.message,
          ),
        );
      } else {
        emit(
          OtpVerificationFailure(
            message: e.message,
          ),
        );
      }
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
        password: event.password,
        tipoUtilizador: event.tipoUtilizador,
        termsAccepted: event.termsAccepted,
        privacyAccepted: event.privacyAccepted,
        marketingAccepted: event.marketingAccepted,
      );

      if (result.tokens != null && result.userProfile != null) {
        // Persiste as credenciais JWT e perfil finais no dispositivo (RN-006)
        await _persistAuthenticatedSession(
          tokens: result.tokens!,
          user: result.userProfile!,
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

  /// Manipula a autenticação direta por e-mail e palavra-passe.
  Future<void> _onLoginWithPasswordRequested(
    LoginWithPasswordRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(const AuthLoading(loadingMessage: 'A verificar credenciais...'));
    try {
      final result = await _authRepository.loginWithPassword(
        email: event.email,
        password: event.password,
      );

      if (result.tokens != null && result.userProfile != null) {
        await _persistAuthenticatedSession(
          tokens: result.tokens!,
          user: result.userProfile!,
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
            message: 'Falha ao autenticar utilizador.',
          ),
        );
      }
    } on DioException catch (e) {
      final isNetwork = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.connectionError;

      if (isNetwork) {
        emit(
          const AuthNetworkFailure(
            message: 'Falha Temporária de Conexão. Verifique a sua ligação com a internet e tente novamente.',
          ),
        );
      } else {
        final erroMsg = e.response?.data?['detalhe']?.toString() ??
            e.response?.data?['detail']?.toString() ??
            e.response?.data?['erro']?.toString() ??
            'Credenciais inválidas. Verifique o seu e-mail e palavra-passe.';
        emit(OtpVerificationFailure(message: erroMsg));
      }
    } on AuthException catch (e) {
      emit(OtpVerificationFailure(message: e.message));
    } catch (e) {
      emit(OtpVerificationFailure(message: 'Erro inesperado: $e'));
    }
  }
}

