import 'package:flutter/material.dart';

import '../models/auth_models.dart';
import '../theme/role_theme.dart';
import '../../catalog/customer_main_navigation_shell.dart';
import '../../partner/screens/partner_main_navigation_shell.dart';
import '../../courier/screens/courier_main_navigation_shell.dart';

/// Retorna o ecrã inicial de destino no interior da aplicação
/// de acordo com o papel (Role) selecionado pelo utilizador.
Widget getHomeScreenForRole(PlatformRole role) {
  switch (role) {
    case PlatformRole.cliente:
      return const CustomerMainNavigationShell();
    case PlatformRole.parceiro:
      return const PartnerMainNavigationShell();
    case PlatformRole.estafeta:
      return const CourierMainNavigationShell();
  }
}

/// Route Guard RBAC: Garante isolamento estrito de papéis na plataforma.
/// Cada conta criada para "Comprar" (Cliente), "Negócio" (Parceiro) ou "Entregar" (Estafeta)
/// é exclusiva para essa atividade no sistema e navega estritamente para a sua área correspondente:
/// - CLIENTE -> CustomerMainNavigationShell
/// - PARCEIRO -> PartnerMainNavigationShell
/// - ESTAFETA -> CourierMainNavigationShell
Widget getAuthorizedHomeScreen({
  required UserProfile user,
  required PlatformRole requestedRole,
  required BuildContext context,
}) {
  final userRole = user.tipoUtilizador.toUpperCase();

  // 1. Conta oficial de PARCEIRO (Tenho um Negócio)
  if (userRole == 'PARCEIRO') {
    if (requestedRole != PlatformRole.parceiro) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                'A sua conta é de Parceiro Comercial. Redirecionado para o Portal do Restaurante.',
              ),
            ),
          );
      });
    }
    RoleThemeManager.instance.setRole(PlatformRole.parceiro);
    return const PartnerMainNavigationShell();
  }

  // 2. Conta oficial de ESTAFETA (Quero Entregar)
  if (userRole == 'ESTAFETA') {
    if (requestedRole != PlatformRole.estafeta) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                'A sua conta é de Estafeta. Redirecionado para a Central de Entregas.',
              ),
            ),
          );
      });
    }
    RoleThemeManager.instance.setRole(PlatformRole.estafeta);
    return const CourierMainNavigationShell();
  }

  // 3. Administrador de Plataforma
  if (userRole == 'ADMIN') {
    return getHomeScreenForRole(requestedRole);
  }

  // 4. Conta oficial de CLIENTE (Quero Comprar)
  if (requestedRole != PlatformRole.cliente) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'A sua conta é de Cliente. Redirecionado para a área de compras.',
            ),
          ),
        );
    });
  }
  RoleThemeManager.instance.setRole(PlatformRole.cliente);
  return const CustomerMainNavigationShell();
}


