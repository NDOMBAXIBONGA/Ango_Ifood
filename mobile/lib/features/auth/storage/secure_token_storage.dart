/// Wrapper seguro para persistência local de credenciais e tokens JWT.
/// Utiliza FlutterSecureStorage com encriptação nativa por plataforma (Keychain no iOS e KeyStore/EncryptedSharedPreferences no Android).

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Contrato abstrato de armazenamento seguro de tokens para desacoplamento e testes.
abstract class ISecureTokenStorage {
  Future<void> saveTokens({required String accessToken, required String refreshToken});
  Future<String?> getAccessToken();
  Future<String?> getRefreshToken();
  Future<void> clearTokens();
  Future<bool> hasValidToken();
}

/// Implementação padrão com `flutter_secure_storage`.
class SecureTokenStorage implements ISecureTokenStorage {
  final FlutterSecureStorage _storage;

  static const String _keyAccessToken = 'auth_access_token';
  static const String _keyRefreshToken = 'auth_refresh_token';

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
  }) async {
    await Future.wait([
      _storage.write(key: _keyAccessToken, value: accessToken),
      _storage.write(key: _keyRefreshToken, value: refreshToken),
    ]);
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
  Future<void> clearTokens() async {
    await Future.wait([
      _storage.delete(key: _keyAccessToken),
      _storage.delete(key: _keyRefreshToken),
    ]);
  }

  @override
  Future<bool> hasValidToken() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }
}

