import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/network/app_environment_config.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/widgets/ango_network_image.dart';
import '../../auth/storage/secure_token_storage.dart';
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
  late bool _isDestaque;
  bool _isEditing = false;
  bool _isUploadingImage = false;

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
      _categoriaSelecionadaId = 'geral';
    }

    _alergenosSelecionados = Set<String>.from(widget.item?.alergenos ?? []);
    _isDisponivel = widget.item?.isDisponivel ?? true;
    _isDestaque = widget.item?.isDestaque ?? false;
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

  Future<void> _pickImageFromGallery() async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (pickedFile == null) return;

      setState(() {
        _isUploadingImage = true;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
                SizedBox(width: 12),
                Text('A carregar imagem da galeria para o catálogo...'),
              ],
            ),
            duration: Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }

      final tokenStorage = const SecureTokenStorage();
      final dio = await createSecureDioClient(tokenStorage: tokenStorage);
      final partnerState = context.read<PartnerBloc>().state;
      final lojaId = partnerState.storeProfile?.id ?? '';

      final formData = FormData.fromMap({
        'arquivo': await MultipartFile.fromFile(
          pickedFile.path,
          filename: pickedFile.name,
        ),
      });

      final resp = await dio.post<Map<String, dynamic>>(
        '/api/v1/partner/store/upload/',
        data: formData,
        options: Options(
          headers: {
            if (lojaId.isNotEmpty) 'X-Store-ID': lojaId,
          },
        ),
      );

      if (resp.data != null && resp.data!['url'] != null) {
        final url = resp.data!['url'].toString();
        setState(() {
          _imagemUrlController.text = url;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Fotografia carregada com sucesso!'),
              backgroundColor: Color(0xFF16A34A),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao enviar imagem: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingImage = false;
        });
      }
    }
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final precoInteiro = int.tryParse(_precoController.text.trim()) ?? 0;

    final catObj = widget.categories
        .where((c) => c.id == _categoriaSelecionadaId)
        .firstOrNull;
    final catNome = catObj?.nome ?? '';

    final novoItem = MenuItemModel(
      id: widget.item?.id ?? 'item-${DateTime.now().millisecondsSinceEpoch}',
      categoriaId: _categoriaSelecionadaId.isEmpty ? 'geral' : _categoriaSelecionadaId,
      categoriaNome: catNome,
      nome: _nomeController.text.trim(),
      descricao: _descricaoController.text.trim(),
      preco: precoInteiro,
      imagemUrl: _imagemUrlController.text.trim(),
      alergenos: _alergenosSelecionados.toList(),
      isDisponivel: _isDisponivel,
      isDestaque: _isDestaque,
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
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 850),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cabeçalho do Diálogo
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
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
                          Expanded(
                            child: Text(
                              _isEditing ? 'Editar Produto do Menu' : 'Novo Produto do Menu',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 14),

                // Corpo do Formulário com Scroll
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. Fotografia do Produto (Upload / Captura / URL)
                        Text(
                          'Fotografia do Produto',
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
                                color: colorScheme.surfaceContainerHighest,
                                child: _imagemUrlController.text.isNotEmpty
                                    ? AngoNetworkImage(
                                        imageUrl: _imagemUrlController.text,
                                        width: 90,
                                        height: 90,
                                        fit: BoxFit.cover,
                                        fallbackIcon: Icons.fastfood,
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
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      OutlinedButton.icon(
                                        style: OutlinedButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          side: const BorderSide(color: Color(0xFF1E88E5)),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        ),
                                        icon: _isUploadingImage
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              )
                                            : const Icon(Icons.photo_library_rounded, size: 16, color: Color(0xFF1E88E5)),
                                        label: Text(
                                          _isUploadingImage ? 'A carregar...' : 'Escolher da Galeria',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1E88E5)),
                                        ),
                                        onPressed: _isUploadingImage ? null : _pickImageFromGallery,
                                      ),
                                      ActionChip(
                                        label: const Text('Exemplo Hambúrguer', style: TextStyle(fontSize: 11)),
                                        onPressed: () => _onPickSampleImage(
                                          'https://images.unsplash.com/photo-1568901346375-23c9450c58cd?w=400',
                                        ),
                                      ),
                                      ActionChip(
                                        label: const Text('Exemplo Bebida', style: TextStyle(fontSize: 11)),
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
                        const SizedBox(height: 18),

                        // 2. Dados Gerais: Nome e Categoria (Em formato vertical responsivo)
                        TextFormField(
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
                            if (val.trim().length < 2) {
                              return 'O nome deve ter no mínimo 2 caracteres.';
                            }
                            if (val.trim().length > 100) {
                              return 'O nome não pode exceder 100 caracteres.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),

                        Builder(
                          builder: (context) {
                            final dropdownItems = widget.categories.isNotEmpty
                                ? widget.categories
                                    .map(
                                      (cat) => DropdownMenuItem<String>(
                                        value: cat.id,
                                        child: Text(cat.nome),
                                      ),
                                    )
                                    .toList()
                                : const [
                                    DropdownMenuItem<String>(
                                      value: 'geral',
                                      child: Text('Cardápio Principal'),
                                    ),
                                  ];
                            final validIds =
                                dropdownItems.map((e) => e.value).toSet();
                            final currentValue =
                                validIds.contains(_categoriaSelecionadaId)
                                    ? _categoriaSelecionadaId
                                    : dropdownItems.first.value;

                            return DropdownButtonFormField<String>(
                              value: currentValue,
                              decoration: const InputDecoration(
                                labelText: 'Categoria *',
                                prefixIcon: Icon(Icons.category),
                                border: OutlineInputBorder(),
                              ),
                              items: dropdownItems,
                              onChanged: (novoId) {
                                if (novoId != null) {
                                  setState(() {
                                    _categoriaSelecionadaId = novoId;
                                  });
                                }
                              },
                            );
                          },
                        ),
                        const SizedBox(height: 14),

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
                        const SizedBox(height: 14),

                        // 4. Preço e Disponibilidade Imediata (Vertical)
                        TextFormField(
                          controller: _precoController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Preço Final de Venda *',
                            suffixText: 'Kz',
                            prefixIcon: Icon(Icons.payments_outlined),
                            helperText: 'Valor em Kwanzas inteiros (Kz)',
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
                        const SizedBox(height: 14),

                        // Switch de Disponibilidade de Stock
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                                    const SizedBox(height: 2),
                                    Text(
                                      _isDisponivel ? 'Visível aos clientes para encomenda imediata' : 'Oculto / Esgotado temporariamente',
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
                        const SizedBox(height: 14),

                        // Switch de Destaque na Página Inicial (100% Automático)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: _isDestaque ? const Color(0xFFFEF9C3) : Colors.transparent,
                            border: Border.all(
                              color: _isDestaque ? const Color(0xFFEAB308) : colorScheme.outlineVariant,
                              width: _isDestaque ? 1.5 : 1.0,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _isDestaque ? Icons.star_rounded : Icons.star_border_rounded,
                                color: _isDestaque ? const Color(0xFFCA8A04) : Colors.grey,
                                size: 26,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Pratos Principais em Destaque',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: Color(0xFF0F172A),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _isDestaque
                                          ? 'Exibido em destaque na Página Inicial da vitrine'
                                          : 'Artigo listado apenas no cardápio normal',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _isDestaque ? const Color(0xFF854D0E) : Colors.grey.shade600,
                                        fontWeight: _isDestaque ? FontWeight.w600 : FontWeight.normal,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch.adaptive(
                                value: _isDestaque,
                                activeColor: const Color(0xFFEAB308),
                                onChanged: (novo) => setState(() => _isDestaque = novo),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),

                        // 5. Grid de Chips Selecionáveis para Alergénios
                        Text(
                          'Declaração de Alergénios',
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
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF16A34A),
                              foregroundColor: Colors.white,
                              minimumSize: const Size(80, 50),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            icon: const Icon(Icons.check_circle_rounded, size: 20),
                            label: Text(
                              _isEditing
                                  ? 'Guardar Alterações do Produto'
                                  : 'Criar Produto no Cardápio',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            onPressed: _submit,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 12),

                // Rodapé Fixo de Ações (Sempre visível com larguras definidas)
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(64, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text(
                            'Cancelar',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 3,
                      child: SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1E88E5),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(80, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.add_task_rounded, size: 18),
                          label: Text(
                            _isEditing ? 'Atualizar' : 'Criar Produto',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          onPressed: _submit,
                        ),
                      ),
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
              leading: const Icon(Icons.photo_library, color: Color(0xFF1E88E5)),
              title: const Text('Escolher da Galeria do Dispositivo'),
              subtitle: const Text('Carregar ficheiro real a partir do telemóvel'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                _pickImageFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }
}

