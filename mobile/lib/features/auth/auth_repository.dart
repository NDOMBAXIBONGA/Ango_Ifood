/// Repositório de Dados de Autenticação (`AuthRepository`).
/// Comunica diretamente com a API REST Django utilizando o cliente HTTP `Dio`.
///
/// Implementa as regras de negócio:
/// - RN-001: Formato internacional do telemóvel E.164.
/// - RN-002: Verificação OTP, rate-limit de 3 envios por hora (HTTP 429), bloqueio de 15 min e expiração de 5 min (HTTP 400).
/// - RN-003: Validação estrita de maioridade (>= 18 anos civis) e unicidade de e-mail.
/// - RN-004: Aceitação de consentimentos mandatórios.
/// - RN-006: Receção e mapeamento dos tokens JWT de Acesso e Refresh (SimpleJWT).
/// - RN-008: Tratamento de contas suspensas (HTTP 403 Forbidden).

import 'dart:developer' as developer;
import 'package:dio/dio.dart';

import 'exceptions/auth_exceptions.dart';
import 'models/auth_models.dart';

export 'exceptions/auth_exceptions.dart';
export 'models/auth_models.dart';

import '../../core/network/app_environment_config.dart';

class AuthRepository {
  final Dio _dio;
  final String _baseUrl;

  static final String _defaultBaseUrl = '${AppEnvironmentConfig.baseHttpUrl}/api/v1/auth';

