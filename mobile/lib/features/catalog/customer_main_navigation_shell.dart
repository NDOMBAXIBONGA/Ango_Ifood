import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/app_environment_config.dart';
import '../cart/cart.dart';
import '../orders/screens/customer_orders_history_screen.dart';
import '../profile/screens/customer_profile_screen.dart';
import 'customer_catalog_screens.dart';

/// Shell Principal de Navegação do Cliente (`CustomerMainNavigationShell`).
/// Unifica as 4 abas estruturais da aplicação:
/// 1. **Início** (Catálogo de Lojas, Cozinhas e Filtros);
/// 2. **Carrinho** (Sacola de Compras com contador dinâmico e checkout);
/// 3. **Pedidos** (Acompanhamento em tempo real e histórico);
/// 4. **Perfil** (Dados do utilizador, moradas e logout seguro).
class CustomerMainNavigationShell extends StatefulWidget {
  final int initialIndex;

  const CustomerMainNavigationShell({
    super.key,
    this.initialIndex = 0,
  });

  @override
  State<CustomerMainNavigationShell> createState() =>
      _CustomerMainNavigationShellState();
}

class _CustomerMainNavigationShellState
    extends State<CustomerMainNavigationShell> {
  late int _currentIndex;
  int _ordersRefreshCount = 0;
  late final CatalogRepository _catalogRepository;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _catalogRepository = CatalogRepository(
      baseUrl: AppEnvironmentConfig.baseHttpUrl,
    );
  }

  void _onTabSelected(int index) {
    setState(() {
      _currentIndex = index;
      if (index == 2) {
        _ordersRefreshCount++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AnimatedBuilder(
      animation: CartService.instance,
      builder: (context, _) {
        final totalCartItems = CartService.instance.totalItemsCount;

        return RepositoryProvider<CatalogRepository>.value(
          value: _catalogRepository,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<StoreDiscoveryBloc>(
                create: (ctx) => StoreDiscoveryBloc(
                  repository: _catalogRepository,
                  initialAddress: const CustomerGeoAddress(
                    label: 'Minha Morada',
                    fullAddress: 'Luanda, Angola',
                    latitude: -8.839988,
                    longitude: 13.289437,
                  ),
                )..add(
                    const LoadStoresForLocationEvent(
                      address: CustomerGeoAddress(
                        label: 'Minha Morada',
                        fullAddress: 'Luanda, Angola',
                        latitude: -8.839988,
                        longitude: 13.289437,
                      ),
                    ),
                  ),
              ),
            ],
            child: Scaffold(
              body: IndexedStack(
                index: _currentIndex,
                children: [
                  const HomeScreen(),
                  CartScreen(
                    onExploreTap: () => _onTabSelected(0),
                  ),
                  CustomerOrdersHistoryScreen(
                    onExploreTap: () => _onTabSelected(0),
                    refreshTrigger: _ordersRefreshCount,
                  ),
                  const CustomerProfileScreen(),
                ],
              ),
              bottomNavigationBar: NavigationBar(
                selectedIndex: _currentIndex,
                onDestinationSelected: _onTabSelected,
                elevation: 4,
                indicatorColor: colorScheme.primaryContainer,
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.storefront_outlined),
                    selectedIcon: Icon(Icons.storefront_rounded),
                    label: 'Início',
                  ),
                  NavigationDestination(
                    icon: totalCartItems > 0
                        ? Badge.count(
                            count: totalCartItems,
                            backgroundColor: colorScheme.primary,
                            child: const Icon(Icons.shopping_bag_outlined),
                          )
                        : const Icon(Icons.shopping_bag_outlined),
                    selectedIcon: totalCartItems > 0
                        ? Badge.count(
                            count: totalCartItems,
                            backgroundColor: colorScheme.primary,
                            child: const Icon(Icons.shopping_bag_rounded),
                          )
                        : const Icon(Icons.shopping_bag_rounded),
                    label: 'Carrinho',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.receipt_long_outlined),
                    selectedIcon: Icon(Icons.receipt_long_rounded),
                    label: 'Pedidos',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.person_outline_rounded),
                    selectedIcon: Icon(Icons.person_rounded),
                    label: 'Perfil',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

