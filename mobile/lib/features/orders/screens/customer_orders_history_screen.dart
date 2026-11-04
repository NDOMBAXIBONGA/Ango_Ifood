import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/app_environment_config.dart';
import '../../auth/storage/secure_token_storage.dart';
import '../../checkout/checkout_screen.dart';
import '../../tracking/order_real_time_tracking_screen.dart';
import '../models/customer_order_summary_model.dart';

/// Ecrã de Histórico e Acompanhamento de Pedidos do Cliente (`CustomerOrdersHistoryScreen`).
/// Divide os pedidos entre "Em Andamento" (com atalho para tracking em tempo real)
/// e "Anteriores" (pedidos concluídos ou cancelados).
class CustomerOrdersHistoryScreen extends StatefulWidget {
  final VoidCallback? onExploreTap;

  const CustomerOrdersHistoryScreen({
    super.key,
    this.onExploreTap,
  });

  @override
  State<CustomerOrdersHistoryScreen> createState() =>
      _CustomerOrdersHistoryScreenState();
}

class _CustomerOrdersHistoryScreenState
    extends State<CustomerOrdersHistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final SecureTokenStorage _tokenStorage = SecureTokenStorage();

  bool _isLoading = true;
  List<CustomerOrderSummaryModel> _orders = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadOrders();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadOrders() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final token = await _tokenStorage.getAccessToken();
      final dio = Dio(
        BaseOptions(
          baseUrl: AppEnvironmentConfig.baseHttpUrl,
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 12),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );

      final response = await dio.get('/api/v1/orders/');
      if (response.statusCode == 200) {
        final list = (response.data as List<dynamic>?) ?? [];
        final parsed = list
            .map((item) => CustomerOrderSummaryModel.fromJson(item as Map<String, dynamic>))
            .toList();
        if (mounted) {
          setState(() {
            _orders = parsed;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _orders = [];
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _orders = [];
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final activeOrders = _orders.where((o) => o.isAtivo).toList();
    final pastOrders = _orders.where((o) => !o.isAtivo).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Os Meus Pedidos'),
        bottom: TabBar(
          controller: _tabController,
          labelColor: colorScheme.primary,
          unselectedLabelColor: colorScheme.onSurfaceVariant,
          indicatorColor: colorScheme.primary,
          tabs: [
            Tab(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Em Andamento'),
                  if (activeOrders.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Badge.count(
                      count: activeOrders.length,
                      backgroundColor: colorScheme.primary,
                    ),
                  ],
                ],
              ),
            ),
            const Tab(text: 'Anteriores'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildOrderList(
                  context,
                  orders: activeOrders,
                  isActiveTab: true,
                ),
                _buildOrderList(
                  context,
                  orders: pastOrders,
                  isActiveTab: false,
                ),
              ],
            ),
    );
  }

  Widget _buildOrderList(
    BuildContext context, {
    required List<CustomerOrderSummaryModel> orders,
    required bool isActiveTab,
  }) {
    if (orders.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadOrders,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 48),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.35),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isActiveTab
                      ? Icons.delivery_dining_outlined
                      : Icons.receipt_long_outlined,
                  size: 64,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isActiveTab
                    ? 'Sem pedidos em andamento'
                    : 'Nenhum pedido anterior',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                isActiveTab
                    ? 'Quando fizer um pedido, poderá acompanhar aqui o preparo e a entrega em tempo real.'
                    : 'Os seus pedidos finalizados e histórico de compras serão apresentados aqui.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: widget.onExploreTap ?? _loadOrders,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Atualizar Lista'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadOrders,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: orders.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final order = orders[index];
          return _buildOrderCard(context, order);
        },
      ),
    );
  }

  Widget _buildOrderCard(
    BuildContext context,
    CustomerOrderSummaryModel order,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    Color badgeColor = colorScheme.primaryContainer;
    Color textColor = colorScheme.onPrimaryContainer;

    if (order.estado.toUpperCase().contains('CANCEL')) {
      badgeColor = colorScheme.errorContainer;
      textColor = colorScheme.onErrorContainer;
    } else if (order.estado.toUpperCase().contains('ENTREG')) {
      badgeColor = Colors.green.shade100;
      textColor = Colors.green.shade900;
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    order.lojaNome,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: badgeColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    order.estadoDisplay,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: textColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              order.itensNomes.isNotEmpty
                  ? order.itensNomes.join(', ')
                  : 'Pedido #${order.id.substring(0, 8)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  CurrencyFormatter.formatKwanza(order.totalCobradoCentimos),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colorScheme.primary,
                  ),
                ),
                if (order.isAtivo)
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => OrderRealTimeTrackingScreen(
                            pedidoId: order.id,
                            jwtToken: '',
                            nomeLoja: order.lojaNome,
                            moradaLojaTexto: 'Restaurante ${order.lojaNome}',
                            coordenadasLoja: const LatLng(-8.839988, 13.289437),
                            moradaClienteTexto: 'Luanda, Angola',
                            coordenadasCliente: const LatLng(-8.836804, 13.234321),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.radar_rounded, size: 18),
                    label: const Text('Rastrear ao Vivo'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

