import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/partner_bloc.dart';
import '../models/partner_models.dart';

/// Formulário modal completo para criação e edição de produtos do menu (RN-014, RN-016).
///
/// Contém:
/// - Campos de texto com validações estritas (Nome, Descrição, Preço sem letras/negativos);
/// - Seletor de Categoria;
/// - Grid de `FilterChip` para declaração visual de alergénios (RN-014);
/// - Botão e pré-visualização de fotografia do produto;
/// - Submissão integrada com `PartnerBloc`.
class ItemEditorFormDialog extends StatefulWidget {
  final MenuItemModel? item;
  final List<MenuCategory> categories;
  final String? initialCategoryId;

  const ItemEditorFormDialog({
    super.key,
    this.item,
    required this.categories,
    this.initialCategoryId,
  });

  static Future<void> show({
    required BuildContext context,
    MenuItemModel? item,
    required List<MenuCategory> categories,
    String? initialCategoryId,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BlocProvider.value(
        value: context.read<PartnerBloc>(),
        child: ItemEditorFormDialog(
          item: item,
          categories: categories,
          initialCategoryId: initialCategoryId,
        ),
      ),
    );
  }

  @override
  State<ItemEditorFormDialog> createState() => _ItemEditorFormDialogState();
}

class _ItemEditorFormDialogState extends State<ItemEditorFormDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nomeController;
  late final TextEditingController _descricaoController;
  late final TextEditingController _precoController;
  late final TextEditingController _imagemUrlController;

  late String _categoriaSelecionadaId;
  late Set<String> _alergenosSelecionados;
  late bool _isDisponivel;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.item != null;

    _nomeController = TextEditingController(text: widget.item?.nome ?? '');
    _descricaoController = TextEditingController(text: widget.item?.descricao ?? '');
    _precoController = TextEditingController(
      text: widget.item != null ? widget.item!.preco.toString() : '',
    );
    _imagemUrlController = TextEditingController(text: widget.item?.imagemUrl ?? '');

    if (widget.item != null && widget.item!.categoriaId.isNotEmpty) {
      _categoriaSelecionadaId = widget.item!.categoriaId;
    } else if (widget.initialCategoryId != null && widget.initialCategoryId!.isNotEmpty) {
      _categoriaSelecionadaId = widget.initialCategoryId!;
    } else if (widget.categories.isNotEmpty) {
      _categoriaSelecionadaId = widget.categories.first.id;
    } else {
      _categoriaSelecionadaId = '';
    }

    _alergenosSelecionados = Set<String>.from(widget.item?.alergenos ?? []);
    _isDisponivel = widget.item?.isDisponivel ?? true;
  }

  @override
  void dispose() {
    _nomeController.dispose();
    _descricaoController.dispose();
    _precoController.dispose();
    _imagemUrlController.dispose();
    super.dispose();
  }

  void _onPickSampleImage(String url) {
    setState(() {
      _imagemUrlController.text = url;
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final precoInteiro = int.tryParse(_precoController.text.trim()) ?? 0;

    final novoItem = MenuItemModel(
      id: widget.item?.id ?? 'item-${DateTime.now().millisecondsSinceEpoch}',
      categoriaId: _categoriaSelecionadaId,
      nome: _nomeController.text.trim(),
      descricao: _descricaoController.text.trim(),
      preco: precoInteiro,
      imagemUrl: _imagemUrlController.text.trim().isNotEmpty
          ? _imagemUrlController.text.trim()
          : 'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400',
      alergenos: _alergenosSelecionados.toList(),
      isDisponivel: _isDisponivel,
    );

    context.read<PartnerBloc>().add(
          SaveMenuItemRequested(
            item: novoItem,
            isEditing: _isEditing,
          ),
        );

    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 850),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cabeçalho do Diálogo
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _isEditing ? Icons.edit_note_rounded : Icons.add_circle_outline_rounded,
                            color: colorScheme.onPrimaryContainer,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Text(
                          _isEditing ? 'Editar Produto do Menu' : 'Novo Produto do Menu',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Corpo do Formulário com Scroll
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. Fotografia do Produto (Upload / Captura / URL)
                        Text(
                          'Fotografia do Produto (RN-014)',
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Preview da imagem
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Container(
                                width: 90,
                                height: 90,
                                color: colorScheme.surfaceVariant,
                                child: _imagemUrlController.text.isNotEmpty
                                    ? Image.network(
                                        _imagemUrlController.text,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => const Center(
                                          child: Icon(Icons.broken_image, size: 32),
                                        ),
                                      )
                                    : const Center(
                                        child: Icon(Icons.fastfood, size: 36, color: Colors.grey),
                                      ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextFormField(
                                    controller: _imagemUrlController,
                                    decoration: InputDecoration(
                                      labelText: 'URL da Imagem / CDN',
                                      hintText: 'https://cdn.delivery.local/imagem.jpg',
                                      prefixIcon: const Icon(Icons.link),
                                      suffixIcon: IconButton(
                                        icon: const Icon(Icons.camera_alt),
                                        tooltip: 'Capturar ou escolher imagem',
                                        onPressed: () => _exibirOpcoesImagem(context),
                                      ),
                                      border: const OutlineInputBorder(),
                                    ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      ActionChip(
                                        label: const Text('Exemplo Hambúrguer'),
                                        onPressed: () => _onPickSampleImage(
                                          'https://images.unsplash.com/photo-1568901346375-23c9450c58cd?w=400',
                                        ),
                                      ),
                                      ActionChip(
                                        label: const Text('Exemplo Bebida'),
                                        onPressed: () => _onPickSampleImage(
                                          'https://images.unsplash.com/photo-1551024709-8f23befc6f87?w=400',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // 2. Dados Gerais: Nome e Categoria
                        Row(
                          children: [
                            // Nome do Produto
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: _nomeController,
                                decoration: const InputDecoration(
                                  labelText: 'Nome do Produto *',
                                  hintText: 'Ex.: Hambúrguer Duplo Artesanal',
                                  prefixIcon: Icon(Icons.restaurant_menu),
                                  border: OutlineInputBorder(),
                                ),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) {
                                    return 'O nome do produto é obrigatório.';
                                  }
                                  if (val.trim().length < 3) {
                                    return 'O nome deve ter no mínimo 3 caracteres.';
                                  }
                                  if (val.trim().length > 100) {
                                    return 'O nome não pode exceder 100 caracteres.';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 14),

                            // Categoria
                            Expanded(
                              flex: 2,
                              child: DropdownButtonFormField<String>(
                                value: _categoriaSelecionadaId.isNotEmpty
                                    ? _categoriaSelecionadaId
                                    : null,
                                decoration: const InputDecoration(
                                  labelText: 'Categoria *',
                                  prefixIcon: Icon(Icons.category),
                                  border: OutlineInputBorder(),
                                ),
                                items: widget.categories.map((cat) {
                                  return DropdownMenuItem<String>(
                                    value: cat.id,
                                    child: Text(cat.nome),
                                  );
                                }).toList(),
                                onChanged: (novoId) {
                                  if (novoId != null) {
                                    setState(() {
                                      _categoriaSelecionadaId = novoId;
                                    });
                                  }
                                },
                                validator: (val) {
                                  if (val == null || val.isEmpty) {
                                    return 'Selecione uma categoria.';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // 3. Descrição Detalhada
                        TextFormField(
                          controller: _descricaoController,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: 'Descrição e Ingredientes',
                            hintText: 'Descreve os ingredientes, gramagem e acompanhamentos incluídos...',
                            alignLabelWithHint: true,
                            prefixIcon: Icon(Icons.description_outlined),
                            border: OutlineInputBorder(),
                          ),
                          maxLength: 500,
                        ),
                        const SizedBox(height: 16),

                        // 4. Preço e Disponibilidade Imediata
                        Row(
                          children: [
                            // Preço com máscara anti-letras e não negativos (RN-016, RN-059)
                            Expanded(
                              child: TextFormField(
                                controller: _precoController,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                decoration: const InputDecoration(
                                  labelText: 'Preço Final de Venda *',
                                  suffixText: 'Kz',
                                  prefixIcon: Icon(Icons.payments_outlined),
                                  helperText: 'Valor em Kwanzas inteiros (RN-016 / RN-059)',
                                  border: OutlineInputBorder(),
                                ),
                                validator: (val) {
                                  if (val == null || val.trim().isEmpty) {
                                    return 'O preço é obrigatório.';
                                  }
                                  final n = int.tryParse(val.trim());
                                  if (n == null || n <= 0) {
                                    return 'Insira um valor positivo superior a 0 Kz.';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 16),

                            // Switch de Disponibilidade de Stock (RN-015)
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  border: Border.all(color: colorScheme.outlineVariant),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Disponível em Stock',
                                            style: theme.textTheme.bodyMedium?.copyWith(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            _isDisponivel ? 'Visível aos clientes' : 'Oculto / Esgotado',
                                            style: theme.textTheme.bodySmall?.copyWith(
                                              color: _isDisponivel
                                                  ? const Color(0xFF2E7D32)
                                                  : const Color(0xFFC62828),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Switch.adaptive(
                                      value: _isDisponivel,
                                      activeColor: const Color(0xFF2E7D32),
                                      onChanged: (novo) => setState(() => _isDisponivel = novo),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),

                        // 5. Grid de Chips Selecionáveis para Alergénios (RN-014)
                        Text(
                          'Declaração Obrigatória de Alergénios (RN-014)',
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Seleciona todos os alergénios presentes na receita ou potenciais contaminações cruzadas:',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),

                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: AllergenType.values.map((allergen) {
                            final isSelected = _alergenosSelecionados.contains(allergen.id);
                            return FilterChip(
                              avatar: Icon(
                                allergen.icon,
                                size: 18,
                                color: isSelected ? Colors.white : allergen.color,
                              ),
                              label: Text(allergen.label),
                              selected: isSelected,
                              selectedColor: allergen.color,
                              checkmarkColor: Colors.white,
                              labelStyle: TextStyle(
                                color: isSelected ? Colors.white : colorScheme.onSurface,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              ),
                              onSelected: (selecionado) {
                                setState(() {
                                  if (selecionado) {
                                    _alergenosSelecionados.add(allergen.id);
                                  } else {
                                    _alergenosSelecionados.remove(allergen.id);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),

                // Rodapé de Ações
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancelar'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(_isEditing ? 'Atualizar Produto' : 'Adicionar ao Catálogo'),
                      onPressed: _submit,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _exibirOpcoesImagem(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Tirar Fotografia com a Câmara'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                // Simula atribuição de foto capturada em ambiente de produção
                _onPickSampleImage(
                  'https://images.unsplash.com/photo-1550547660-d9450f859349?w=400',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Escolher da Galeria do Dispositivo'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _onPickSampleImage(
                  'https://images.unsplash.com/photo-1565299624946-b28f40a0ae38?w=400',
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

