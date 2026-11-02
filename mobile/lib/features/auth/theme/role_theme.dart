/// Gestão de Papéis da Plataforma (Cliente, Parceiro, Estafeta)
/// e Adaptação Dinâmica do Tema Material Design 3.

import 'package:flutter/material.dart';

/// Os 3 Perfis Oficiais do Ecossistema de Delivery.
enum PlatformRole {
  cliente,
  parceiro,
  estafeta,
}

extension PlatformRoleExtension on PlatformRole {
  String get displayName {
    switch (this) {
      case PlatformRole.cliente:
        return 'Cliente';
      case PlatformRole.parceiro:
        return 'Parceiro';
      case PlatformRole.estafeta:
        return 'Estafeta';
    }
  }

  String get title {
    switch (this) {
      case PlatformRole.cliente:
        return 'Quero Comprar';
      case PlatformRole.parceiro:
        return 'Tenho um Negócio';
      case PlatformRole.estafeta:
        return 'Quero Entregar';
    }
  }

  String get subtitle {
    switch (this) {
      case PlatformRole.cliente:
        return 'Encomende dos seus restaurantes e lojas favoritas com entrega rápida.';
      case PlatformRole.parceiro:
        return 'Faça a gestão do seu catálogo, aumente as suas vendas e receba pedidos.';
      case PlatformRole.estafeta:
        return 'Trabalhe com horários flexíveis e ganhe dinheiro por cada entrega.';
    }
  }

  IconData get icon {
    switch (this) {
      case PlatformRole.cliente:
        return Icons.shopping_bag_outlined;
      case PlatformRole.parceiro:
        return Icons.storefront_outlined;
      case PlatformRole.estafeta:
        return Icons.two_wheeler_outlined;
    }
  }

  /// Cor de destaque primária dinâmica da aplicação (Material 3).
  Color get primaryColor {
    switch (this) {
      case PlatformRole.cliente:
        return const Color(0xFF00A86B); // Verde Esmeralda / Cliente
      case PlatformRole.parceiro:
        return const Color(0xFF1E88E5); // Azul Cobalto / Parceiro Comercial
      case PlatformRole.estafeta:
        return const Color(0xFFFF6D00); // Laranja Tangerina / Estafeta
    }
  }

  Color get secondaryColor {
    switch (this) {
      case PlatformRole.cliente:
        return const Color(0xFF059669);
      case PlatformRole.parceiro:
        return const Color(0xFF1565C0);
      case PlatformRole.estafeta:
        return const Color(0xFFE65100);
    }
  }

  ColorScheme get colorScheme {
    return ColorScheme.fromSeed(
      seedColor: primaryColor,
      primary: primaryColor,
      brightness: Brightness.light,
    );
  }
}

/// InheritedNotifier ou Gerenciador Reativo do Papel Atual da Aplicação.
class RoleThemeManager extends ChangeNotifier {
  PlatformRole _currentRole = PlatformRole.cliente;

  PlatformRole get currentRole => _currentRole;
  Color get primaryColor => _currentRole.primaryColor;
  ColorScheme get colorScheme => _currentRole.colorScheme;

  void setRole(PlatformRole role) {
    if (_currentRole != role) {
      _currentRole = role;
      notifyListeners();
    }
  }

  static final RoleThemeManager instance = RoleThemeManager();
}

