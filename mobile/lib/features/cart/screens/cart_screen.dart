import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/auth_bloc.dart';
import '../../auth/storage/secure_token_storage.dart';
import '../../auth/widgets/guest_auth_prompt_sheet.dart';
import '../../catalog/customer_catalog_screens.dart';
import '../../checkout/checkout_screen.dart';
import '../services/cart_service.dart';

/// Ecrã do Carrinho / Sacola de Compras do Cliente (`CartScreen`).
/// Exibe os itens adicionados, permite gerir quantidades e prosseguir para o Checkout.
class CartScreen extends StatelessWidget {
  final VoidCallback? onExploreTap;

  const CartScreen({
    super.key,
    this.onExploreTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AnimatedBuilder(
      animation: CartService.instance,
      builder: (context, _) {
        final cart = CartService.instance;

        return Scaffold(
          appBar: AppBar(
            title: const Text('A Minha Sacola'),
            actions: [
              if (cart.isNotEmpty)
                IconButton(
                  tooltip: 'Esvaziar Sacola',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () => _showClearCartDialog(context),
                ),
            ],
          ),
          body: cart.isEmpty
              ? _buildEmptyState(context)
              : _buildCartContent(context, cart),
          bottomNavigationBar: cart.isNotEmpty
              ? _buildCheckoutBottomBar(context, cart)
              : null,
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withOpacity(0.35),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shopping_bag_outlined,
                size: 72,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'A sua sacola está vazia',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Explore os restaurantes e mercados disponíveis na sua zona para escolher os seus pratos e produtos favoritos.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: onExploreTap ?? () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.restaurant_menu_rounded),
              label: const Text('Explorar Restaurantes'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCartContent(BuildContext context, CartService cart) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        // Cabeçalho da Loja Atual
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colorScheme.surfaceVariant.withOpacity(0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.5)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.storefront_rounded,
                  color: colorScheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pedido em:',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      cart.lojaNome ?? 'Restaurante Parceiro',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Chip(
                label: Text('${cart.totalItemsCount} item(ns)'),
                backgroundColor: colorScheme.primaryContainer.withOpacity(0.5),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        Text(
          'Itens Selecionados',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),

        // Lista de Itens do Carrinho
        ...cart.items.map((item) {
          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      item.imagemUrl,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 64,
                        height: 64,
                        color: colorScheme.surfaceVariant,
                        child: Icon(
                          Icons.fastfood_rounded,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.nome,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (item.opcoesNomes.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Opções: ${item.opcoesNomes.join(', ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (item.notas.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Nota: "${item.notas.trim()}"',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.tertiary,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          CurrencyFormatter.formatKwanza(item.precoUnitarioCentimos),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Seletor de Quantidade (+ / -)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.filledTonal(
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => cart.updateQuantity(item.itemId, -1),
                        icon: const Icon(Icons.remove),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          '${item.quantidade}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton.filledTonal(
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => cart.updateQuantity(item.itemId, 1),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),

        const SizedBox(height: 16),

        // Resumo Estimado
        Card(
          elevation: 0,
          color: colorScheme.surfaceVariant.withOpacity(0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.4)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Subtotal dos produtos', style: theme.textTheme.bodyMedium),
                    Text(
                      CurrencyFormatter.formatKwanza(cart.totalSubtotalCentimos),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Taxa de entrega', style: theme.textTheme.bodySmall),
                    Text('Calculada no checkout', style: theme.textTheme.bodySmall),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total estimado',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      CurrencyFormatter.formatKwanza(cart.totalSubtotalCentimos),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCheckoutBottomBar(BuildContext context, CartService cart) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: FilledButton.icon(
          onPressed: () => _navigateToCheckout(context, cart),
          icon: const Icon(Icons.arrow_forward_rounded),
          label: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Avançar para o Pagamento'),
              Text(
                CurrencyFormatter.formatKwanza(cart.totalSubtotalCentimos),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _navigateToCheckout(BuildContext context, CartService cart) async {
    if (cart.isEmpty || cart.lojaId == null) return;

    // Guarda de Visitante (Guest Mode Checkout Gate):
    // Visitantes navegam livremente e montam a sacola, mas a finalização exige autenticação
    // para definir o endereço de entrega e emitir o código PIN de validação seguro
    final token = await SecureTokenStorage().getAccessToken();
    bool isAuthenticated = token != null && token.isNotEmpty;
    if (!isAuthenticated) {
      try {
        final authState = context.read<AuthBloc>().state;
        if (authState is AuthAuthenticated) {
          isAuthenticated = true;
        }
      } catch (_) {}
    }

    if (!isAuthenticated) {
      if (!context.mounted) return;
      final authSuccess = await GuestAuthPromptSheet.show(
        context,
        lojaNome: cart.lojaNome,
      );

      // Se o utilizador não completou a autenticação, mantém o carrinho preservado e cancela o checkout
      if (authSuccess != true) {
        final recheckToken = await SecureTokenStorage().getAccessToken();
        if (recheckToken == null || recheckToken.isEmpty) return;
      }
    }

    if (!context.mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CheckoutScreen(
          lojaId: cart.lojaId!,
          lojaNome: cart.lojaNome ?? 'Restaurante Parceiro',
          moradaId: cart.moradaId,
          moradaLabel: cart.moradaLabel,
          moradaTexto: cart.moradaTexto,
          itensCarrinho: cart.toCheckoutInputs(),
        ),
      ),
    );
  }

  void _showClearCartDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Esvaziar Sacola?'),
          content: const Text(
            'Tem a certeza que deseja remover todos os itens adicionados à sua sacola?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                CartService.instance.clear();
                Navigator.of(dialogContext).pop();
              },
              child: const Text('Esvaziar'),
            ),
          ],
        );
      },
    );
  }
}

