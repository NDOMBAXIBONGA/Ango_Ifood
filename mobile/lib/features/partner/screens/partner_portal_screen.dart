import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/partner_bloc.dart';
import '../widgets/partner_dashboard_control_widget.dart';
import 'business_hours_config_screen.dart';
import 'menu_management_screen.dart';

/// Ecrã Principal Integrado do Portal do Parceiro Comercial (Tablet / Mobile).
///
/// Agrega de forma harmoniosa:
/// 1. `PartnerDashboardControlWidget`: Painel de controlo superior com toggle de Pausa Temporária
///    e contagem decrescente em tempo real (RN-013);
/// 2. `MenuManagementScreen`: Gestão do catálogo, abas de categorias e produtos com switch de stock (RN-014, RN-015);
/// 3. `BusinessHoursConfigScreen`: Calendário semanal de operação e horários de abertura/fecho (RN-012).
class PartnerPortalScreen extends StatefulWidget {
  const PartnerPortalScreen({super.key});

  @override
  State<PartnerPortalScreen> createState() => _PartnerPortalScreenState();
}

class _PartnerPortalScreenState extends State<PartnerPortalScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
        backgroundColor: colorScheme.surfaceVariant.withOpacity(0.2),
        appBar: AppBar(
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.store_mall_directory, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              const Text(
                'Portal do Parceiro',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          bottom: TabBar(
            controller: _tabController,
            labelColor: colorScheme.primary,
            unselectedLabelColor: colorScheme.onSurfaceVariant,
            indicatorColor: colorScheme.primary,
            indicatorWeight: 3,
            tabs: const [
              Tab(
                icon: Icon(Icons.restaurant_menu),
                text: 'Gestão de Catálogo & Menu (RN-014 / RN-015)',
              ),
              Tab(
                icon: Icon(Icons.access_time_filled),
                text: 'Horários de Operação (RN-012)',
              ),
            ],
          ),
        ),
        body: Column(
          children: [
            // 1. Painel de Controlo Superior (RN-013)
            const PartnerDashboardControlWidget(),

            // 2. Separador de Vistas (Menu vs Horários)
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: const [
                  MenuManagementScreen(),
                  BusinessHoursConfigScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

