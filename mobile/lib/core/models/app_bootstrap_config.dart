import 'package:flutter/material.dart';

/// Modelo de dados tipado com 100% de suporte ao Bootstrap Remoto e Server-Driven UI.
/// Mapeia branding, temas de cores, dicionário de strings, finanças, logística, flags e banners.
class AppBootstrapConfig {
  final String schemaVersion;
  final String timestamp;
  final AppBrandingConfig branding;
  final AppDesignSystemConfig designSystem;
  final Map<String, dynamic> strings;
  final AppFinancesConfig financesAndFees;
  final AppLogisticsConfig logistics;
  final Map<String, dynamic> featureFlags;
  final AppMaintenanceConfig maintenance;
  final List<AppBannerItem> banners;
  final Map<String, dynamic> rawParameters;

  const AppBootstrapConfig({
    required this.schemaVersion,
    required this.timestamp,
    required this.branding,
    required this.designSystem,
    required this.strings,
    required this.financesAndFees,
    required this.logistics,
    required this.featureFlags,
    required this.maintenance,
    required this.banners,
    required this.rawParameters,
  });

  factory AppBootstrapConfig.empty() {
    return AppBootstrapConfig(
      schemaVersion: '1.0.0',
      timestamp: DateTime.now().toIso8601String(),
      branding: const AppBrandingConfig.defaults(),
      designSystem: const AppDesignSystemConfig.defaults(),
      strings: const {},
      financesAndFees: const AppFinancesConfig.defaults(),
      logistics: const AppLogisticsConfig.defaults(),
      featureFlags: const {
        'modulo_gorjetas_ativo': true,
        'pagamento_dinheiro_ativo': true,
        'pagamento_express_ativo': true,
        'tracking_gps_ao_vivo': true,
        'modo_manutencao': false,
      },
      maintenance: const AppMaintenanceConfig.defaults(),
      banners: const [],
      rawParameters: const {},
    );
  }

  factory AppBootstrapConfig.fromJson(Map<String, dynamic> json) {
    return AppBootstrapConfig(
      schemaVersion: json['schema_version']?.toString() ?? '1.0.0',
      timestamp: json['timestamp']?.toString() ?? '',
      branding: AppBrandingConfig.fromJson(
        (json['branding'] as Map<String, dynamic>?) ?? {},
      ),
      designSystem: AppDesignSystemConfig.fromJson(
        (json['design_system'] as Map<String, dynamic>?) ?? {},
      ),
      strings: (json['strings'] as Map<String, dynamic>?) ?? {},
      financesAndFees: AppFinancesConfig.fromJson(
        (json['finances_and_fees'] as Map<String, dynamic>?) ?? {},
      ),
      logistics: AppLogisticsConfig.fromJson(
        (json['logistics'] as Map<String, dynamic>?) ?? {},
      ),
      featureFlags: (json['feature_flags'] as Map<String, dynamic>?) ?? {},
      maintenance: AppMaintenanceConfig.fromJson(
        (json['maintenance'] as Map<String, dynamic>?) ?? {},
      ),
      banners: ((json['banners'] as List<dynamic>?) ?? [])
          .map((item) => AppBannerItem.fromJson(item as Map<String, dynamic>))
          .toList(),
      rawParameters: (json['raw_parameters'] as Map<String, dynamic>?) ?? {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schema_version': schemaVersion,
      'timestamp': timestamp,
      'branding': branding.toJson(),
      'design_system': designSystem.toJson(),
      'strings': strings,
      'finances_and_fees': financesAndFees.toJson(),
      'logistics': logistics.toJson(),
      'feature_flags': featureFlags,
      'maintenance': maintenance.toJson(),
      'banners': banners.map((b) => b.toJson()).toList(),
      'raw_parameters': rawParameters,
    };
  }
}

class AppBrandingConfig {
  final String appName;
  final String appSlogan;
  final String logoUrl;
  final String iconUrl;

  const AppBrandingConfig({
    required this.appName,
    required this.appSlogan,
    required this.logoUrl,
    required this.iconUrl,
  });

  const AppBrandingConfig.defaults()
      : appName = 'Ango_Ifood Delivery',
        appSlogan = 'A maior plataforma de entregas de Angola',
        logoUrl = '',
        iconUrl = '';

