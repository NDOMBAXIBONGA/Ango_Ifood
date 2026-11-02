/// Modelos de dados fortemente tipificados para a camada de Autenticação Mobile.
/// Suporta o fluxo Passwordless OTP, Perfis de Utilizador e Credenciais JWT.

import 'package:equatable/equatable.dart';

/// Par de tokens criptográficos emitidos pelo backend (SimpleJWT).
class AuthTokens extends Equatable {
  final String accessToken;
  final String refreshToken;

  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access'] as String? ?? '',
      refreshToken: json['refresh'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'access': accessToken,
        'refresh': refreshToken,
      };

  @override
  List<Object?> get props => [accessToken, refreshToken];
}

/// Perfil do utilizador autenticado (RN-003, RN-006, RN-008).
class UserProfile extends Equatable {
  final String id;
  final String telemovel;
  final String nome;
  final String email;
  final String estado;
  final DateTime? dataNascimento;
  final DateTime? dataCriacao;

  const UserProfile({
    required this.id,
    required this.telemovel,
    required this.nome,
    required this.email,
    required this.estado,
    this.dataNascimento,
    this.dataCriacao,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String? ?? '',
      telemovel: json['telemovel'] as String? ?? '',
      nome: json['nome'] as String? ?? '',
      email: json['email'] as String? ?? '',
      estado: json['estado'] as String? ?? 'ATIVO',
      dataNascimento: json['data_nascimento'] != null
          ? DateTime.tryParse(json['data_nascimento'] as String)
          : null,
      dataCriacao: json['data_criacao'] != null
          ? DateTime.tryParse(json['data_criacao'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'telemovel': telemovel,
        'nome': nome,
        'email': email,
        'estado': estado,
        'data_nascimento': dataNascimento?.toIso8601String().split('T').first,
        'data_criacao': dataCriacao?.toIso8601String(),
      };

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

/// Resposta da solicitação de OTP (Endpoint 1: /api/v1/auth/request-otp/).
class OtpRequestResult extends Equatable {
  final String mensagem;
  final String telemovel;
  final DateTime expiraEm;
  final int validadeMinutos;
  final int tentativasPermitidas;
  final int enviosRestantesNaHora;

  const OtpRequestResult({
    required this.mensagem,
    required this.telemovel,
    required this.expiraEm,
    required this.validadeMinutos,
    required this.tentativasPermitidas,
    required this.enviosRestantesNaHora,
  });

  factory OtpRequestResult.fromJson(Map<String, dynamic> json) {
    return OtpRequestResult(
      mensagem: json['mensagem'] as String? ?? 'Código OTP enviado.',
      telemovel: json['telemovel'] as String? ?? '',
      expiraEm: json['expira_em'] != null
          ? DateTime.parse(json['expira_em'] as String)
          : DateTime.now().add(const Duration(minutes: 5)),
      validadeMinutos: json['validade_minutos'] as int? ?? 5,
      tentativasPermitidas: json['tentativas_permitidas'] as int? ?? 5,
      enviosRestantesNaHora: json['envios_restantes_na_hora'] as int? ?? 2,
    );
  }

  @override
  List<Object?> get props => [
        mensagem,
        telemovel,
        expiraEm,
        validadeMinutos,
        tentativasPermitidas,
        enviosRestantesNaHora,
      ];
}

/// Resultado unificado da verificação de OTP e finalização de registo.
class AuthResult extends Equatable {
  final bool isRegistrationRequired;
  final String? phone;
  final AuthTokens? tokens;
  final UserProfile? userProfile;
  final String message;

  const AuthResult({
    required this.isRegistrationRequired,
    this.phone,
    this.tokens,
    this.userProfile,
    required this.message,
  });

  factory AuthResult.fromVerifyOtpJson(Map<String, dynamic> json, String defaultPhone) {
    final bool isRegistrationRequired =
        json['registo_pendente'] == true || json['requires_registration_completion'] == true;

    if (isRegistrationRequired) {
      return AuthResult(
        isRegistrationRequired: true,
        phone: json['telemovel'] as String? ?? defaultPhone,
        message: json['mensagem'] as String? ?? 'Registo complementar necessário.',
      );
    }

    final tokensMap = json['tokens'] as Map<String, dynamic>?;
    final perfilMap = json['perfil'] as Map<String, dynamic>?;

    return AuthResult(
      isRegistrationRequired: false,
      phone: defaultPhone,
      tokens: tokensMap != null ? AuthTokens.fromJson(tokensMap) : null,
      userProfile: perfilMap != null ? UserProfile.fromJson(perfilMap) : null,
      message: json['mensagem'] as String? ?? 'Autenticado com sucesso.',
    );
  }

  factory AuthResult.fromCompleteRegistrationJson(Map<String, dynamic> json) {
    final tokensMap = json['tokens'] as Map<String, dynamic>?;
    final perfilMap = json['perfil'] as Map<String, dynamic>?;

    return AuthResult(
      isRegistrationRequired: false,
      tokens: tokensMap != null ? AuthTokens.fromJson(tokensMap) : null,
      userProfile: perfilMap != null ? UserProfile.fromJson(perfilMap) : null,
      message: json['mensagem'] as String? ?? 'Registo concluído com sucesso.',
    );
  }

  @override
  List<Object?> get props => [
        isRegistrationRequired,
        phone,
        tokens,
        userProfile,
        message,
      ];
}

