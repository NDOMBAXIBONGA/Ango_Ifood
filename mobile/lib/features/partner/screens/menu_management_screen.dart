import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/partner_bloc.dart';
import '../models/partner_models.dart';
import '../widgets/item_editor_form_dialog.dart';

/// Ecrã de Gestão de Catálogo e Menu do Parceiro Comercial (RN-014, RN-015).
///
/// Arquitetura UX/UI Mobile-First:
/// - Seletor horizontal de categorias com chips fluidos e contadores de itens;
/// - Barra de pesquisa rápida e filtros de disponibilidade (Todos / Disponíveis / Esgotados);
/// - Cartões de produto detalhados com imagem, preço formatado em Kwanzas (Kz),
///   tags de alergénios com cores normalizadas e comutador instantâneo de stock;
/// - Botão flutuante (FAB) moderno para criação rápida de novos produtos;
/// - Diálogo intuitivo para gestão e criação de novas categorias.
class MenuManagementScreen extends StatefulWidget {
  const MenuManagementScreen({super.key});

  @override
  State<MenuManagementScreen> createState() => _MenuManagementScreenState();
}

class _MenuManagementScreenState extends State<MenuManagementScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  _StockFilter _stockFilter = _StockFilter.todos;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
              backgroundColor: const Color(0xFF16A34A),
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

        // Aplica filtragem por categoria, pesquisa textual e disponibilidade de stock
        final itemsFiltrados = state.filteredItems.where((item) {
          // Filtro por termo de pesquisa
          if (_searchQuery.isNotEmpty) {
            final query = _searchQuery.toLowerCase();
            final matchNome = item.nome.toLowerCase().contains(query);
            final matchDesc = item.descricao.toLowerCase().contains(query);
            if (!matchNome && !matchDesc) return false;
          }

          // Filtro por estado de stock
          if (_stockFilter == _StockFilter.disponiveis && !item.isDisponivel) {
            return false;
          }
          if (_stockFilter == _StockFilter.esgotados && item.isDisponivel) {
            return false;
          }

          return true;
        }).toList();

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          body: Column(
            children: [
              // 1. Barra de Pesquisa e Filtros Rápidos
              Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  children: [
                    // Campo de Busca Moderno
                    Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: TextField(
                        controller: _searchController,
                        onChanged: (val) {
                          setState(() {
                            _searchQuery = val.trim();
                          });
                        },
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Pesquisar prato, bebida ou ingrediente...',
                          hintStyle: TextStyle(
                            fontSize: 13.5,
                            color: Colors.grey.shade500,
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: Colors.grey.shade600,
                          ),
                          suffixIcon: _searchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchQuery = '';
                                    });
                                  },
                                )
                              : null,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Linha de Filtro de Stock (Todos / Disponíveis / Esgotados)
                    Row(
                      children: [
                        _buildStockFilterChip('Todos', _StockFilter.todos),
                        const SizedBox(width: 8),
                        _buildStockFilterChip('Disponíveis', _StockFilter.disponiveis,
                            dotColor: const Color(0xFF16A34A)),
                        const SizedBox(width: 8),
                        _buildStockFilterChip('Esgotados', _StockFilter.esgotados,
                            dotColor: const Color(0xFFEA580C)),
                        const Spacer(),
                        Text(
                          '${itemsFiltrados.length} ${itemsFiltrados.length == 1 ? "artigo" : "artigos"}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // 2. Barra Horizontal Deslizante de Categorias (Chips)
              Container(
                height: 52,
                color: Colors.white,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  children: [
                    // Chip "Todos os Artigos"
                    _buildCategoryPill(
                      title: 'Todos',
                      count: state.items.length,
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

                      return _buildCategoryPill(
                        title: cat.nome,
                        count: count,
                        isSelected: isSelected,
                        icon: Icons.restaurant_menu_rounded,
                        onTap: () {
                          context.read<PartnerBloc>().add(SelectCategoryRequested(cat.id));
                        },
                      );
                    }),

                    // Botão "+ Nova Categoria"
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: ActionChip(
                        avatar: const Icon(Icons.add, size: 16, color: Color(0xFF1E88E5)),
                        label: const Text(
                          'Nova Categoria',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E88E5),
                          ),
                        ),
                        backgroundColor: const Color(0xFFEFF6FF),
                        side: const BorderSide(color: Color(0xFFBFDBFE)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        onPressed: () => _exibirDialogoCriarCategoria(context),
                      ),
                    ),
                  ],
                ),
              ),

              const Divider(height: 1, thickness: 1, color: Color(0xFFE2E8F0)),

              // 3. Lista de Produtos Mobile-First (Sem Overflow)
              Expanded(
                child: itemsFiltrados.isEmpty
                    ? _buildEmptyState(context, categories, selectedCategoryId)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 88),
                        itemCount: itemsFiltrados.length,
                        itemBuilder: (ctx, index) {
                          final item = itemsFiltrados[index];
                          return _ProductCard(
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

          // Botão Flutuante de Ação Rápida: Novo Produto
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () {
              ItemEditorFormDialog.show(
                context: context,
                categories: categories,
                initialCategoryId: selectedCategoryId,
              );
            },
            backgroundColor: const Color(0xFF1E88E5),
            foregroundColor: Colors.white,
            elevation: 3,
            icon: const Icon(Icons.add_rounded, size: 22),
            label: const Text(
              'Novo Artigo',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStockFilterChip(String label, _StockFilter filter, {Color? dotColor}) {
    final isSelected = _stockFilter == filter;
    return GestureDetector(
      onTap: () {
        setState(() {
          _stockFilter = filter;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : const Color(0xFF475569),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryPill({
    required String title,
    required int count,
    required bool isSelected,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF1E88E5) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? const Color(0xFF1E88E5) : const Color(0xFFE2E8F0),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: isSelected ? Colors.white : const Color(0xFF64748B),
                ),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                    color: isSelected ? Colors.white : const Color(0xFF334155),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.white.withOpacity(0.25)
                        : const Color(0xFFCBD5E1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? Colors.white : const Color(0xFF1E293B),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context,
    List<MenuCategory> categories,
    String? selectedCategoryId,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Icon(
                Icons.restaurant_rounded,
                size: 38,
                color: Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Nenhum artigo encontrado',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Nenhum resultado corresponde à sua pesquisa "$_searchQuery".'
                  : 'Comece a construir o catálogo do restaurante adicionando pratos ou bebidas.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13.5,
                color: Color(0xFF64748B),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                ItemEditorFormDialog.show(
                  context: context,
                  categories: categories,
                  initialCategoryId: selectedCategoryId,
                );
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1E88E5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Adicionar Primeiro Artigo'),
            ),
          ],
        ),
      ),
    );
  }

  void _exibirDialogoCriarCategoria(BuildContext context) {
    final textController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Nova Categoria', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Indique o nome da categoria para organizar o cardápio (ex.: Hambúrgueres, Bebidas, Sobremesas).',
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: textController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Nome da Categoria',
                  hintText: 'Ex.: Entradas Especiais',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1E88E5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                final nome = textController.text.trim();
                if (nome.isNotEmpty) {
                  context.read<PartnerBloc>().add(CreateCategoryRequested(nome));
                  Navigator.of(ctx).pop();
                }
              },
              child: const Text('Criar Categoria'),
            ),
          ],
        );
      },
    );
  }

  void _confirmarRemocaoItem(BuildContext context, MenuItemModel item) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Remover Artigo?', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Text(
            'Tem a certeza que deseja eliminar "${item.nome}" do menu? Esta ação não pode ser desfeita.',
            style: const TextStyle(fontSize: 13.5, color: Color(0xFF475569)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () {
                Navigator.of(ctx).pop();
                context.read<PartnerBloc>().add(DeleteMenuItemRequested(item.id));
              },
              child: const Text('Sim, Eliminar'),
            ),
          ],
        );
      },
    );
  }
}

