import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../courier_flow_screens.dart';
import '../courier_wallet_screen.dart';
import 'active_delivery_flow_screen.dart';
import 'courier_profile_screen.dart';

/// Shell de Navegação Principal do Estafeta / Courier (`CourierMainNavigationShell`).
/// Unifica as 4 abas estruturais do Estafeta:
/// 1. **Radar**: Despacho geográfico, toggle Online/Offline e telemetria GPS (RN-083, RN-094);
/// 2. **Corrida Ativa**: Fluxo de 5 etapas para recolha e validação do PIN de 4 dígitos (RN-095);
/// 3. **Carteira**: Saldo acumulado, 100% das gorjetas (RN-058) e pedidos de saque;
/// 4. **Perfil & Viatura**: Documentação, veículo, reputação e logout.
class CourierMainNavigationShell extends StatefulWidget {
  final int initialIndex;

  const CourierMainNavigationShell({
    super.key,
    this.initialIndex = 0,
  });

  @override
  State<CourierMainNavigationShell> createState() =>
      _CourierMainNavigationShellState();
}

class _CourierMainNavigationShellState
    extends State<CourierMainNavigationShell> {
  late int _currentIndex;

  static const CourierProfileModel _defaultProfile = CourierProfileModel(
    id: 'est-main-profile',
    nome: 'Mateus Sebastião',
    telemovel: '+244923111222',
    nif: '009842180LA042',
    bancoNome: 'Banco Angolano de Investimentos (BAI)',
    numeroConta: '0040.0000.1234.5678',
    iban: 'AO06.0040.0000.1234.5678.9012.3',
    vehicleType: VehicleType.mota,
    cartaConducaoNumero: '994821802LA04',
    cartaConducaoUrl: 'https://cdn.platform.com/docs/license.pdf',
    documentosVeiculoUrl: 'https://cdn.platform.com/docs/vehicle.pdf',
    onboardingStatus: OnboardingStatus.aprovado,
    isOnline: true,
    latitude: -8.839988,
    longitude: 13.289437,
    ganhosHojeCentimos: 850000,
    entregasConcluidasHoje: 4,
    scoreReputacao: 4.9,
  );

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
    return BlocProvider<CourierBloc>(
      create: (context) => CourierBloc(
        repository: CourierRepository(),
      )..emit(const CourierActiveLoaded(profile: _defaultProfile)),
      child: Scaffold(
        backgroundColor: const Color(0xFF121417),
        body: IndexedStack(
          index: _currentIndex,
          children: [
            // Aba 0: Radar de Despacho
            const CourierHomepageScreen(profile: _defaultProfile),

            // Aba 1: Corrida Ativa & Validação de PIN
            ActiveDeliveryFlowScreen(
              onGoToRadar: () => _onTabSelected(0),
            ),

            // Aba 2: Carteira Digital & Repasses
            const CourierWalletScreen(),

            // Aba 3: Perfil, Viatura e Logout
            const CourierProfileScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _onTabSelected,
          elevation: 4,
          backgroundColor: const Color(0xFF1A1D23),
          indicatorColor: const Color(0xFF00E676).withOpacity(0.2),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.radar_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.radar_rounded, color: Color(0xFF00E676)),
              label: 'Radar',
            ),
            NavigationDestination(
              icon: Icon(Icons.delivery_dining_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.delivery_dining_rounded, color: Color(0xFF00E676)),
              label: 'Corrida',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined, color: Colors.white70),
              selectedIcon: Icon(Icons.account_balance_wallet_rounded, color: Color(0xFF00E676)),
              label: 'Carteira',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline_rounded, color: Colors.white70),
              selectedIcon: Icon(Icons.person_rounded, color: Color(0xFF00E676)),
              label: 'Perfil',
            ),
          ],
        ),
      ),
    );
  }
}

