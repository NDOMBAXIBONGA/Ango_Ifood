/// Wrapper seguro para persistência local de credenciais e tokens JWT.
/// Utiliza FlutterSecureStorage com encriptação nativa por plataforma (Keychain no iOS e KeyStore/EncryptedSharedPreferences no Android),
/// combinado com cache estática em memória para leitura instantânea (0ms) e proteção contra falhas transitórias do KeyStore.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Contrato abstrato de armazenamento seguro de tokens para desacoplamento e testes.
abstract class ISecureTokenStorage {
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    String? userRole,
  });
  Future<void> saveUserProfileJson(String profileJson);
  Future<String?> getUserProfileJson();
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<String?> getUserRole();
  Future<void> clearTokens();
  Future<bool> hasValidToken();
}

/// Implementação padrão com `flutter_secure_storage` e cache estática em memória.
class SecureTokenStorage implements ISecureTokenStorage {
  final FlutterSecureStorage _storage;

  static const String _keyAccessToken = 'auth_access_token';
  static const String _keyRefreshToken = 'auth_refresh_token';
  static const String _keyUserRole = 'auth_user_role';
  static const String _keyUserProfileJson = 'auth_user_profile_json';

  // Cache estática em memória partilhada por todas as instâncias de SecureTokenStorage
  static String? _memAccessToken;
  static String? _memRefreshToken;
  static String? _memUserRole;
  static String? _memUserProfileJson;

  SecureTokenStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                encryptedSharedPreferences: true,
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
            );

  /// Leitura síncrona imediata do token de acesso em memória (se já carregado).
  static String? get cachedAccessToken => _memAccessToken;

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    String? userRole,
  }) async {
    _memAccessToken = accessToken;
    _memRefreshToken = refreshToken;
    if (userRole != null && userRole.isNotEmpty) {
      _memUserRole = userRole.toUpperCase();
    }
    try {
      final writes = <Future<void>>[
        _storage.write(key: _keyAccessToken, value: accessToken),
        _storage.write(key: _keyRefreshToken, value: refreshToken),
      ];
      if (userRole != null && userRole.isNotEmpty) {
        writes.add(_storage.write(key: _keyUserRole, value: userRole.toUpperCase()));
      }
      await Future.wait(writes);
    } catch (_) {
      // Mantém os tokens em memória caso o KeyStore do dispositivo falhe
    }
  }

  @override
  Future<void> saveUserProfileJson(String profileJson) async {
    _memUserProfileJson = profileJson;
    try {
      await _storage.write(key: _keyUserProfileJson, value: profileJson);
    } catch (_) {}
  }

  @override
  Future<String?> getUserProfileJson() async {
    if (_memUserProfileJson != null && _memUserProfileJson!.isNotEmpty) {
      return _memUserProfileJson;
    }
    try {
      final persisted = await _storage.read(key: _keyUserProfileJson);
      if (persisted != null && persisted.isNotEmpty) {
        _memUserProfileJson = persisted;
      }
      return persisted;
    } catch (_) {
      return _memUserProfileJson;
    }
  }

  @override
  Future<String?> getAccessToken() async {
    if (_memAccessToken != null && _memAccessToken!.isNotEmpty) {
      return _memAccessToken;
    }
    try {
      final persisted = await _storage.read(key: _keyAccessToken);
      if (persisted != null && persisted.isNotEmpty) {
        _memAccessToken = persisted;
      }
      return persisted;
    } catch (_) {
      return _memAccessToken;
    }
  }

  @override
  Future<String?> getRefreshToken() async {
    if (_memRefreshToken != null && _memRefreshToken!.isNotEmpty) {
      return _memRefreshToken;
    }
    try {
      final persisted = await _storage.read(key: _keyRefreshToken);
      if (persisted != null && persisted.isNotEmpty) {
        _memRefreshToken = persisted;
      }
      return persisted;
    } catch (_) {
      return _memRefreshToken;
    }
  }

  @override
  Future<String?> getUserRole() async {
    if (_memUserRole != null && _memUserRole!.isNotEmpty) {
      return _memUserRole;
    }
    try {
      final persisted = await _storage.read(key: _keyUserRole);
      if (persisted != null && persisted.isNotEmpty) {
        _memUserRole = persisted;
      }
      return persisted;
    } catch (_) {
      return _memUserRole;
    }
  }

  @override
  Future<void> clearTokens() async {
    _memAccessToken = null;
    _memRefreshToken = null;
    _memUserRole = null;
    _memUserProfileJson = null;
    try {
      await Future.wait([
        _storage.delete(key: _keyAccessToken),
        _storage.delete(key: _keyRefreshToken),
        _storage.delete(key: _keyUserRole),
        _storage.delete(key: _keyUserProfileJson),
      ]);
    } catch (_) {}
  }

  @override
  Future<bool> hasValidToken() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }
}

