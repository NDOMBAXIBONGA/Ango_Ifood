import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/partner_bloc.dart';
import '../partner_order_terminal_screen.dart';
import '../widgets/partner_dashboard_control_widget.dart';
import 'business_hours_config_screen.dart';
import 'menu_management_screen.dart';
import 'partner_store_profile_screen.dart';

/// Shell de Navegação Principal do Parceiro Comercial (`PartnerMainNavigationShell`).
/// Unifica as 4 abas estruturais do Portal do Parceiro:
/// 1. **Pedidos (KDS)**: Terminal de gestão de pedidos de cozinha em tempo real (RN-075 a RN-077);
/// 2. **Cardápio**: Gestão do menu, preços e controlo de stock (RN-014, RN-015);
/// 3. **Horários**: Calendário semanal de funcionamento (RN-012);
/// 4. **Loja & Finanças**: Faturamento, comissões e dados do estabelecimento.
class PartnerMainNavigationShell extends StatefulWidget {
  final int initialIndex;

  const PartnerMainNavigationShell({
    super.key,
    this.initialIndex = 0,
  });

  @override
  State<PartnerMainNavigationShell> createState() =>
      _PartnerMainNavigationShellState();
}

class _PartnerMainNavigationShellState
    extends State<PartnerMainNavigationShell> {
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  void _onTabSelected(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocProvider(
      create: (ctx) => PartnerBloc(
        repository: PartnerRepository(),
      )..add(const LoadPartnerDataRequested()),
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            // Aba 0: Terminal KDS de Cozinha (Pedidos em Tempo Real)
            const PartnerOrderTerminalScreen(),

            // Aba 1: Cardápio e Stock (com barra de pausa de emergência no topo)
            Column(
              children: const [
                PartnerDashboardControlWidget(),
                Expanded(child: MenuManagementScreen()),
              ],
            ),

            // Aba 2: Horários de Abertura / Fecho
            const BusinessHoursConfigScreen(),

            // Aba 3: Perfil da Loja e Relatório Financeiro
            const PartnerStoreProfileScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _onTabSelected,
          elevation: 4,
          indicatorColor: colorScheme.primaryContainer,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.kitchen_outlined),
              selectedIcon: Icon(Icons.kitchen_rounded),
              label: 'Pedidos KDS',
            ),
            NavigationDestination(
              icon: Icon(Icons.restaurant_menu_outlined),
              selectedIcon: Icon(Icons.restaurant_menu_rounded),
              label: 'Cardápio',
            ),
            NavigationDestination(
              icon: Icon(Icons.access_time_outlined),
              selectedIcon: Icon(Icons.access_time_filled),
              label: 'Horários',
            ),
            NavigationDestination(
              icon: Icon(Icons.storefront_outlined),
              selectedIcon: Icon(Icons.storefront_rounded),
              label: 'Minha Loja',
            ),
          ],
        ),
      ),
    );
  }
}
