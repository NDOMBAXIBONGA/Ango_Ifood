/// Wrapper seguro para persistência local de credenciais e tokens JWT.
/// Utiliza FlutterSecureStorage com encriptação nativa por plataforma (Keychain no iOS e KeyStore/EncryptedSharedPreferences no Android).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Contrato abstrato de armazenamento seguro de tokens para desacoplamento e testes.
abstract class ISecureTokenStorage {
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    String? userRole,
  });
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<String?> getUserRole();
  Future<void> clearTokens();
  Future<bool> hasValidToken();
}

/// Implementação padrão com `flutter_secure_storage`.
class SecureTokenStorage implements ISecureTokenStorage {
  final FlutterSecureStorage _storage;

  static const String _keyAccessToken = 'auth_access_token';
  static const String _keyRefreshToken = 'auth_refresh_token';
  static const String _keyUserRole = 'auth_user_role';

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

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    String? userRole,
  }) async {
    final writes = <Future<void>>[
      _storage.write(key: _keyAccessToken, value: accessToken),
      _storage.write(key: _keyRefreshToken, value: refreshToken),
    ];
    if (userRole != null && userRole.isNotEmpty) {
      writes.add(_storage.write(key: _keyUserRole, value: userRole.toUpperCase()));
    }
    await Future.wait(writes);
  }

  @override
  Future<String?> getAccessToken() async {
    return _storage.read(key: _keyAccessToken);
  }

  @override
  Future<String?> getRefreshToken() async {
    return _storage.read(key: _keyRefreshToken);
  }

  @override
  Future<String?> getUserRole() async {
    return _storage.read(key: _keyUserRole);
  }

  @override
  Future<void> clearTokens() async {
    await Future.wait([
      _storage.delete(key: _keyAccessToken),
      _storage.delete(key: _keyRefreshToken),
      _storage.delete(key: _keyUserRole),
    ]);
  }

  @override
  Future<bool> hasValidToken() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }
}

