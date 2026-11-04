import 'package:flutter/material.dart';

import '../theme/role_theme.dart';
import '../../catalog/customer_catalog_screens.dart';
import '../../partner/screens/partner_portal_screen.dart';
import '../../courier/courier_flow_screens.dart';

/// Retorna o ecrã inicial de destino no interior da aplicação
/// de acordo com o papel (Role) selecionado pelo utilizador.
Widget getHomeScreenForRole(PlatformRole role) {
  switch (role) {
    case PlatformRole.cliente:
      return const HomeScreen();
    case PlatformRole.parceiro:
      return const PartnerPortalScreen();
    case PlatformRole.estafeta:
      return const CourierMainAppNavigation();
  }
}
