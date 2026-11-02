/// Eventos do BLoC de Autenticação (`AuthEvent`).
/// Define as intenções do utilizador e disparos de ciclo de vida do fluxo passwordless.

import 'package:equatable/equatable.dart';

abstract class AuthEvent extends Equatable {
  const AuthEvent();

  @override
  List<Object?> get props => [];
}

/// Verifica no arranque da aplicação se existem credenciais JWT válidas no armazenamento seguro.
class CheckAuthStatusRequested extends AuthEvent {
  const CheckAuthStatusRequested();
}

/// Disparado quando o utilizador introduz o telemóvel e pede o código OTP (RN-001, RN-002).
class RequestOtpRequested extends AuthEvent {
  final String phone;

  const RequestOtpRequested({required this.phone});

  @override
  List<Object?> get props => [phone];
}

/// Disparado quando o utilizador submete o código OTP de 6 dígitos para validação (RN-002).
class VerifyOtpSubmitted extends AuthEvent {
  final String phone;
  final String code;

  const VerifyOtpSubmitted({
    required this.phone,
    required this.code,
  });

  @override
  List<Object?> get props => [phone, code];
}

/// Disparado quando o novo utilizador submete os dados de finalização de registo (RN-003, RN-004).
class RegistrationFormSubmitted extends AuthEvent {
  final String phone;
  final String name;
  final String email;
  final DateTime birthDate;
  final bool termsAccepted;
  final bool privacyAccepted;
  final bool marketingAccepted;

  const RegistrationFormSubmitted({
    required this.phone,
    required this.name,
    required this.email,
    required this.birthDate,
    this.termsAccepted = true,
    this.privacyAccepted = true,
    this.marketingAccepted = false,
  });

  @override
  List<Object?> get props => [
        phone,
        name,
        email,
        birthDate,
        termsAccepted,
        privacyAccepted,
        marketingAccepted,
      ];
}

/// Disparado quando o utilizador encerra a sessão, limpando as credenciais locais.
class LogoutRequested extends AuthEvent {
  const LogoutRequested();
}

/// Disparado pelo utilizador ao clicar em "Tentar Novamente" após falha de rede/conexão.
class RetryAuthRequested extends AuthEvent {
  const RetryAuthRequested();
}

/// Alias para suporte à nomenclatura em português
typedef TentarReconexaoEvent = RetryAuthRequested;

/// Disparado quando o utilizador introduz o e-mail para receber código OTP de 6 dígitos.
class SendEmailOtpEvent extends AuthEvent {
  final String email;

  const SendEmailOtpEvent({required this.email});

  @override
  List<Object?> get props => [email];
}

/// Disparado quando o utilizador autentica via Google Sign-In com o token de identificação.
class GoogleLoginSubmitted extends AuthEvent {
  final String? token;

  const GoogleLoginSubmitted({this.token});

  @override
  List<Object?> get props => [token];
}

/// Disparado quando o utilizador preenche os 6 dígitos do código OTP recebido por e-mail.
class VerifyEmailOtpSubmitted extends AuthEvent {
  final String email;
  final String otp;

  const VerifyEmailOtpSubmitted({
    required this.email,
    required this.otp,
  });

  @override
  List<Object?> get props => [email, otp];
}

