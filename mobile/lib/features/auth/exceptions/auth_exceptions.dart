/// Exceções fortemente tipificadas para tratamento de respostas e erros da API REST de Autenticação.

abstract class AuthException implements Exception {
  final String message;
  final int? statusCode;
  final String? errorCode;

  const AuthException({
    required this.message,
    this.statusCode,
    this.errorCode,
  });

  @override
  String toString() => 'AuthException(status: $statusCode, code: $errorCode): $message';
}

/// Erro HTTP 429: Limite de envios de OTP por hora ou bloqueio ativo (RN-002).
class OtpRateLimitException extends AuthException {
  final DateTime? retryAfter;
  final int? retryAfterSeconds;

  const OtpRateLimitException({
    required super.message,
    this.retryAfter,
    this.retryAfterSeconds,
  }) : super(statusCode: 429, errorCode: 'limite_envios_excedido');
}

/// Erro HTTP 403: Conta associada com estado 'SUSPENSO' (RN-008).
class AccountSuspendedException extends AuthException {
  const AccountSuspendedException({
    required super.message,
  }) : super(statusCode: 403, errorCode: 'conta_suspensa');
}

/// Erro HTTP 400: Código OTP expirado (TTL > 5 minutos per RN-002).
class OtpExpiredException extends AuthException {
  const OtpExpiredException({
    required super.message,
  }) : super(statusCode: 400, errorCode: 'otp_expirado');
}

/// Erro HTTP 400: Código OTP incorreto ou tentativas excedidas (RN-002).
class InvalidOtpException extends AuthException {
  final int? tentativasRestantes;
  final DateTime? bloqueadoAte;

  const InvalidOtpException({
    required super.message,
    this.tentativasRestantes,
    this.bloqueadoAte,
  }) : super(statusCode: 400, errorCode: 'codigo_incorreto');
}

/// Erro HTTP 400: Validação de maioridade falhou (idade < 18 anos civis per RN-003).
class UnderageException extends AuthException {
  const UnderageException({
    required super.message,
  }) : super(statusCode: 400, errorCode: 'menor_idade');
}

/// Erro HTTP 400: Erro de validação de campos no registo (email duplicado, telemóvel inválido, etc.).
class RegistrationValidationException extends AuthException {
  final Map<String, dynamic>? fieldErrors;

  const RegistrationValidationException({
    required super.message,
    this.fieldErrors,
  }) : super(statusCode: 400, errorCode: 'validacao_formulario');
}

/// Erro de conectividade ou rede (timeout, offline, DNS).
class AuthNetworkException extends AuthException {
  const AuthNetworkException({
    required super.message,
  }) : super(statusCode: null, errorCode: 'network_error');
}

/// Erro 500 do servidor ou erro inesperado.
class AuthServerException extends AuthException {
  const AuthServerException({
    required super.message,
    super.statusCode,
  }) : super(errorCode: 'server_error');
}

