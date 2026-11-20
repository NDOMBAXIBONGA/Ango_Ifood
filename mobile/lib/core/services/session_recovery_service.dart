import 'dart:convert';
import 'dart:developer' as developer;
import 'package:shared_preferences/shared_preferences.dart';

/// Dados recuperados de uma sessão anterior interrompida para atualização.
class RecoveredSessionData {
  final String routeName;
  final Map<String, dynamic>? arguments;

  const RecoveredSessionData({
    required this.routeName,
    this.arguments,
  });

  @override
  String toString() => 'RecoveredSessionData(route: $routeName, args: $arguments)';
}

/// Gestor de Restauro de Estado de Navegação pós-atualização OTA (Over-The-Air).
/// Salva a rota ativa e parâmetros imediatamente antes da instalação do APK (Android)
/// ou redirecionamento para o site externo (iOS) e retoma o ecrã no arranque seguinte.
class SessionRecoveryService {
  SessionRecoveryService._();
  static final SessionRecoveryService instance = SessionRecoveryService._();

  static const String _keyUltimaRota = 'ota_ultima_rota';
  static const String _keyRouteArgs = 'ota_route_args';
  static const String _keyRestaurarAposUpdate = 'ota_restaurar_apos_update';

  /// Regista o ecrã e argumentos atuais antes de disparar o download/instalação.
  Future<void> saveCurrentRouteBeforeUpdate({
    required String routeName,
    Map<String, dynamic>? arguments,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyUltimaRota, routeName);

      if (arguments != null && arguments.isNotEmpty) {
        final jsonArgs = jsonEncode(arguments);
        await prefs.setString(_keyRouteArgs, jsonArgs);
      } else {
        await prefs.remove(_keyRouteArgs);
      }

      await prefs.setBool(_keyRestaurarAposUpdate, true);

      developer.log(
        'Sessão guardada para restauro pós-update: rota=$routeName, args=$arguments',
        name: 'SessionRecoveryService',
      );
    } catch (e, stack) {
      developer.log(
        'Erro ao guardar sessão antes do update: $e',
        name: 'SessionRecoveryService',
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// Verifica no arranque da app se existe um restauro pendente após uma atualização.
  /// Se existir, limpa a flag de controle e devolve a rota e argumentos originais.
  Future<RecoveredSessionData?> checkAndRecoverSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deveRestaurar = prefs.getBool(_keyRestaurarAposUpdate) ?? false;

      if (!deveRestaurar) {
        return null;
      }

      final rota = prefs.getString(_keyUltimaRota);
      if (rota == null || rota.isEmpty) {
        await clearRecoveryState();
        return null;
      }

      Map<String, dynamic>? args;
      final rawArgs = prefs.getString(_keyRouteArgs);
      if (rawArgs != null && rawArgs.isNotEmpty) {
        try {
          args = jsonDecode(rawArgs) as Map<String, dynamic>?;
        } catch (_) {}
      }

      // Limpa a flag para não entrar em loop em reinícios normais futuros
      await clearRecoveryState();

      developer.log(
        'Restauro de sessão ativado pós-atualização: rota=$rota, args=$args',
        name: 'SessionRecoveryService',
      );

      return RecoveredSessionData(routeName: rota, arguments: args);
    } catch (e) {
      developer.log(
        'Falha ao verificar restauro de sessão: $e',
        name: 'SessionRecoveryService',
      );
      return null;
    }
  }

  /// Limpa todos os dados de recuperação guardados.
  Future<void> clearRecoveryState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyUltimaRota);
      await prefs.remove(_keyRouteArgs);
      await prefs.remove(_keyRestaurarAposUpdate);
    } catch (_) {}
  }
}
