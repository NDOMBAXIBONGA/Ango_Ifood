import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_bootstrap_config.dart';

/// Serviço Central de Configuração Remota, Server-Driven UI e Parâmetros Dinâmicos.
///
/// Responsabilidades:
/// 1. Inicialização Offline-First instantânea a partir de SharedPreferences (0ms, zero ecrã branco).
/// 2. Sincronização inteligente com a API Django Bootstrap (`/api/v1/system/bootstrap/`) usando ETag HTTP 304.
/// 3. Emissão de notificações reativas (ChangeNotifier) para re-renderização em tempo real de temas e textos.
/// 4. Acesso tipado a 100% dos parâmetros de sistema (Branding, Design System, Textos, Taxas, Feature Flags).
class AppConfigService extends ChangeNotifier {
  static final AppConfigService instance = AppConfigService._internal();

  AppConfigService._internal();

  static const String _kPrefsConfigKey = 'app_system_bootstrap_config_json';
  static const String _kPrefsEtagKey = 'app_system_bootstrap_etag';
  static const String _defaultApiBaseUrl = 'https://ango-ifood.onrender.com';

  AppBootstrapConfig _config = AppBootstrapConfig.empty();
  String? _currentEtag;
  bool _isInitialized = false;

  /// Retorna a configuração global ativa no momento.
  AppBootstrapConfig get config => _config;

  /// Indica se a configuração já foi inicializada da persistência local.
  bool get isInitialized => _isInitialized;

  // ===========================================================================
  // ATALHOS TIPADOS DE DESIGN SYSTEM & BRANDING
  // ===========================================================================
  AppBrandingConfig get branding => _config.branding;
  AppDesignSystemConfig get designSystem => _config.designSystem;

  Color get primaryColor => _config.designSystem.primaryColor;
  Color get secondaryColor => _config.designSystem.secondaryColor;
  Color get accentColor => _config.designSystem.accentColor;
  Color get backgroundColor => _config.designSystem.backgroundColor;
  Color get surfaceColor => _config.designSystem.surfaceColor;
  Color get textPrimaryColor => _config.designSystem.textPrimaryColor;
  Color get textSecondaryColor => _config.designSystem.textSecondaryColor;
  double get buttonBorderRadius => _config.designSystem.buttonBorderRadius;
  double get cardBorderRadius => _config.designSystem.cardBorderRadius;

  bool get isMaintenanceActive => _config.maintenance.active;
  String get maintenanceMessage => _config.maintenance.message;

  // ===========================================================================
  // 1. INICIALIZAÇÃO OFFLINE-FIRST (CACHE LOCAL)
  // ===========================================================================
  /// Carrega a última configuração válida armazenada no disco.
  /// Deve ser chamado no arranque do app (main.dart ou Splash) antes da UI final.
  Future<void> loadCachedConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _currentEtag = prefs.getString(_kPrefsEtagKey);
      final rawJson = prefs.getString(_kPrefsConfigKey);