  factory AppBrandingConfig.fromJson(Map<String, dynamic> json) {
    return AppBrandingConfig(
      appName: json['app_name']?.toString() ?? 'Ango_Ifood Delivery',
      appSlogan: json['app_slogan']?.toString() ?? '',
      logoUrl: json['logo_url']?.toString() ?? '',
      iconUrl: json['icon_url']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'app_name': appName,
        'app_slogan': appSlogan,
        'logo_url': logoUrl,
        'icon_url': iconUrl,
      };
}

class AppDesignSystemConfig {
  final String primaryColorHex;
  final String secondaryColorHex;
  final String accentColorHex;
  final String backgroundScreenHex;
  final String backgroundCardHex;
  final String borderRadiusBase;
  final String fontFamily;

  const AppDesignSystemConfig({
    required this.primaryColorHex,
    required this.secondaryColorHex,
    required this.accentColorHex,
    required this.backgroundScreenHex,
    required this.backgroundCardHex,
    required this.borderRadiusBase,
    required this.fontFamily,
  });

  const AppDesignSystemConfig.defaults()
      : primaryColorHex = '#EA1D2C',
        secondaryColorHex = '#0F172A',
        accentColorHex = '#F59E0B',
        backgroundScreenHex = '#F8FAFC',
        backgroundCardHex = '#FFFFFF',
        borderRadiusBase = '14px',
        fontFamily = 'Roboto';

  factory AppDesignSystemConfig.fromJson(Map<String, dynamic> json) {
    return AppDesignSystemConfig(
      primaryColorHex: json['primary_color']?.toString() ?? '#EA1D2C',
      secondaryColorHex: json['secondary_color']?.toString() ?? '#0F172A',
      accentColorHex: json['accent_color']?.toString() ?? '#F59E0B',
      backgroundScreenHex: json['background_screen']?.toString() ?? '#F8FAFC',
      backgroundCardHex: json['background_card']?.toString() ?? '#FFFFFF',
      borderRadiusBase: json['border_radius_base']?.toString() ?? '14px',
      fontFamily: json['font_family']?.toString() ?? 'Roboto',
    );
  }

  Map<String, dynamic> toJson() => {
        'primary_color': primaryColorHex,
        'secondary_color': secondaryColorHex,
        'accent_color': accentColorHex,
        'background_screen': backgroundScreenHex,
        'background_card': backgroundCardHex,
        'border_radius_base': borderRadiusBase,
        'font_family': fontFamily,
      };

  Color get primaryColor => _parseHexColor(primaryColorHex, const Color(0xFFEA1D2C));
  Color get secondaryColor => _parseHexColor(secondaryColorHex, const Color(0xFF0F172A));
  Color get accentColor => _parseHexColor(accentColorHex, const Color(0xFFF59E0B));
  Color get backgroundScreen => _parseHexColor(backgroundScreenHex, const Color(0xFFF8FAFC));
  Color get backgroundCard => _parseHexColor(backgroundCardHex, Colors.white);

  static Color _parseHexColor(String hex, Color fallback) {
    try {
      final clean = hex.replaceAll('#', '').trim();
      if (clean.length == 6) {
        return Color(int.parse('FF$clean', radix: 16));
      } else if (clean.length == 8) {
        return Color(int.parse(clean, radix: 16));
      }
    } catch (_) {}
    return fallback;
  }
}

class AppFinancesConfig {
  final double taxaBaseEntregaAoa;
  final double valorKmEntregaAoa;
  final double comissaoMarketplacePercentagem;
  final double valorMinimoPedidoAoa;
  final double valorMinimoSaqueAoa;

  const AppFinancesConfig({
    required this.taxaBaseEntregaAoa,
    required this.valorKmEntregaAoa,
    required this.comissaoMarketplacePercentagem,
    required this.valorMinimoPedidoAoa,
    required this.valorMinimoSaqueAoa,
  });

  const AppFinancesConfig.defaults()
      : taxaBaseEntregaAoa = 500.0,
        valorKmEntregaAoa = 150.0,
        comissaoMarketplacePercentagem = 10.0,
        valorMinimoPedidoAoa = 1000.0,
        valorMinimoSaqueAoa = 2000.0;

