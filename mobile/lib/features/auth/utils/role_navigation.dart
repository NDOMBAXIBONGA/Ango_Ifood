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

/// Route Guard RBAC: Valida se o papel oficial da conta do utilizador confere
/// acesso à área pretendida. Se um utilizador com conta 'CLIENTE' tentar abrir áreas
/// de Parceiro ou Estafeta, o acesso é bloqueado e o utilizador é redirecionado
/// com segurança para o CustomerMainNavigationShell.
Widget getAuthorizedHomeScreen({
  required UserProfile user,
  required PlatformRole requestedRole,
  required BuildContext context,
}) {
  final userRole = user.tipoUtilizador.toUpperCase();

  // Caso 1: Utilizador é CLIENTE e tentou abrir Parceiro ou Estafeta
  if (userRole == 'CLIENTE' && requestedRole != PlatformRole.cliente) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              'A sua conta está registada como Cliente. Redirecionado para a área de compras.',
            ),
          ),
        );
    });
    return const CustomerMainNavigationShell();
  }

  // Caso 2: Área de Parceiro solicitada
  if (requestedRole == PlatformRole.parceiro) {
    if (userRole != 'PARCEIRO' && userRole != 'ADMIN') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                'Acesso restrito: Esta conta não possui perfil de parceiro comercial ativo.',
              ),
            ),
          );
      });
      return const CustomerMainNavigationShell();
    }
    return const PartnerMainNavigationShell();
  }

  // Caso 3: Área de Estafeta solicitada
  if (requestedRole == PlatformRole.estafeta) {
    if (userRole != 'ESTAFETA' && userRole != 'ADMIN') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                'Acesso restrito: Esta conta não possui registo aprovado de estafeta.',
              ),
            ),
          );
      });
      return const CustomerMainNavigationShell();
    }
    return const CourierMainNavigationShell();
  }

  return getHomeScreenForRole(requestedRole);
}


