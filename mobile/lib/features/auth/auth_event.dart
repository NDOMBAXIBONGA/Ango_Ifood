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

