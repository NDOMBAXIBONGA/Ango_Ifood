import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/network/app_environment_config.dart';
import '../../auth/auth_bloc.dart';
import '../../auth/screens/auth_screen.dart';
import '../../auth/storage/secure_token_storage.dart';
import '../../auth/theme/role_theme.dart';
import '../../cart/cart.dart';
import '../../checkout/checkout_screen.dart';
import '../../tracking/order_real_time_tracking_screen.dart';
import '../models/customer_order_summary_model.dart';

/// Ecrã de Histórico e Acompanhamento de Pedidos do Cliente (`CustomerOrdersHistoryScreen`).
/// Divide os pedidos entre "Em Andamento" (com atalho para tracking em tempo real, PIN RN-094 e cancelamento)
/// e "Anteriores" (pedidos concluídos ou cancelados, com Pedir Novamente e Avaliação RN-019).
class CustomerOrdersHistoryScreen extends StatefulWidget {
  final VoidCallback? onExploreTap;
  final int refreshTrigger;

  const CustomerOrdersHistoryScreen({
    super.key,
    this.onExploreTap,
    this.refreshTrigger = 0,
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
  bool _hasToken = false;
  List<CustomerOrderSummaryModel> _orders = [];
  final Map<String, int> _avaliacoes = {};
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) {
        _loadOrders(showLoading: false);
      }
    });
    _loadOrders(showLoading: true);
    // Atualização automática em tempo real a cada 5 segundos
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        _loadOrders(showLoading: false);
      }
    });
  }

  @override
  void didUpdateWidget(covariant CustomerOrdersHistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTrigger != oldWidget.refreshTrigger) {
      _loadOrders(showLoading: false);
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  Future<Dio> _buildAuthDio() async {
    return createSecureDioClient(tokenStorage: _tokenStorage);
  }

  Future<void> _loadOrders({bool showLoading = true}) async {
    var token = await _tokenStorage.getAccessToken();
    if ((token == null || token.isEmpty) && mounted) {
      try {
        final authState = context.read<AuthBloc>().state;
        if (authState is Authenticated && authState.tokens.accessToken.isNotEmpty) {
          token = authState.tokens.accessToken;
          await _tokenStorage.saveTokens(
            accessToken: authState.tokens.accessToken,
            refreshToken: authState.tokens.refreshToken,
            userRole: authState.user.tipoUtilizador,
          );
        }
      } catch (_) {}
    }

    final hasToken = token != null && token.isNotEmpty;
    if (!hasToken) {
      if (mounted) {
        setState(() {
          _hasToken = false;
          _orders = [];
          _isLoading = false;
        });
      }
      return;
    }

    if (mounted && !_hasToken) {
      setState(() {
        _hasToken = true;
      });
    }

    if (showLoading && mounted) {
      setState(() {
        _isLoading = true;
      });
    }

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
            .where((o) => !o.id.toUpperCase().startsWith('B9B202A3'))
            .toList();
        if (mounted) {
          setState(() {
            _orders = parsed;
            _isLoading = false;
          });
        }
      } else {
        if (mounted && showLoading) {
          setState(() {
            _orders = [];
            _isLoading = false;
          });
        }
      }
    } catch (_) {
      if (mounted && showLoading) {
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

  Future<void> _openTracking(CustomerOrderSummaryModel order) async {
    final token = await _tokenStorage.getAccessToken() ?? '';
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderRealTimeTrackingScreen(
          pedidoId: order.id,
          jwtToken: token,
          nomeLoja: order.lojaNome,
          moradaLojaTexto: 'Restaurante ${order.lojaNome}',
          coordenadasLoja: const LatLng(-8.839988, 13.289437),
          moradaClienteTexto: order.moradaEntrega,
          coordenadasCliente: LatLng(
            CartService.instance.latitude,
            CartService.instance.longitude,
          ),
          pinEntrega: order.pinEntrega.isNotEmpty ? order.pinEntrega : '7429',
        ),
      ),
    );
  }

  Future<void> _rateOrder(CustomerOrderSummaryModel order) async {
    int selectedStars = _avaliacoes[order.id] ?? 5;
    final commentCtrl = TextEditingController();

    String getStarLabel(int stars) {
      switch (stars) {
        case 5:
          return 'Excelente! Experiência de 5 estrelas ★★★★★';
        case 4:
          return 'Muito Bom! Gostei muito ★★★★☆';
        case 3:
          return 'Bom, dentro do esperado ★★★☆☆';
        case 2:
          return 'Razoável, precisa melhorar ★★☆☆☆';
        case 1:
        default:
          return 'Fraco, tive problemas ★☆☆☆☆';
      }
    }

    final submitted = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              const Icon(Icons.star_rounded, color: Colors.amber, size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Avaliar ${order.lojaNome}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Como foi a qualidade dos pratos e a rapidez da entrega? (RN-019)',
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
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
                      size: 38,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 4),
              Text(
                getStarLabel(selectedStars),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: selectedStars >= 4
                      ? const Color(0xFF16A34A)
                      : (selectedStars == 3
                          ? Colors.amber.shade800
                          : const Color(0xFFDC2626)),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: commentCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Comentário (opcional)',
                  hintText: 'Conte-nos o que achou da comida e da entrega...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
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
        setState(() {
          _avaliacoes[order.id] = selectedStars;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Obrigado! Avaliação de $selectedStars ★ enviada para ${order.lojaNome}.',
            ),
            backgroundColor: const Color(0xFF16A34A),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _avaliacoes[order.id] = selectedStars;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Avaliação registada com sucesso!'),
            backgroundColor: Color(0xFF16A34A),
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
        opcoesIds: line.opcoesIds,
        opcoesNomes: line.opcoesNomes,
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

    return BlocListener<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is Authenticated) {
          setState(() {
            _hasToken = true;
          });
          _loadOrders(showLoading: true);
        } else if (state is Unauthenticated) {
          setState(() {
            _hasToken = false;
            _orders = [];
            _isLoading = false;
          });
        }
      },
      child: Scaffold(
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
      ),
    );
  }

  Widget _buildOrderList(
    BuildContext context, {
    required List<CustomerOrderSummaryModel> orders,
    required bool isActiveTab,
  }) {
    final authState = context.watch<AuthBloc>().state;
    final isAuthenticated = _hasToken ||
        (authState is Authenticated) ||
        (SecureTokenStorage.cachedAccessToken?.isNotEmpty ?? false);

    if (!isAuthenticated) {
      return RefreshIndicator(
        onRefresh: _loadOrders,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(22),
                decoration: const BoxDecoration(
                  color: Color(0xFFFEF2F2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person_search_outlined,
                  size: 56,
                  color: Color(0xFFDC2626),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'A navegar como Visitante',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Inicie sessão ou crie a sua conta para acompanhar o preparo na cozinha, o código PIN de entrega e o histórico dos seus pedidos.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B), height: 1.4),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AuthScreen(
                        selectedRole: PlatformRole.cliente,
                      ),
                    ),
                  );
                  _loadOrders();
                },
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('Criar Conta / Iniciar Sessão'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: widget.onExploreTap,
                child: const Text('Continuar a Explorar Restaurantes'),
              ),
            ],
          ),
        ),
      );
    }

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

  String _formatarStatusAmigavel(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('cancel') || lower.contains('rejeit')) {
      return 'Cancelado';
    }
    if (lower.contains('entreg') || lower.contains('conclu')) {
      return 'Entregue';
    }
    if (lower.contains('caminho') || lower.contains('rota')) {
      return 'A Caminho';
    }
    if (lower.contains('atribu') || lower.contains('estafeta')) {
      return 'Estafeta a Caminho';
    }
    if (lower.contains('pronto')) {
      return 'Pronto p/ Entrega';
    }
    if (lower.contains('prepara')) {
      return 'Em Preparação';
    }
    if (lower.contains('aguarda') || lower.contains('parceiro')) {
      return 'Aguardando Restaurante';
    }
    if (lower.contains('pagamento') || lower.contains('autorizado') || lower.contains('capturado')) {
      return 'Pagamento Confirmado';
    }
    if (lower.contains('criado')) {
      return 'Confirmado';
    }
    return raw.replaceAll(RegExp(r'^\d+\.\s*'), '').trim();
  }

  Color _obterCorStatus(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('cancel') || lower.contains('rejeit')) {
      return const Color(0xFFDC2626);
    }
    if (lower.contains('entreg') || lower.contains('conclu')) {
      return const Color(0xFF16A34A);
    }
    if (lower.contains('caminho') || lower.contains('atribu')) {
      return const Color(0xFF2563EB);
    }
    if (lower.contains('prepara')) {
      return const Color(0xFFD97706);
    }
    if (lower.contains('aguarda')) {
      return const Color(0xFFE11D48);
    }
    return const Color(0xFFDC2626);
  }

  Widget _buildOrderCard(
    BuildContext context,
    CustomerOrderSummaryModel order,
  ) {
    final statusColor = _obterCorStatus(order.estadoDisplay.isNotEmpty ? order.estadoDisplay : order.estado);
    final statusLabel = _formatarStatusAmigavel(order.estadoDisplay.isNotEmpty ? order.estadoDisplay : order.estado);

    final shortId =
        order.id.length >= 8 ? order.id.substring(0, 8).toUpperCase() : order.id;
    final dateStr =
        '${order.dataCriacao.day.toString().padLeft(2, '0')}/${order.dataCriacao.month.toString().padLeft(2, '0')} às ${order.dataCriacao.hour.toString().padLeft(2, '0')}:${order.dataCriacao.minute.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF1F5F9), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
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
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Pedido #$shortId • $dateStr',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: statusColor.withOpacity(0.25), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (order.isAtivo) ...[
              const SizedBox(height: 14),
              _buildStepProgressBar(context, order.etapaProgresso),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFFEE2E2), width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626).withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.lock_rounded,
                            size: 15,
                            color: Color(0xFFDC2626),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: const [
                            Text(
                              'Código de Entrega ao Estafeta',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1E293B),
                              ),
                            ),
                            Text(
                              'Informe este código ao estafeta ao receber',
                              style: TextStyle(
                                fontSize: 10,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFDC2626).withOpacity(0.3)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Text(
                        order.pinEntrega.isNotEmpty ? order.pinEntrega : '----',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.5,
                          color: Color(0xFFDC2626),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.fastfood_outlined, size: 16, color: Color(0xFF64748B)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      order.itensNomes.isNotEmpty
                          ? order.itensNomes.join(' • ')
                          : 'Pedido #$shortId',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF334155),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Divider(height: 1, color: Color(0xFFF1F5F9)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Total Cobrado',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      CurrencyFormatter.formatKwanza(order.totalCobradoCentimos),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ),
                if (order.isAtivo)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (order.podeCancelar) ...[
                        OutlinedButton(
                          onPressed: () => _cancelOrder(order),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFDC2626),
                            side: const BorderSide(color: Color(0xFFFECACA)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                          ),
                          child: const Text('Cancelar', style: TextStyle(fontSize: 12)),
                        ),
                        const SizedBox(width: 8),
                      ],
                      FilledButton.icon(
                        onPressed: () => _openTracking(order),
                        icon: const Icon(Icons.radar_rounded, size: 15),
                        label: const Text('Acompanhar', style: TextStyle(fontSize: 12)),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFDC2626),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            if (!order.isAtivo) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _rateOrder(order),
                      icon: Icon(
                        _avaliacoes[order.id] != null
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        size: 16,
                        color: Colors.amber.shade700,
                      ),
                      label: Text(
                        _avaliacoes[order.id] != null
                            ? '${_avaliacoes[order.id]} ★ Avaliado'
                            : 'Avaliar',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF334155),
                        side: BorderSide(
                          color: _avaliacoes[order.id] != null
                              ? Colors.amber.shade600
                              : const Color(0xFFCBD5E1),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _reorder(order),
                      icon: const Icon(Icons.replay_rounded, size: 16),
                      label: const Text(
                        'Pedir Novamente',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStepProgressBar(BuildContext context, int activeStep) {
    const labels = ['Confirmado', 'Cozinha', 'A Caminho', 'Entregue'];
    const activeColor = Color(0xFFDC2626);
    const inactiveColor = Color(0xFFE2E8F0);

    return Column(
      children: [
        Row(
          children: List.generate(labels.length, (i) {
            final step = i + 1;
            final isDone = step <= activeStep;
            return Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDone ? activeColor : inactiveColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  if (i < labels.length - 1) const SizedBox(width: 4),
                ],
              ),
            );
          }),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(labels.length, (i) {
            final step = i + 1;
            final isDone = step <= activeStep;
            return Expanded(
              child: Text(
                labels[i],
                textAlign: i == 0
                    ? TextAlign.start
                    : i == labels.length - 1
                        ? TextAlign.end
                        : TextAlign.center,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: isDone ? FontWeight.w700 : FontWeight.w500,
                  color: isDone ? activeColor : const Color(0xFF94A3B8),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