      if (rawJson != null && rawJson.isNotEmpty) {
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        _config = AppBootstrapConfig.fromJson(decoded);
        debugPrint(
          '✅ [AppConfigService] Configurações locais carregadas com sucesso (ETag: $_currentEtag).',
        );
      } else {
        _config = AppBootstrapConfig.empty();
        debugPrint(
          'ℹ️ [AppConfigService] Nenhum cache prévio encontrado. Usando padrões internos.',
        );
      }
    } catch (e, stack) {
      debugPrint('⚠️ [AppConfigService] Falha ao ler cache local: $e\n$stack');
      _config = AppBootstrapConfig.empty();
    } finally {
      _isInitialized = true;
      notifyListeners();
    }
  }

  // ===========================================================================
  // 2. SINCRONIZAÇÃO REMOTA (BOOTSTRAP API COM ETAG)
  // ===========================================================================
  /// Consulta o endpoint `/api/v1/system/bootstrap/` enviando `If-None-Match`.
  /// Se o servidor responder HTTP 304, poupa dados e mantém a versão local intacta.
  /// Se responder HTTP 200, atualiza o cache e dispara notificação para a UI.
  Future<bool> syncWithRemote({String? customBaseUrl}) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: customBaseUrl ?? _defaultApiBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'Accept': 'application/json',
          if (_currentEtag != null && _currentEtag!.isNotEmpty)
            'If-None-Match': _currentEtag,
        },
      ),
    );

    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/api/v1/system/bootstrap/',
      );

      if (response.statusCode == 200 && response.data != null) {
        final newConfig = AppBootstrapConfig.fromJson(response.data!);
        final newEtag = response.headers.value('ETag') ??
            response.headers.value('etag');

        _config = newConfig;
        _currentEtag = newEtag;

        // Persiste no SharedPreferences para futuros arranques instantâneos
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kPrefsConfigKey, jsonEncode(response.data));
        if (newEtag != null) {
          await prefs.setString(_kPrefsEtagKey, newEtag);
        }

        debugPrint(
          '🚀 [AppConfigService] Configuração remota atualizada (Versão: ${_config.schemaVersion}, ETag: $_currentEtag).',
        );
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 304) {
        debugPrint(
          '⚡ [AppConfigService] HTTP 304 Not Modified. Configurações remotas idênticas ao cache local.',
        );
        return false;
      }
      debugPrint('⚠️ [AppConfigService] Erro de rede ao buscar bootstrap: ${e.message}');
    } catch (e, stack) {
      debugPrint('⚠️ [AppConfigService] Erro inesperado ao sincronizar: $e\n$stack');
    }
    return false;
  }

  // ===========================================================================
  // 3. CONSULTAS TIPADAS & HELPERS SERVER-DRIVEN UI
  // ===========================================================================

  /// Retorna um texto resolvido remotamente pelo Django Admin ou o fallback indicado.
  String getString(String key, {String fallback = ''}) {
    if (_config.strings.containsKey(key)) {
      final val = _config.strings[key];
      if (val != null) return val.toString();
    }
    if (_config.rawParameters.containsKey(key)) {
      final raw = _config.rawParameters[key];
      if (raw != null) return raw.toString();
    }
    return fallback;
  }

  /// Verifica se uma funcionalidade ou Feature Flag está habilitada pelo administrador.
  bool isFeatureEnabled(String flagKey, {bool fallback = false}) {
    if (_config.featureFlags.containsKey(flagKey)) {
      final val = _config.featureFlags[flagKey];
      if (val is bool) return val;
      if (val != null) {
        final str = val.toString().trim().toLowerCase();
        return str == 'true' || str == '1' || str == 'sim' || str == 'yes';
      }
    }
    return fallback;
  }

  /// Retorna a lista de banners ativos filtrados pelo papel do utilizador.
  List<AppBannerItem> getBannersForRole(String targetRole) {
    final roleUpper = targetRole.toUpperCase();
    return _config.banners.where((b) {
      final p = b.targetAudience.toUpperCase();
      return p == 'TODOS' || p == roleUpper;
    }).toList();
  }

  /// Retorna o valor numérico ou estruturado de qualquer parâmetro bruto arbitrário.
  dynamic getRawParameter(String key, {dynamic defaultValue}) {
    if (_config.rawParameters.containsKey(key)) {
      return _config.rawParameters[key] ?? defaultValue;
    }
    return defaultValue;
  }

  /// Gera um ThemeData dinâmico no Flutter baseado 100% nas diretrizes configuradas no Django Admin.
  ThemeData buildDynamicThemeData() {
    final ds = _config.designSystem;
    final primary = ds.primaryColor;
    final secondary = ds.secondaryColor;
    final background = ds.backgroundColor;
    final surface = ds.surfaceColor;
    final textPrimary = ds.textPrimaryColor;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      secondary: secondary,
      surface: surface,
      error: const Color(0xFFEF4444),
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ds.buttonBorderRadius),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ds.cardBorderRadius),
        ),
      ),
    );
  }
}

/// Extensão ergonómica em BuildContext para resolver parâmetros e textos remotos em qualquer Widget.
extension RemoteConfigContext on BuildContext {
  AppConfigService get remoteConfig => AppConfigService.instance;

  /// Retorna o texto dinâmico configurado no Django Admin ou a string padrão de fallback.
  String remoteStr(String key, {String fallback = ''}) {
    return AppConfigService.instance.getString(key, fallback: fallback);
  }

  /// Verifica se uma feature flag está ativa no Django Admin.
  bool isFeatureActive(String flagKey, {bool fallback = false}) {
    return AppConfigService.instance.isFeatureEnabled(flagKey, fallback: fallback);
  }
}
