import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/partner_bloc.dart';
import '../models/partner_models.dart';
import '../widgets/item_editor_form_dialog.dart';

/// Ecrã de Gestão Interna de Catálogo e Menu do Parceiro Comercial (RN-014, RN-015).
///
/// Apresenta:
/// - Estrutura hierárquica por abas verticais para Categorias de Itens (otimizada para Tablet/Portal);
/// - Lista de produtos com miniatura, nome, preço em Kz e tags de alergénios (RN-014);
/// - Switch lateral "Disponível em Stock" com opacidade atenuada imediata e invalidação na API (RN-015);
/// - Ações rápidas de Adicionar, Editar e Remover Produtos.
class MenuManagementScreen extends StatelessWidget {
  const MenuManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocConsumer<PartnerBloc, PartnerState>(
      listener: (context, state) {
        if (state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage!),
              backgroundColor: colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else if (state.successMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.successMessage!),
              backgroundColor: const Color(0xFF2E7D32),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      builder: (context, state) {
        if (state.status == PartnerStatus.loading && state.categories.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final categories = state.categories;
        final selectedCategoryId = state.selectedCategoryId;
        final items = state.filteredItems;

        return Scaffold(
          body: Row(
            children: [
              // 1. ABAS VERTICAIS DE CATEGORIAS (Tablet / Portal Layout - RN-014)
              Container(
                width: 250,
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  border: Border(
                    right: BorderSide(color: colorScheme.outlineVariant, width: 1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Título do Menu Lateral
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Categorias',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline, size: 22),
                            tooltip: 'Criar Nova Categoria',
                            onPressed: () => _exibirDialogoCriarCategoria(context),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // Lista de Categorias Verticais
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          // Opção "Todos os Produtos"
                          _CategoryTabTile(
                            title: 'Todos os Produtos',
                            itemCount: state.items.length,
                            isSelected: selectedCategoryId == null || selectedCategoryId.isEmpty,
                            icon: Icons.all_inbox_rounded,
                            onTap: () {
                              context.read<PartnerBloc>().add(const SelectCategoryRequested(null));
                            },
                          ),

                          // Categorias Cadastradas
                          ...categories.map((cat) {
                            final count = state.items.where((i) => i.categoriaId == cat.id).length;
                            final isSelected = selectedCategoryId == cat.id;

                            return _CategoryTabTile(
                              title: cat.nome,
                              itemCount: count,
                              isSelected: isSelected,
                              icon: Icons.restaurant_menu_rounded,
                              onTap: () {
                                context.read<PartnerBloc>().add(SelectCategoryRequested(cat.id));
                              },
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 2. PAINEL DE CONTEÚDO DOS ITENS DO MENU
              Expanded(
                child: Container(
                  color: colorScheme.surfaceVariant.withOpacity(0.3),
                  child: Column(
                    children: [
                      // Barra Superior da Categoria com Ação de Adicionar
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        color: colorScheme.surface,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getNomeCategoriaSelecionada(state),
                                  style: theme.textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  '${items.length} ${items.length == 1 ? "produto configurado" : "produtos configurados"}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                            FilledButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('Novo Produto'),
                              onPressed: () {
                                ItemEditorFormDialog.show(
                                  context: context,
                                  categories: categories,
                                  initialCategoryId: selectedCategoryId,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),

                      // Lista / Grelha de Cards de Produtos
                      Expanded(
                        child: items.isEmpty
                            ? _buildEmptyState(context, colorScheme, theme, categories, selectedCategoryId)
                            : ListView.separated(
                                padding: const EdgeInsets.all(24),
                                itemCount: items.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 16),
                                itemBuilder: (ctx, index) {
                                  final item = items[index];
                                  return _MenuItemCard(
                                    item: item,
                                    categories: categories,
                                    onToggleAvailability: (novoValor) {
                                      context.read<PartnerBloc>().add(
                                            ToggleItemAvailabilityRequested(
                                              itemId: item.id,
                                              isDisponivel: novoValor,
                                            ),
                                          );
                                    },
                                    onEdit: () {
                                      ItemEditorFormDialog.show(
                                        context: context,
                                        item: item,
                                        categories: categories,
                                        initialCategoryId: item.categoriaId,
                                      );
                                    },
                                    onDelete: () {
                                      _confirmarRemocaoItem(context, item);
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _getNomeCategoriaSelecionada(PartnerState state) {
    if (state.selectedCategoryId == null || state.selectedCategoryId!.isEmpty) {
      return 'Todos os Produtos';
    }
    final cat = state.categories.where((c) => c.id == state.selectedCategoryId);
    if (cat.isNotEmpty) return cat.first.nome;
    return 'Catálogo do Parceiro';
  }

  static Widget _buildEmptyState(
    BuildContext context,
    ColorScheme colorScheme,
    ThemeData theme,
    List<MenuCategory> categories,
    String? selectedCategoryId,
  ) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.restaurant_outlined, size: 64, color: colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            'Nenhum produto cadastrado nesta categoria',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Adiciona pratos e bebidas ao teu menu para começares a vender.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.outline,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.add),
            label: const Text('Adicionar Primeiro Produto'),
            onPressed: () {
              ItemEditorFormDialog.show(
                context: context,
                categories: categories,
                initialCategoryId: selectedCategoryId,
              );
            },
          ),
        ],
      ),
    );
  }

  static void _confirmarRemocaoItem(BuildContext context, MenuItemModel item) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Remover Produto'),
        content: Text('Tens a certeza de que desejas remover "${item.nome}" do teu menu?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () {
              context.read<PartnerBloc>().add(DeleteMenuItemRequested(item.id));
              Navigator.of(dialogCtx).pop();
            },
            child: const Text('Remover'),
          ),
        ],
      ),
    );
  }

  static void _exibirDialogoCriarCategoria(BuildContext context) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Nova Categoria de Menu (RN-014)'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nome da Categoria',
            hintText: 'Ex.: Sobremesas Gourmet',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final nome = controller.text.trim();
              if (nome.isNotEmpty) {
                // Em produção invocaria o evento de criar categoria
                Navigator.of(dialogCtx).pop();
              }
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
  }
}

/// Item de aba vertical de categoria (estilo Navigation Drawer/Rail).
class _CategoryTabTile extends StatelessWidget {
  final String title;
  final int itemCount;
  final bool isSelected;
  final IconData icon;
  final VoidCallback onTap;

  const _CategoryTabTile({
    required this.title,
    required this.itemCount,
    required this.isSelected,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isSelected ? colorScheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Icon(
          icon,
          color: isSelected ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
          size: 22,
        ),
        title: Text(
          title,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? colorScheme.onPrimaryContainer : colorScheme.onSurface,
          ),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: isSelected
                ? colorScheme.primary.withOpacity(0.15)
                : colorScheme.surfaceVariant,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$itemCount',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: isSelected ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}

/// Card de exibição do produto do menu com suporte a atenuação visual quando indisponível (RN-015).
class _MenuItemCard extends StatelessWidget {
  final MenuItemModel item;
  final List<MenuCategory> categories;
  final ValueChanged<bool> onToggleAvailability;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _MenuItemCard({
    required this.item,
    required this.categories,
    required this.onToggleAvailability,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDisponivel = item.isDisponivel;

    // Quando indisponível, atenua visualmente a opacidade do card para acinzentado (RN-015)
    return AnimatedOpacity(
      opacity: isDisponivel ? 1.0 : 0.55,
      duration: const Duration(milliseconds: 250),
      child: Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDisponivel ? colorScheme.outlineVariant : const Color(0xFFE0E0E0),
            width: 1,
          ),
          boxShadow: isDisponivel
              ? [
                  BoxShadow(
                    color: colorScheme.shadow.withOpacity(0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Miniatura da Imagem do Produto
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 100,
                  height: 100,
                  color: colorScheme.surfaceVariant,
                  child: item.imagemUrl != null && item.imagemUrl!.isNotEmpty
                      ? ColorFiltered(
                          colorFilter: isDisponivel
                              ? const ColorFilter.mode(Colors.transparent, BlendMode.multiply)
                              : const ColorFilter.mode(Colors.grey, BlendMode.saturation),
                          child: Image.network(
                            item.imagemUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Icon(Icons.broken_image, size: 32),
                            ),
                          ),
                        )
                      : const Center(
                          child: Icon(Icons.fastfood, size: 36, color: Colors.grey),
                        ),
                ),
              ),
              const SizedBox(width: 16),

              // 2. Detalhes: Nome, Preço, Descrição e Tags de Alergénios (RN-014)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.nome,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              decoration: isDisponivel ? null : TextDecoration.lineThrough,
                            ),
                          ),
                        ),
                        // Preço formatado em unidades inteiras de Kwanza (RN-016, RN-059)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            CurrencyFormatter.formatKwanza(item.preco),
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (item.descricao.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        item.descricao,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],

                    // Tags Visuais de Alergénios Declarados (RN-014)
                    if (item.alergenos.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: item.alergenos.map((alergenoId) {
                          final allergen = AllergenType.fromId(alergenoId);
                          final label = allergen?.label ?? alergenoId;
                          final color = allergen?.color ?? const Color(0xFF6C757D);

                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: color.withOpacity(0.4)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(allergen?.icon ?? Icons.warning_amber, size: 12, color: color),
                                const SizedBox(width: 4),
                                Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: color,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 16),

              // 3. Switch Lateral "Disponível em Stock" + Botões de Ação (RN-015)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isDisponivel ? 'Disponível em Stock' : 'Indisponível (RN-015)',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: isDisponivel ? const Color(0xFF2E7D32) : const Color(0xFFC62828),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Switch.adaptive(
                        value: isDisponivel,
                        activeColor: const Color(0xFF2E7D32),
                        onChanged: onToggleAvailability,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton.outlined(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: 'Editar Produto',
                        onPressed: onEdit,
                      ),
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        icon: Icon(Icons.delete_outline, size: 18, color: colorScheme.error),
                        tooltip: 'Remover Produto',
                        onPressed: onDelete,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

