import 'dart:developer' as developer;
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/app_update_info.dart';
import '../network/app_environment_config.dart';
import '../widgets/update_dialog.dart';

/// Serviço responsável pela verificação remota de versões da aplicação (OTA / Kill Switch).
/// Consulta a API Django `/api/app/check-update/` no arranque e quando a app volta do segundo plano.
class UpdateService with WidgetsBindingObserver {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  GlobalKey<NavigatorState>? _navigatorKey;
  bool _isChecking = false;
  bool _isDialogShowing = false;

  /// Inicializa o observador de ciclo de vida para verificar atualizações no arranque
  /// e sempre que a aplicação retornar do segundo plano (AppLifecycleState.resumed).
  void initLifecycleObserver({required GlobalKey<NavigatorState> navigatorKey}) {
    _navigatorKey = navigatorKey;
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);

    // Verificação inicial no arranque
    WidgetsBinding.instance.addPostFrameCallback((_) {
      checkAndShowUpdateDialog();
    });
  }

  /// Cancela o observador ao encerrar o serviço
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      developer.log('App retomada do segundo plano (resumed): a verificar atualizações...', name: 'UpdateService');
      checkAndShowUpdateDialog();
    }
  }

  /// Consulta o endpoint da API Django para saber se existe uma versão mais recente.
  Future<AppUpdateInfo?> checkForUpdate() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return null;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final buildNumber = int.tryParse(packageInfo.buildNumber) ?? 1;
      final plataforma = Platform.isAndroid ? 'ANDROID' : 'IOS';

      final url = '${AppEnvironmentConfig.baseHttpUrl}/api/app/check-update/';

      developer.log(
        'A consultar OTA: $url?plataforma=$plataforma&versao_atual=$buildNumber',
        name: 'UpdateService',
      );

      final response = await _dio.get(
        url,
        queryParameters: {
          'plataforma': plataforma,
          'versao_atual': buildNumber,
        },
      );

      if (response.statusCode == 200 && response.data is Map<String, dynamic>) {
        final updateInfo = AppUpdateInfo.fromJson(response.data as Map<String, dynamic>);
        return updateInfo;
      }
    } catch (e) {
      developer.log('Aviso ao verificar atualizações OTA: $e', name: 'UpdateService');
    }
    return null;
  }

  /// Executa a verificação e, se houver atualização disponível, apresenta o diálogo nativo.
  Future<void> checkAndShowUpdateDialog({BuildContext? customContext}) async {
    if (_isChecking || _isDialogShowing) return;
    _isChecking = true;

    try {
      final info = await checkForUpdate();
      if (info != null && info.atualizacaoDisponivel) {
        final ctx = customContext ?? _navigatorKey?.currentContext;
        if (ctx != null && ctx.mounted) {
          _isDialogShowing = true;

          // Obtém o nome da rota atual a partir do Navigator se disponível
          String currentRoute = '/';
          ModalRoute? currentModal = ModalRoute.of(ctx);
          if (currentModal?.settings.name != null) {
            currentRoute = currentModal!.settings.name!;
          }

          final args = currentModal?.settings.arguments as Map<String, dynamic>?;

          await UpdateDialog.show(
            ctx,
            updateInfo: info,
            currentRouteName: currentRoute,
            currentRouteArgs: args,
          );

          _isDialogShowing = false;
        }
      }
    } finally {
      _isChecking = false;
    }
  }
}