  AuthRepository({
    Dio? dio,
    String? baseUrl,
  })  : _baseUrl = baseUrl ?? _defaultBaseUrl,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 35),
                receiveTimeout: const Duration(seconds: 35),
                sendTimeout: const Duration(seconds: 35),
                headers: {
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
              ),
            );

  /// Constrói URLs de endpoints de forma segura, eliminando barras duplas ('//')
  /// e garantindo estritamente a barra final ('/') requerida pelo Django (APPEND_SLASH = True).
  String _buildUrl(String path) {
    final cleanBase = _baseUrl.endsWith('/')
        ? _baseUrl.substring(0, _baseUrl.length - 1)
        : _baseUrl;
    var cleanPath = path.startsWith('/') ? path.substring(1) : path;
    if (!cleanPath.endsWith('/')) {
      cleanPath = '$cleanPath/';
    }
    return '$cleanBase/$cleanPath';
  }

  /// Endpoint 1: `POST /api/v1/auth/request-otp/`
  /// Solicita o envio de um código OTP de 6 dígitos para o número de telemóvel informado (RN-001, RN-002).
  Future<OtpRequestResult> requestOtp(String phone) async {
    try {
      final sanitizedPhone = phone.trim().replaceAll(' ', '');
      developer.log('Solicitando OTP para: $sanitizedPhone', name: 'AuthRepository');

      final response = await _dio.post(
        _buildUrl('request-otp'),
        data: {'telemovel': sanitizedPhone},
      );

      final data = response.data as Map<String, dynamic>;
      return OtpRequestResult.fromJson(data);
    } on DioException catch (e) {
      developer.log('Erro ao solicitar OTP: ${e.response?.statusCode} - ${e.message}',
          name: 'AuthRepository', error: e);
      throw _handleDioException(e);
    } catch (e) {
      developer.log('Erro inesperado em requestOtp: $e', name: 'AuthRepository', error: e);
      throw AuthServerException(message: 'Erro inesperado ao solicitar código OTP: $e');
    }
  }

  /// Endpoint 1b: `POST /api/v1/auth/email/request/` (com trailing slash obrigatória)
  /// Solicita o envio de um código OTP de 6 dígitos para o endereço de e-mail informado via Brevo.
  Future<OtpRequestResult> requestEmailOtp(String email) async {
    final sanitizedEmail = email.trim().toLowerCase();
    try {
      developer.log('Solicitando OTP para e-mail: $sanitizedEmail', name: 'AuthRepository');

      final response = await _dio.post(
        _buildUrl('email/request'),
        data: {
          'email': sanitizedEmail,
        },
      );

      final data = response.data as Map<String, dynamic>;
      return OtpRequestResult.fromJson(data);
    } on DioException catch (e) {
      // Fallback seguro caso o endpoint dedicado ainda não esteja ativo
      if (e.response?.statusCode == 404) {
        try {
          final fallback = await _dio.post(
            _buildUrl('request-otp'),
            data: {
              'email': sanitizedEmail,
              'telemovel': sanitizedEmail,
            },
          );
          final data = fallback.data as Map<String, dynamic>;
          return OtpRequestResult.fromJson(data);
        } catch (_) {}
      }
      developer.log('Erro ao solicitar OTP por e-mail: ${e.response?.statusCode} - ${e.message}',
          name: 'AuthRepository', error: e);
      throw _handleDioException(e);
    } catch (e) {
      developer.log('Erro inesperado em requestEmailOtp: $e', name: 'AuthRepository', error: e);
      throw AuthServerException(message: 'Erro inesperado ao solicitar código OTP por e-mail: $e');
    }
  }

  /// Endpoint 1c: `POST /api/v1/auth/email/verify/`
  /// Valida o código OTP de 6 dígitos enviado por e-mail.
  Future<bool> verifyEmailOtp(String email, String code) async {
    final sanitizedEmail = email.trim().toLowerCase();
    final sanitizedCode = code.trim();
    try {
      developer.log('Verificando OTP para e-mail: $sanitizedEmail', name: 'AuthRepository');

      final response = await _dio.post(
        _buildUrl('email/verify'),
        data: {
          'email': sanitizedEmail,
          'codigo_otp': sanitizedCode,
        },
      );

      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data['is_verificado'] == true || data['sucesso'] == true;
      }
      return response.statusCode == 200;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        try {
          final fallback = await _dio.post(
            _buildUrl('verify-otp'),
            data: {
              'telemovel': sanitizedEmail,
              'codigo_otp': sanitizedCode,
            },
          );
          return fallback.statusCode == 200;
        } catch (_) {}
      }
      developer.log('Erro ao verificar OTP por e-mail: ${e.response?.statusCode} - ${e.message}',
          name: 'AuthRepository', error: e);
      throw _handleDioException(e);
    } catch (e) {
      developer.log('Erro inesperado em verifyEmailOtp: $e', name: 'AuthRepository', error: e);
      throw AuthServerException(message: 'Erro inesperado ao validar código OTP: $e');
    }
  }

  /// Endpoint 2: `POST /api/v1/auth/verify-otp/`
  /// Valida o código OTP submetido. Emite tokens JWT se o utilizador já existir (RN-006)
  /// ou devolve `isRegistrationRequired=true` para novos utilizadores (RN-002).
  Future<AuthResult> verifyOtp(String phone, String code) async {
    try {
      final sanitizedPhone = phone.trim().replaceAll(' ', '');
      final sanitizedCode = code.trim();

      developer.log('Verificando OTP para: $sanitizedPhone', name: 'AuthRepository');

      final response = await _dio.post(
        _buildUrl('verify-otp'),
        data: {
          'telemovel': sanitizedPhone,
          'codigo_otp': sanitizedCode,
        },
      );

      final data = response.data as Map<String, dynamic>;
      return AuthResult.fromVerifyOtpJson(data, sanitizedPhone);
    } on DioException catch (e) {
      developer.log('Erro ao verificar OTP: ${e.response?.statusCode} - ${e.message}',
          name: 'AuthRepository', error: e);
      throw _handleDioException(e);
    } catch (e) {
      developer.log('Erro inesperado em verifyOtp: $e', name: 'AuthRepository', error: e);
      throw AuthServerException(message: 'Erro inesperado ao validar código OTP: $e');
    }
  }

  /// Endpoint 3: `POST /api/v1/auth/complete-registration/`
  /// Finaliza o registo de utilizadores com telemóvel validado (RN-003, RN-004).
  /// Valida maioridade estrita de 18 anos civis no backend e recebe os tokens JWT finais.
  Future<AuthResult> completeRegistration({
    required String phone,
    required String name,
    required String email,
    required DateTime birthDate,
    String? password,
    String tipoUtilizador = 'CLIENTE',
    bool termsAccepted = true,
    bool privacyAccepted = true,
    bool marketingAccepted = false,
  }) async {
    try {
      final isEmailPhone = phone.contains('@');
      final sanitizedPhone = isEmailPhone ? null : phone.trim().replaceAll(' ', '');
      final sanitizedEmail = email.trim().toLowerCase();
      final formattedBirthDate =
          '${birthDate.year.toString().padLeft(4, '0')}-${birthDate.month.toString().padLeft(2, '0')}-${birthDate.day.toString().padLeft(2, '0')}';

      developer.log(
        'Completando registo: phone=$sanitizedPhone | email=$sanitizedEmail | name=$name | birth=$formattedBirthDate | tipo=$tipoUtilizador',
        name: 'AuthRepository',
      );

      final payload = <String, dynamic>{
        'nome': name.trim(),
        'email': sanitizedEmail,
        'data_nascimento': formattedBirthDate,
        'tipo_utilizador': tipoUtilizador,
        'termos_utilizacao': termsAccepted,
        'politica_privacidade': privacyAccepted,
        'marketing': marketingAccepted,
      };
      if (sanitizedPhone != null && sanitizedPhone.isNotEmpty) {
        payload['telemovel'] = sanitizedPhone;
      }
      if (password != null && password.isNotEmpty) {
        payload['password'] = password;
      }

      final response = await _dio.post(
        _buildUrl('complete-registration'),
        data: payload,
      );

      final data = response.data as Map<String, dynamic>;
      return AuthResult.fromCompleteRegistrationJson(data);
    } on DioException catch (e) {
      developer.log('Erro ao completar registo: ${e.response?.statusCode} - ${e.message}',
          name: 'AuthRepository', error: e);
      throw _handleDioException(e);
    } catch (e) {
      developer.log('Erro inesperado em completeRegistration: $e', name: 'AuthRepository', error: e);
      throw AuthServerException(message: 'Erro inesperado ao finalizar registo: $e');
    }
  }

  /// Endpoint: `POST /api/v1/auth/google/`
  /// Valida o ID Token do Google Sign-In junto da API Django e devolve os tokens de sessão JWT.
  Future<AuthResult> authenticateWithGoogle(String token) async {
    try {
      developer.log('Enviando token Google ao backend Django...', name: 'AuthRepository');
      final response = await _dio.post(
        _buildUrl('google'),
        data: {'token': token},
      );

      final data = response.data as Map<String, dynamic>;
      return AuthResult.fromCompleteRegistrationJson(data);
    } on DioException catch (e) {
      developer.log(
        'Erro ao validar token Google no backend: ${e.response?.statusCode} - ${e.message}',
        name: 'AuthRepository',
        error: e,
      );
      throw _handleDioException(e);
    } catch (e) {
      developer.log('Erro inesperado em authenticateWithGoogle: $e', name: 'AuthRepository', error: e);
      throw AuthServerException(message: 'Erro inesperado na validação do login Google: $e');
    }
  }

  /// Endpoint: `POST /api/v1/auth/login/`
  /// Autentica diretamente o utilizador por e-mail e palavra-passe.
  Future<AuthResult> loginWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      final sanitizedEmail = email.trim().toLowerCase();
      developer.log('Efetuando login com palavra-passe para: $sanitizedEmail', name: 'AuthRepository');

      final response = await _dio.post(
        _buildUrl('login'),
        data: {
          'email': sanitizedEmail,
          'password': password,
        },
      );

      final data = response.data as Map<String, dynamic>;
      return AuthResult.fromCompleteRegistrationJson(data);
    } on DioException catch (e) {
      developer.log(
        'Erro ao autenticar com palavra-passe: ${e.response?.statusCode} - ${e.message}',
        name: 'AuthRepository',
        error: e,
      );
      throw _handleDioException(e);
    } catch (e) {
      developer.log('Erro inesperado em loginWithPassword: $e', name: 'AuthRepository', error: e);
      throw AuthServerException(message: 'Erro inesperado ao realizar autenticação: $e');
    }
  }

  /// Mapeador centralizado de exceções HTTP do Dio para exceções de domínio tipificadas.
  AuthException _handleDioException(DioException e) {
    final response = e.response;
    final statusCode = response?.statusCode;
    final responseData = response?.data;

    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.unknown ||
        response == null ||
        statusCode == null) {
      return const AuthNetworkException(
        message: 'Falha de comunicação com os servidores. Verifique a sua ligação à Internet ou tente novamente.',
      );
    }

    if (responseData is Map<String, dynamic>) {
      final String? erroCode = responseData['erro'] as String?;
      final String? detalhe = responseData['detalhe'] as String?;

      // 1. Trata HTTP 409 ou conta_ja_existe: Utilizador já registado no sistema
      if (statusCode == 409 || erroCode == 'conta_ja_existe' || responseData['conta_ja_existe'] == true) {
        final emailStr = responseData['email']?.toString() ?? '';
        return AccountAlreadyExistsException(
          message: detalhe ?? 'Já existe uma conta registada com este e-mail. Por favor, introduza a sua palavra-passe.',
          email: emailStr,
        );
      }

      // 2. Trata HTTP 429: Limite de envios ou bloqueio ativo (RN-002)
      if (statusCode == 429 || erroCode == 'limite_envios_excedido' || erroCode == 'telemovel_bloqueado') {
        final bloqueadoAteStr = responseData['bloqueado_ate'] as String?;
        final retrySeconds = responseData['retry_after_seconds'] as int?;
        return OtpRateLimitException(
          message: detalhe ?? 'Limite de tentativas ou envios de OTP atingido. Tente mais tarde.',
          retryAfter: bloqueadoAteStr != null ? DateTime.tryParse(bloqueadoAteStr) : null,
          retryAfterSeconds: retrySeconds,
        );
      }

      // 2. Trata HTTP 403: Conta Suspensa (RN-008)
      if (statusCode == 403 || erroCode == 'conta_suspensa') {
        return AccountSuspendedException(
          message: detalhe ?? 'Esta conta encontra-se suspensa. Contacte o suporte.',
        );
      }

      // 3. Trata HTTP 401: Credenciais Inválidas, Senha não configurada ou Utilizador não encontrado
      if (statusCode == 401) {
        final msgErro = detalhe ??
            responseData['message'] ??
            responseData['detail'] ??
            'Credenciais inválidas. Verifique os dados introduzidos.';
        return InvalidCredentialsException(
          message: msgErro.toString(),
          errorCode: erroCode ?? 'credenciais_invalidas',
        );
      }

      // 3. Trata HTTP 400: OTP Expirado (RN-002)
      if (erroCode == 'otp_expirado') {
        return OtpExpiredException(
          message: detalhe ?? 'O código OTP expirou após 5 minutos. Solicite um novo código.',
        );
      }

      // 4. Trata HTTP 400: Código Incorreto ou Tentativas Esgotadas (RN-002)
      if (erroCode == 'codigo_incorreto' || erroCode == 'tentativas_esgotadas') {
        final tentativasRestantes = responseData['tentativas_restantes'] as int?;
        final bloqueadoAteStr = responseData['bloqueado_ate'] as String?;
        return InvalidOtpException(
          message: detalhe ?? 'Código OTP incorreto.',
          tentativasRestantes: tentativasRestantes,
          bloqueadoAte: bloqueadoAteStr != null ? DateTime.tryParse(bloqueadoAteStr) : null,
        );
      }

      // 5. Trata HTTP 400: Validação de Maioridade (< 18 anos per RN-003)
      final dataNascErrors = responseData['data_nascimento'];
      if (dataNascErrors != null) {
        final msg = dataNascErrors is List ? dataNascErrors.first.toString() : dataNascErrors.toString();
        if (msg.contains('18 anos') || msg.contains('menor')) {
          return UnderageException(message: msg);
        }
        return RegistrationValidationException(
          message: msg,
          fieldErrors: responseData,
        );
      }

      // 6. Trata outros erros de validação de formulário (telemóvel, e-mail duplicado, consentimentos, etc.)
      if (statusCode == 400) {
        final telemovelError = responseData['telemovel'];
        if (telemovelError != null) {
          final msg = telemovelError is List ? telemovelError.first.toString() : telemovelError.toString();
          return RegistrationValidationException(
            message: msg,
            fieldErrors: responseData,
          );
        }

        final emailError = responseData['email'];
        if (emailError != null) {
          final msg = emailError is List ? emailError.first.toString() : emailError.toString();
          return RegistrationValidationException(
            message: msg,
            fieldErrors: responseData,
          );
        }

        final nomeError = responseData['nome'];
        if (nomeError != null) {
          final msg = nomeError is List ? nomeError.first.toString() : nomeError.toString();
          return RegistrationValidationException(
            message: msg,
            fieldErrors: responseData,
          );
        }

        final consentimentosError = responseData['consentimentos'];
        if (consentimentosError != null) {
          final msg = consentimentosError is List ? consentimentosError.first.toString() : consentimentosError.toString();
          return RegistrationValidationException(
            message: msg,
            fieldErrors: responseData,
          );
        }

        final detalheErro = detalhe ?? responseData['message'] ?? responseData['detail'] ?? responseData['erro'];
        if (detalheErro != null) {
          return RegistrationValidationException(
            message: detalheErro.toString(),
            fieldErrors: responseData,
          );
        }

        return RegistrationValidationException(
          message: 'Dados de formulário inválidos. Verifique os campos submetidos.',
          fieldErrors: responseData,
        );
      }
    }

    if (statusCode != null && statusCode >= 500) {
      return AuthServerException(
        message: 'O servidor de autenticação encontrou uma instabilidade ($statusCode). Tente novamente.',
        statusCode: statusCode,
      );
    }

    if (responseData is Map<String, dynamic>) {
      final msg = responseData['detalhe'] ?? responseData['detail'] ?? responseData['message'];
      if (msg != null && msg.toString().isNotEmpty) {
        return AuthServerException(
          message: msg.toString(),
          statusCode: statusCode,
        );
      }
    }

    return AuthServerException(
      message: statusCode != null
          ? 'Não foi possível concluir a autenticação. Código de status: $statusCode.'
          : 'Não foi possível concluir a autenticação. Verifique a sua conexão com a Internet.',
      statusCode: statusCode,
    );
  }
}

