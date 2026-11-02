/// Estados do ecossistema de Autenticação (`AuthState`).
/// Modela a interface reativa para a aplicação Flutter com base nas regras de negócio.

import 'package:equatable/equatable.dart';

import 'models/auth_models.dart';

abstract class AuthState extends Equatable {
  const AuthState();

  @override
  List<Object?> get props => [];
}

/// Estado inicial do BLoC antes de qualquer ação.
class AuthInitial extends AuthState {
  const AuthInitial();
}

/// Estado de carregamento assíncrono para exibição de spinners e desativação de botões.
class AuthLoading extends AuthState {
  final String? loadingMessage;

  const AuthLoading({this.loadingMessage});

  @override
  List<Object?> get props => [loadingMessage];
}

/// Estado emitido quando o código OTP é enviado com sucesso por SMS (RN-002).
class OtpSendSuccess extends AuthState {
  final String phone;
  final DateTime expiraEm;
  final int validadeMinutos;
  final int enviosRestantesNaHora;

  const OtpSendSuccess({
    required this.phone,
    required this.expiraEm,
    required this.validadeMinutos,
    required this.enviosRestantesNaHora,
  });

  @override
  List<Object?> get props => [
        phone,
        expiraEm,
        validadeMinutos,
        enviosRestantesNaHora,
      ];
}

/// Estado emitido quando ocorre falha no envio ou validação do código OTP.
/// Pode conter contador de tentativas restantes ou timestamp de bloqueio (RN-002).
class OtpVerificationFailure extends AuthState {
  final String message;
  final int? tentativasRestantes;
  final DateTime? bloqueadoAte;
  final bool isRateLimited;

  const OtpVerificationFailure({
    required this.message,
    this.tentativasRestantes,
    this.bloqueadoAte,
    this.isRateLimited = false,
  });

  @override
  List<Object?> get props => [
        message,
        tentativasRestantes,
        bloqueadoAte,
        isRateLimited,
      ];
}

/// Estado emitido quando o telemóvel foi validado com sucesso pelo OTP,
/// mas a conta ainda não possui os dados básicos (RN-002, RN-003).
/// Redireciona para o formulário de registo.
class RegistrationRequired extends AuthState {
  final String phone;
  final String message;

  const RegistrationRequired({
    required this.phone,
    required this.message,
  });

  @override
  List<Object?> get props => [phone, message];
}

/// Estado emitido quando ocorre falha no envio do formulário de registo
/// (ex: menor de 18 anos civis - RN-003, e-mail duplicado, etc.).
class RegistrationFailure extends AuthState {
  final String message;
  final Map<String, dynamic>? fieldErrors;
  final bool isUnderage;

  const RegistrationFailure({
    required this.message,
    this.fieldErrors,
    this.isUnderage = false,
  });

  @override
  List<Object?> get props => [message, fieldErrors, isUnderage];
}

/// Estado de sucesso onde o utilizador encontra-se autenticado com sessão válida (RN-006).
/// Contém os tokens JWT e os dados de perfil do utilizador.
class Authenticated extends AuthState {
  final AuthTokens tokens;
  final UserProfile user;

  const Authenticated({
    required this.tokens,
    required this.user,
  });

  @override
  List<Object?> get props => [tokens, user];
}

/// Estado emitido quando o utilizador não possui sessão ativa ou efetuou logout.
class Unauthenticated extends AuthState {
  final String? message;

  const Unauthenticated({this.message});

  @override
  List<Object?> get props => [message];
}