enum _StockFilter { todos, disponiveis, esgotados }

/// Cartão de Produto Otimizado para Ecrãs Móveis (Mobile-First)
class _ProductCard extends StatelessWidget {
  final MenuItemModel item;
  final List<MenuCategory> categories;
  final ValueChanged<bool> onToggleAvailability;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ProductCard({
    required this.item,
    required this.categories,
    required this.onToggleAvailability,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDisponivel = item.isDisponivel;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: isDisponivel ? 1.0 : 0.65,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDisponivel ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Miniatura da Foto com Tag "Esgotado"
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 78,
                      height: 78,
                      color: const Color(0xFFF1F5F9),
                      child: (item.imagemUrl != null && item.imagemUrl!.isNotEmpty)
                          ? Image.network(
                              item.imagemUrl!,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _buildPlaceholderIcon(),
                            )
                          : _buildPlaceholderIcon(),
                    ),
                  ),
                  if (!isDisponivel)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: Text(
                            'ESGOTADO',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),

              // Informações Textuais (Nome, Preço em Kz, Alergénios)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.nome,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.descricao.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.descricao,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),

                    // Preço Formatado em Kwanzas (RN-059)
                    Text(
                      CurrencyFormatter.formatKwanza(item.preco),
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1E88E5),
                      ),
                    ),

                    // Alergénios Declarados (RN-014)
                    if (item.allergenTypes.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: item.allergenTypes.take(3).map((alerg) {
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: alerg.color.withOpacity(0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(alerg.icon, size: 10, color: alerg.color),
                                const SizedBox(width: 3),
                                Text(
                                  alerg.label,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: alerg.color,
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

              // Comutador de Stock & Menu de Ações
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Switch.adaptive(
                    value: isDisponivel,
                    activeColor: const Color(0xFF16A34A),
                    onChanged: onToggleAvailability,
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert_rounded, size: 20, color: Colors.grey.shade600),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onSelected: (val) {
                      if (val == 'edit') onEdit();
                      if (val == 'delete') onDelete();
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit_outlined, size: 18),
                            SizedBox(width: 8),
                            Text('Editar Artigo'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red),
                            SizedBox(width: 8),
                            Text('Eliminar', style: TextStyle(color: Colors.red)),
                          ],
                        ),
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

  Widget _buildPlaceholderIcon() {
    return const Center(
      child: Icon(
        Icons.fastfood_rounded,
        size: 32,
        color: Color(0xFFCBD5E1),
      ),
    );
  }
}