  factory AppFinancesConfig.fromJson(Map<String, dynamic> json) {
    return AppFinancesConfig(
      taxaBaseEntregaAoa: (json['taxa_base_entrega_aoa'] as num?)?.toDouble() ?? 500.0,
      valorKmEntregaAoa: (json['valor_km_entrega_aoa'] as num?)?.toDouble() ?? 150.0,
      comissaoMarketplacePercentagem: (json['comissao_marketplace_percentagem'] as num?)?.toDouble() ?? 10.0,
      valorMinimoPedidoAoa: (json['valor_minimo_pedido_aoa'] as num?)?.toDouble() ?? 1000.0,
      valorMinimoSaqueAoa: (json['valor_minimo_saque_aoa'] as num?)?.toDouble() ?? 2000.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'taxa_base_entrega_aoa': taxaBaseEntregaAoa,
        'valor_km_entrega_aoa': valorKmEntregaAoa,
        'comissao_marketplace_percentagem': comissaoMarketplacePercentagem,
        'valor_minimo_pedido_aoa': valorMinimoPedidoAoa,
        'valor_minimo_saque_aoa': valorMinimoSaqueAoa,
      };
}

class AppLogisticsConfig {
  final double raioMaximoEntregaKm;
  final double fatorCorrecaoUrbana;
  final bool exigirPinEntrega;

  const AppLogisticsConfig({
    required this.raioMaximoEntregaKm,
    required this.fatorCorrecaoUrbana,
    required this.exigirPinEntrega,
  });

  const AppLogisticsConfig.defaults()
      : raioMaximoEntregaKm = 25.0,
        fatorCorrecaoUrbana = 1.25,
        exigirPinEntrega = true;

  factory AppLogisticsConfig.fromJson(Map<String, dynamic> json) {
    return AppLogisticsConfig(
      raioMaximoEntregaKm: (json['raio_maximo_entrega_km'] as num?)?.toDouble() ?? 25.0,
      fatorCorrecaoUrbana: (json['fator_correcao_urbana'] as num?)?.toDouble() ?? 1.25,
      exigirPinEntrega: json['exigir_pin_entrega'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'raio_maximo_entrega_km': raioMaximoEntregaKm,
        'fator_correcao_urbana': fatorCorrecaoUrbana,
        'exigir_pin_entrega': exigirPinEntrega,
      };
}

class AppMaintenanceConfig {
  final bool ativo;
  final String mensagem;

  const AppMaintenanceConfig({
    required this.ativo,
    required this.mensagem,
  });

  const AppMaintenanceConfig.defaults()
      : ativo = false,
        mensagem = 'Estamos a realizar melhorias na nossa plataforma. Voltamos muito em breve!';

  factory AppMaintenanceConfig.fromJson(Map<String, dynamic> json) {
    return AppMaintenanceConfig(
      ativo: json['ativo'] as bool? ?? false,
      mensagem: json['mensagem']?.toString() ?? 'A plataforma está em manutenção temporária.',
    );
  }

  Map<String, dynamic> toJson() => {
        'ativo': ativo,
        'mensagem': mensagem,
      };
}

class AppBannerItem {
  final String id;
  final String titulo;
  final String subtitulo;
  final String tipoBanner;
  final String publicoAlvo;
  final String imagemUrl;
  final String deeplink;
  final String corFundo;
  final String corTexto;
  final int ordem;

  const AppBannerItem({
    required this.id,
    required this.titulo,
    required this.subtitulo,
    required this.tipoBanner,
    required this.publicoAlvo,
    required this.imagemUrl,
    required this.deeplink,
    required this.corFundo,
    required this.corTexto,
    required this.ordem,
  });

  factory AppBannerItem.fromJson(Map<String, dynamic> json) {
    return AppBannerItem(
      id: json['id']?.toString() ?? '',
      titulo: json['titulo']?.toString() ?? '',
      subtitulo: json['subtitulo']?.toString() ?? '',
      tipoBanner: json['tipo_banner']?.toString() ?? 'HOME_CAROUSEL',
      publicoAlvo: json['publico_alvo']?.toString() ?? 'TODOS',
      imagemUrl: json['imagem_url']?.toString() ?? '',
      deeplink: json['deeplink']?.toString() ?? '',
      corFundo: json['cor_fundo']?.toString() ?? '#EA1D2C',
      corTexto: json['cor_texto']?.toString() ?? '#FFFFFF',
      ordem: (json['ordem'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'titulo': titulo,
        'subtitulo': subtitulo,
        'tipo_banner': tipoBanner,
        'publico_alvo': publicoAlvo,
        'imagem_url': imagemUrl,
        'deeplink': deeplink,
        'cor_fundo': corFundo,
        'cor_texto': corTexto,
        'ordem': ordem,
      };
}
