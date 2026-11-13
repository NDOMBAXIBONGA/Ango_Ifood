import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/app_environment_config.dart';
import '../../auth/storage/secure_token_storage.dart';
import '../../cart/cart.dart';
import '../../checkout/checkout_screen.dart';
import '../../tracking/order_real_time_tracking_screen.dart';
import '../models/customer_order_summary_model.dart';

/// Ecrã de Histórico e Acompanhamento de Pedidos do Cliente (`CustomerOrdersHistoryScreen`).
/// Divide os pedidos entre "Em Andamento" (com atalho para tracking em tempo real, PIN RN-094 e cancelamento)
/// e "Anteriores" (pedidos concluídos ou cancelados, com Pedir Novamente e Avaliação RN-019).
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

  Future<Dio> _buildAuthDio() async {
    final token = await _tokenStorage.getAccessToken();
    return Dio(
      BaseOptions(
        baseUrl: AppEnvironmentConfig.baseHttpUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (token != null && token.isNotEmpty)
            'Authorization': 'Bearer $token',
        },
      ),
    );
  }

  Future<void> _loadOrders() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final dio = await _buildAuthDio();
      final response = await dio.get<dynamic>('/api/v1/orders/');
      if (response.statusCode == 200 && response.data != null) {
        final raw = response.data;
        List<dynamic> list = const [];
        if (raw is List) {
          list = raw;
        } else if (raw is Map<String, dynamic> && raw['results'] is List) {
          list = raw['results'] as List<dynamic>;
        }
        final parsed = list
            .whereType<Map<String, dynamic>>()
            .map(CustomerOrderSummaryModel.fromJson)
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

  Future<void> _cancelOrder(CustomerOrderSummaryModel order) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancelar Pedido?'),
        content: Text(
          'Tem a certeza que deseja cancelar o pedido em "${order.lojaNome}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirmar Cancelamento'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    try {
      final dio = await _buildAuthDio();
      await dio.post<dynamic>(
        '/api/v1/orders/${order.id}/cancelar/',
        data: {'motivo': 'Cancelado pelo cliente no histórico de pedidos'},
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pedido cancelado com sucesso.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        await _loadOrders();
      }
    } on DioException catch (e) {
      final msg = (e.response?.data is Map)
          ? (e.response?.data['detalhe'] ??
              e.response?.data['detail'] ??
              'Não foi possível cancelar o pedido.')
          : 'Não foi possível cancelar o pedido.';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$msg'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _rateOrder(CustomerOrderSummaryModel order) async {
    int selectedStars = 5;
    final commentCtrl = TextEditingController();

    final submitted = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          title: Text('Avaliar ${order.lojaNome}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Como foi a sua experiência com este pedido? (RN-019)'),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (index) {
                  final starNumber = index + 1;
                  return IconButton(
                    onPressed: () =>
                        setModalState(() => selectedStars = starNumber),
                    icon: Icon(
                      starNumber <= selectedStars
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: Colors.amber.shade700,
                      size: 34,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: commentCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Comentário (opcional)',
                  hintText: 'Conte-nos o que achou da comida e da entrega...',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Enviar Avaliação'),
            ),
          ],
        ),
      ),
    );

    if (submitted != true || !mounted) return;

    try {
      final dio = await _buildAuthDio();
      await dio.post<dynamic>(
        '/api/v1/orders/${order.id}/avaliar/',
        data: {
          'estrelas': selectedStars,
          'comentario': commentCtrl.text.trim(),
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Obrigado! Avaliação de $selectedStars ★ enviada para ${order.lojaNome}.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Avaliação registada com sucesso!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _reorder(CustomerOrderSummaryModel order) {
    if (order.linhas.isEmpty || order.lojaId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Explore o menu da loja para repetir o pedido.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      widget.onExploreTap?.call();
      return;
    }

    final cart = CartService.instance;
    cart.clear();
    for (final line in order.linhas) {
      if (line.itemId.isEmpty) continue;
      cart.addItem(
        itemId: line.itemId,
        lojaId: order.lojaId,
        lojaNome: order.lojaNome,
        nome: line.nome,
        imagemUrl: order.lojaImagem,
        precoUnitarioCentimos: line.precoUnitarioCentimos,
        quantidade: line.quantidade,
        notas: line.notas,
      );
    }

    if (cart.isEmpty) {
      widget.onExploreTap?.call();
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CheckoutScreen(
          lojaId: order.lojaId,
          lojaNome: order.lojaNome,
          moradaId: cart.moradaId,
          moradaLabel: cart.moradaLabel,
          moradaTexto: cart.moradaTexto,
          itensCarrinho: cart.toCheckoutInputs(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final activeOrders = _orders.where((o) => o.isAtivo).toList();
    final pastOrders = _orders.where((o) => !o.isAtivo).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Os Meus Pedidos'),
        actions: [
          IconButton(
            tooltip: 'Atualizar Pedidos',
            onPressed: _loadOrders,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
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
                  color: Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withOpacity(0.35),
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
                    ? 'Quando fizer um pedido, poderá acompanhar aqui o preparo, o PIN de entrega e o estafeta em tempo real.'
                    : 'Os seus pedidos finalizados e histórico de compras serão apresentados aqui.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: widget.onExploreTap ?? _loadOrders,
                icon: const Icon(Icons.restaurant_menu_rounded),
                label: Text(
                  widget.onExploreTap != null
                      ? 'Explorar Restaurantes'
                      : 'Atualizar Lista',
                ),
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
        separatorBuilder: (_, __) => const SizedBox(height: 14),
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
    } else if (order.estado.toUpperCase().contains('ENTREG') ||
        order.estado.toUpperCase().contains('CONCLU')) {
      badgeColor = Colors.green.shade100;
      textColor = Colors.green.shade900;
    }

    final shortId =
        order.id.length >= 8 ? order.id.substring(0, 8).toUpperCase() : order.id;
    final dateStr =
        '${order.dataCriacao.day.toString().padLeft(2, '0')}/${order.dataCriacao.month.toString().padLeft(2, '0')} às ${order.dataCriacao.hour.toString().padLeft(2, '0')}:${order.dataCriacao.minute.toString().padLeft(2, '0')}';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.6)),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.lojaNome,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Pedido #$shortId • $dateStr',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
            if (order.isAtivo) ...[
              const SizedBox(height: 12),
              _buildStepProgressBar(context, order.etapaProgresso),
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.lock_person_outlined,
                          size: 18,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'PIN de Entrega (RN-094):',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      order.pinEntrega,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              order.itensNomes.isNotEmpty
                  ? order.itensNomes.join(' • ')
                  : 'Pedido #$shortId',
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total Cobrado',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      CurrencyFormatter.formatKwanza(order.totalCobradoCentimos),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    if (order.isAtivo && order.podeCancelar)
                      OutlinedButton(
                        onPressed: () => _cancelOrder(order),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text('Cancelar'),
                      ),
                    if (order.isAtivo)
                      FilledButton.icon(
                        onPressed: () async {
                          final token =
                              await _tokenStorage.getAccessToken() ?? '';
                          if (!context.mounted) return;
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => OrderRealTimeTrackingScreen(
                                pedidoId: order.id,
                                jwtToken: token,
                                nomeLoja: order.lojaNome,
                                moradaLojaTexto: 'Restaurante ${order.lojaNome}',
                                coordenadasLoja:
                                    const LatLng(-8.839988, 13.289437),
                                moradaClienteTexto: order.moradaEntrega,
                                coordenadasCliente: LatLng(
                                  CartService.instance.latitude,
                                  CartService.instance.longitude,
                                ),
                                pinEntrega: order.pinEntrega.isNotEmpty
                                    ? order.pinEntrega
                                    : '7429',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.radar_rounded, size: 18),
                        label: const Text('Acompanhar'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    if (!order.isAtivo) ...[
                      OutlinedButton.icon(
                        onPressed: () => _rateOrder(order),
                        icon: const Icon(Icons.star_outline_rounded, size: 18),
                        label: const Text('Avaliar'),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _reorder(order),
                        icon: const Icon(Icons.replay_rounded, size: 18),
                        label: const Text('Pedir Novamente'),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepProgressBar(BuildContext context, int activeStep) {
    final colorScheme = Theme.of(context).colorScheme;
    const labels = ['Confirmado', 'Cozinha', 'A Caminho', 'Entregue'];

    return Row(
      children: List.generate(labels.length, (i) {
        final step = i + 1;
        final done = step <= activeStep;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < labels.length - 1 ? 6 : 0),
            child: Column(
              children: [
                Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: done
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: done ? FontWeight.bold : FontWeight.normal,
                    color: done
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

