/// Interface de Utilizador (UI) e Gestão de Estado (`flutter_bloc` + `dio`) da App do Cliente
/// para Descoberta de Lojas (`HomeScreen`) e Navegação no Menu (`StoreMenuScreen`).
///
/// Implementa rigorosamente a Secção 6.3 e as Regras de Negócio:
/// - RN-014: Categorias, itens, descrição, preço, imagem, alergénios e grupos de opções.
/// - RN-015: Itens com `isDisponivel == false` aparecem a cinzento (desaturados) e bloqueiam
///   qualquer clique/adição ao carrinho.
/// - RN-025 / RN-026: Lojas filtradas pela morada geolocalizada (`lat`, `lng`), com badge de
///   "Fechada" e indicação do próximo horário de abertura.
/// - RN-027 / RN-028 / RN-029: Ordenação, etiqueta "Patrocinado", ETA estimada, taxa de entrega e
///   filtros interativos (Tipo de Cozinha, Avaliação >= 4.5, Entrega Grátis).

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// ============================================================================
// 1. MODELOS DE DADOS DO CATÁLOGO E DESCOBERTA (RN-014, RN-015, RN-025 a RN-029)
// ============================================================================

/// Representa a morada atual geolocalizada do Cliente (RN-005, RN-025).
@immutable
class CustomerGeoAddress extends Equatable {
  final String label;
  final String fullAddress;
  final double latitude;
  final double longitude;

  const CustomerGeoAddress({
    required this.label,
    required this.fullAddress,
    required this.latitude,
    required this.longitude,
  });

  @override
  List<Object?> get props => [label, fullAddress, latitude, longitude];
}

/// Representa uma Loja retornada pelo `StoreDiscoveryViewSet` (`/api/v1/catalog/stores/`).
@immutable
class StoreSummaryModel extends Equatable {
  final String id;
  final String nome;
  final String moradaTexto;
  final String imagemUrl;
  final double scoreReputacao;
  final bool isAberta;
  final String? proximoHorarioAbertura;
  final bool isPatrocinado;
  final String? etiquetaPatrocinado;
  final int etaMinutosEstimado;
  final double distanciaKm;
  final int taxaEntregaCentimos;
  final String tipoCozinha;

  const StoreSummaryModel({
    required this.id,
    required this.nome,
    required this.moradaTexto,
    required this.imagemUrl,
    required this.scoreReputacao,
    required this.isAberta,
    this.proximoHorarioAbertura,
    required this.isPatrocinado,
    this.etiquetaPatrocinado,
    required this.etaMinutosEstimado,
    required this.distanciaKm,
    required this.taxaEntregaCentimos,
    required this.tipoCozinha,
  });

  bool get isEntregaGratis => taxaEntregaCentimos == 0;

  factory StoreSummaryModel.fromJson(Map<String, dynamic> json) {
    final scoreRaw = json['score_reputacao'];
    final parsedScore = scoreRaw is num
        ? scoreRaw.toDouble()
        : double.tryParse('$scoreRaw') ?? 5.0;

    return StoreSummaryModel(
      id: json['id'] as String,
      nome: (json['nome'] as String?) ?? 'Loja Parceira',
      moradaTexto: (json['morada_texto'] as String?) ?? '',
      imagemUrl: (json['imagem_url'] as String?) ??
          'https://images.unsplash.com/photo-1504674900247-0877df9cc836?w=800',
      scoreReputacao: parsedScore,
      isAberta: (json['is_aberta'] as bool?) ?? true,
      proximoHorarioAbertura: json['proximo_horario_abertura'] as String?,
      isPatrocinado: (json['is_patrocinado'] as bool?) ?? false,
      etiquetaPatrocinado: json['etiqueta_patrocinado'] as String?,
      etaMinutosEstimado: (json['eta_minutos_estimado'] as num?)?.toInt() ?? 30,
      distanciaKm: (json['distancia_km'] as num?)?.toDouble() ?? 1.2,
      taxaEntregaCentimos: (json['taxa_entrega'] as num?)?.toInt() ?? 50000,
      tipoCozinha: (json['tipo_cozinha'] as String?) ?? 'Restaurante',
    );
  }

  @override
  List<Object?> get props => [
        id,
        nome,
        moradaTexto,
        imagemUrl,
        scoreReputacao,
        isAberta,
        proximoHorarioAbertura,
        isPatrocinado,
        etiquetaPatrocinado,
        etaMinutosEstimado,
        distanciaKm,
        taxaEntregaCentimos,
        tipoCozinha,
      ];
}

/// Representa uma opção individual (`OpcaoItem`) dentro de um `GrupoOpcao` (RN-014).
@immutable
class MenuOptionItemModel extends Equatable {
  final String id;
  final String nome;
  final int precoAdicional;
  final bool isDisponivel;

  const MenuOptionItemModel({
    required this.id,
    required this.nome,
    required this.precoAdicional,
    required this.isDisponivel,
  });

  factory MenuOptionItemModel.fromJson(Map<String, dynamic> json) {
    return MenuOptionItemModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      precoAdicional: (json['preco_adicional'] as num?)?.toInt() ?? 0,
      isDisponivel: (json['is_disponivel'] as bool?) ?? true,
    );
  }

  @override
  List<Object?> get props => [id, nome, precoAdicional, isDisponivel];
}

/// Representa um grupo de opções (`GrupoOpcao`) de um item (RN-014).
@immutable
class MenuOptionGroupModel extends Equatable {
  final String id;
  final String nome;
  final bool isObrigatorio;
  final int minimoEscolhas;
  final int maximoEscolhas;
  final List<MenuOptionItemModel> opcoes;

  const MenuOptionGroupModel({
    required this.id,
    required this.nome,
    required this.isObrigatorio,
    required this.minimoEscolhas,
    required this.maximoEscolhas,
    required this.opcoes,
  });

  factory MenuOptionGroupModel.fromJson(Map<String, dynamic> json) {
    final rawOpcoes = (json['opcoes'] as List<dynamic>?) ?? const [];
    return MenuOptionGroupModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      isObrigatorio: (json['is_obrigatorio'] as bool?) ?? false,
      minimoEscolhas: (json['minimo_escolhas'] as num?)?.toInt() ?? 0,
      maximoEscolhas: (json['maximo_escolhas'] as num?)?.toInt() ?? 1,
      opcoes: rawOpcoes
          .whereType<Map<String, dynamic>>()
          .map(MenuOptionItemModel.fromJson)
          .toList(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        nome,
        isObrigatorio,
        minimoEscolhas,
        maximoEscolhas,
        opcoes,
      ];
}

/// Representa um item do menu (`ItemMenu`) (RN-014, RN-015, RN-016).
@immutable
class MenuItemModel extends Equatable {
  final String id;
  final String nome;
  final String descricao;
  final int preco; // Unidades mínimas inteiras (Cêntimos / Kwanza convertido - RN-059)
  final String imagemUrl;
  final List<String> alergenos;
  final bool isDisponivel;
  final List<MenuOptionGroupModel> gruposOpcoes;

  const MenuItemModel({
    required this.id,
    required this.nome,
    required this.descricao,
    required this.preco,
    required this.imagemUrl,
    required this.alergenos,
    required this.isDisponivel,
    required this.gruposOpcoes,
  });

  factory MenuItemModel.fromJson(Map<String, dynamic> json) {
    final rawAlergenos = (json['alergenos'] as List<dynamic>?) ?? const [];
    final rawGrupos = (json['grupos_opcoes'] as List<dynamic>?) ?? const [];

    return MenuItemModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      descricao: (json['descricao'] as String?) ?? '',
      preco: (json['preco'] as num?)?.toInt() ?? 0,
      imagemUrl: (json['imagem_url'] as String?) ?? '',
      alergenos: rawAlergenos.map((e) => '$e').toList(),
      isDisponivel: (json['is_disponivel'] as bool?) ?? true,
      gruposOpcoes: rawGrupos
          .whereType<Map<String, dynamic>>()
          .map(MenuOptionGroupModel.fromJson)
          .toList(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        nome,
        descricao,
        preco,
        imagemUrl,
        alergenos,
        isDisponivel,
        gruposOpcoes,
      ];
}

/// Representa uma Categoria do Menu (`CategoriaItem`) com os seus itens (RN-014).
@immutable
class MenuCategoryModel extends Equatable {
  final String id;
  final String nome;
  final int ordemExibicao;
  final List<MenuItemModel> itens;

  const MenuCategoryModel({
    required this.id,
    required this.nome,
    required this.ordemExibicao,
    required this.itens,
  });

  factory MenuCategoryModel.fromJson(Map<String, dynamic> json) {
    final rawItens = (json['itens'] as List<dynamic>?) ?? const [];
    return MenuCategoryModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      ordemExibicao: (json['ordem_exibicao'] as num?)?.toInt() ?? 0,
      itens: rawItens
          .whereType<Map<String, dynamic>>()
          .map(MenuItemModel.fromJson)
          .toList(),
    );
  }

  @override
  List<Object?> get props => [id, nome, ordemExibicao, itens];
}

/// Formata valores monetários inteiros (unidades mínimas — RN-059) para exibição ao cliente.
String formatarMoedaUnidadesMinimas(int valorInteiro, {String simbolo = 'Kz'}) {
  final valorReal = valorInteiro / 100.0;
  return '${valorReal.toStringAsFixed(2)} $simbolo';
}

// ============================================================================
// 2. REPOSITÓRIO DE CATÁLOGO E DESCOBERTA COM DIO (CatalogRepository)
// ============================================================================

class CatalogRepository {
  final Dio _dio;

  CatalogRepository({
    Dio? dio,
    String baseUrl = 'https://api.seudominio.com',
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                headers: const {
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
              ),
            );

  /// RN-025 / RN-026 / RN-027 / RN-028: Carrega a lista de lojas para as coordenadas do cliente
  /// a partir do endpoint `GET /api/v1/catalog/stores/`.
  Future<List<StoreSummaryModel>> fetchStores({
    required double lat,
    required double lng,
    bool incluirFechadas = true,
    String? query,
    double? scoreMin,
  }) async {
    final queryParams = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'incluir_fechadas': incluirFechadas,
    };
    if (query != null && query.trim().isNotEmpty) {
      queryParams['q'] = query.trim();
    }
    if (scoreMin != null) {
      queryParams['score_min'] = scoreMin;
    }

    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/catalog/stores/',
      queryParameters: queryParams,
    );

    final data = response.data;
    if (data == null) return const [];

    final results = (data['results'] as List<dynamic>?) ?? const [];
    return results
        .whereType<Map<String, dynamic>>()
        .map(StoreSummaryModel.fromJson)
        .toList();
  }

  /// RN-014 / RN-015: Carrega as categorias e itens do menu de uma loja específica
  /// a partir do endpoint `GET /api/v1/catalog/stores/<storeId>/menu/`.
  Future<List<MenuCategoryModel>> fetchStoreMenu(String storeId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/catalog/stores/$storeId/menu/',
    );

    final data = response.data;
    if (data == null) return const [];

    final rawCategories = (data['categorias'] as List<dynamic>?) ?? const [];
    return rawCategories
        .whereType<Map<String, dynamic>>()
        .map(MenuCategoryModel.fromJson)
        .toList();
  }
}

// ============================================================================
// 3. BLOC DE DESCOBERTA DE LOJAS E FILTROS (StoreDiscoveryBloc - RN-028)
// ============================================================================

@immutable
sealed class StoreDiscoveryEvent extends Equatable {
  const StoreDiscoveryEvent();

  @override
  List<Object?> get props => [];
}

final class LoadStoresForLocationEvent extends StoreDiscoveryEvent {
  final CustomerGeoAddress address;
  final String? selectedCuisine;
  final double? minRating;
  final bool onlyFreeDelivery;
  final String searchQuery;

  const LoadStoresForLocationEvent({
    required this.address,
    this.selectedCuisine,
    this.minRating,
    this.onlyFreeDelivery = false,
    this.searchQuery = '',
  });

  @override
  List<Object?> get props => [
        address,
        selectedCuisine,
        minRating,
        onlyFreeDelivery,
        searchQuery,
      ];
}

@immutable
sealed class StoreDiscoveryState extends Equatable {
  final CustomerGeoAddress currentAddress;
  final String? selectedCuisine;
  final double? minRating;
  final bool onlyFreeDelivery;
  final String searchQuery;

  const StoreDiscoveryState({
    required this.currentAddress,
    this.selectedCuisine,
    this.minRating,
    this.onlyFreeDelivery = false,
    this.searchQuery = '',
  });

  @override
  List<Object?> get props => [
        currentAddress,
        selectedCuisine,
        minRating,
        onlyFreeDelivery,
        searchQuery,
      ];
}

final class StoreDiscoveryLoading extends StoreDiscoveryState {
  const StoreDiscoveryLoading({
    required super.currentAddress,
    super.selectedCuisine,
    super.minRating,
    super.onlyFreeDelivery,
    super.searchQuery,
  });
}

final class StoreDiscoveryLoaded extends StoreDiscoveryState {
  final List<StoreSummaryModel> stores;

  const StoreDiscoveryLoaded({
    required this.stores,
    required super.currentAddress,
    super.selectedCuisine,
    super.minRating,
    super.onlyFreeDelivery,
    super.searchQuery,
  });

  @override
  List<Object?> get props => [...super.props, stores];
}

final class StoreDiscoveryError extends StoreDiscoveryState {
  final String message;

  const StoreDiscoveryError({
    required this.message,
    required super.currentAddress,
    super.selectedCuisine,
    super.minRating,
    super.onlyFreeDelivery,
    super.searchQuery,
  });

  @override
  List<Object?> get props => [...super.props, message];
}

class StoreDiscoveryBloc
    extends Bloc<StoreDiscoveryEvent, StoreDiscoveryState> {
  final CatalogRepository _repository;

  StoreDiscoveryBloc({
    required CatalogRepository repository,
    required CustomerGeoAddress initialAddress,
  })  : _repository = repository,
        super(StoreDiscoveryLoading(currentAddress: initialAddress)) {
    on<LoadStoresForLocationEvent>(_onLoadStores);
  }

  Future<void> _onLoadStores(
    LoadStoresForLocationEvent event,
    Emitter<StoreDiscoveryState> emit,
  ) async {
    emit(
      StoreDiscoveryLoading(
        currentAddress: event.address,
        selectedCuisine: event.selectedCuisine,
        minRating: event.minRating,
        onlyFreeDelivery: event.onlyFreeDelivery,
        searchQuery: event.searchQuery,
      ),
    );

    try {
      final combinedQuery = [
        if (event.selectedCuisine != null && event.selectedCuisine!.isNotEmpty)
          event.selectedCuisine!,
        if (event.searchQuery.trim().isNotEmpty) event.searchQuery.trim(),
      ].join(' ');

      var stores = await _repository.fetchStores(
        lat: event.address.latitude,
        lng: event.address.longitude,
        incluirFechadas: true,
        query: combinedQuery.isEmpty ? null : combinedQuery,
        scoreMin: event.minRating,
      );

      // Filtro RN-028: Entrega Grátis
      if (event.onlyFreeDelivery) {
        stores = stores.where((s) => s.isEntregaGratis).toList();
      }

      emit(
        StoreDiscoveryLoaded(
          stores: stores,
          currentAddress: event.address,
          selectedCuisine: event.selectedCuisine,
          minRating: event.minRating,
          onlyFreeDelivery: event.onlyFreeDelivery,
          searchQuery: event.searchQuery,
        ),
      );
    } on DioException catch (e) {
      emit(
        StoreDiscoveryError(
          message:
              'Não foi possível carregar as lojas na sua zona (${e.response?.statusCode ?? 'Erro de Rede'}).',
          currentAddress: event.address,
          selectedCuisine: event.selectedCuisine,
          minRating: event.minRating,
          onlyFreeDelivery: event.onlyFreeDelivery,
          searchQuery: event.searchQuery,
        ),
      );
    } catch (e) {
      emit(
        StoreDiscoveryError(
          message: 'Erro inesperado ao carregar catálogo: $e',
          currentAddress: event.address,
          selectedCuisine: event.selectedCuisine,
          minRating: event.minRating,
          onlyFreeDelivery: event.onlyFreeDelivery,
          searchQuery: event.searchQuery,
        ),
      );
    }
  }
}

// ============================================================================
// 4. BLOC DE MENU DA LOJA E CARRINHO (StoreMenuBloc - RN-014, RN-015, RN-040)
// ============================================================================

@immutable
sealed class StoreMenuEvent extends Equatable {
  const StoreMenuEvent();

  @override
  List<Object?> get props => [];
}

final class LoadStoreMenuEvent extends StoreMenuEvent {
  final String storeId;

  const LoadStoreMenuEvent({required this.storeId});

  @override
  List<Object?> get props => [storeId];
}

final class AddMenuItemToCartEvent extends StoreMenuEvent {
  final MenuItemModel item;

  const AddMenuItemToCartEvent({required this.item});

  @override
  List<Object?> get props => [item];
}

@immutable
sealed class StoreMenuState extends Equatable {
  const StoreMenuState();

  @override
  List<Object?> get props => [];
}

final class StoreMenuLoading extends StoreMenuState {
  const StoreMenuLoading();
}

final class StoreMenuLoaded extends StoreMenuState {
  final List<MenuCategoryModel> categories;
  final Map<String, int> cartQuantities;
  final int cartSubtotalCentimos;

  const StoreMenuLoaded({
    required this.categories,
    this.cartQuantities = const {},
    this.cartSubtotalCentimos = 0,
  });

  int get totalCartItems =>
      cartQuantities.values.fold(0, (acc, qty) => acc + qty);

  @override
  List<Object?> get props => [categories, cartQuantities, cartSubtotalCentimos];
}

final class StoreMenuError extends StoreMenuState {
  final String message;

  const StoreMenuError({required this.message});

  @override
  List<Object?> get props => [message];
}

class StoreMenuBloc extends Bloc<StoreMenuEvent, StoreMenuState> {
  final CatalogRepository _repository;

  StoreMenuBloc({required CatalogRepository repository})
      : _repository = repository,
        super(const StoreMenuLoading()) {
    on<LoadStoreMenuEvent>(_onLoadStoreMenu);
    on<AddMenuItemToCartEvent>(_onAddMenuItemToCart);
  }

  Future<void> _onLoadStoreMenu(
    LoadStoreMenuEvent event,
    Emitter<StoreMenuState> emit,
  ) async {
    emit(const StoreMenuLoading());
    try {
      final categories = await _repository.fetchStoreMenu(event.storeId);
      emit(StoreMenuLoaded(categories: categories));
    } catch (e) {
      emit(
        StoreMenuError(
          message: 'Não foi possível carregar o menu da loja: $e',
        ),
      );
    }
  }

  void _onAddMenuItemToCart(
    AddMenuItemToCartEvent event,
    Emitter<StoreMenuState> emit,
  ) {
    // RN-015: Bloqueio estrito no nível de domínio caso o item esteja indisponível
    if (!event.item.isDisponivel) return;

    final currentState = state;
    if (currentState is! StoreMenuLoaded) return;

    final updatedQuantities = Map<String, int>.from(currentState.cartQuantities);
    updatedQuantities[event.item.id] =
        (updatedQuantities[event.item.id] ?? 0) + 1;

    emit(
      StoreMenuLoaded(
        categories: currentState.categories,
        cartQuantities: updatedQuantities,
        cartSubtotalCentimos:
            currentState.cartSubtotalCentimos + event.item.preco,
      ),
    );
  }
}

// ============================================================================
// 5. ECRÃ 1: HomeScreen (Descoberta, Morada Geolocalizada e Filtros RN-028)
// ============================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();

  static const List<String> _cuisines = [
    'Hambúrgueres',
    'Pizza',
    'Tradicional',
    'Sushi',
    'Mercearia',
    'Farmácia',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _dispatchFilterUpdate(
    StoreDiscoveryState state, {
    String? cuisine,
    bool clearCuisine = false,
    double? minRating,
    bool clearMinRating = false,
    bool? onlyFreeDelivery,
    String? searchQuery,
  }) {
    context.read<StoreDiscoveryBloc>().add(
          LoadStoresForLocationEvent(
            address: state.currentAddress,
            selectedCuisine:
                clearCuisine ? null : (cuisine ?? state.selectedCuisine),
            minRating:
                clearMinRating ? null : (minRating ?? state.minRating),
            onlyFreeDelivery: onlyFreeDelivery ?? state.onlyFreeDelivery,
            searchQuery: searchQuery ?? state.searchQuery,
          ),
        );
  }

  /// Abre o modal de Filtros Avançados (Cozinha, Avaliação, Entrega Grátis - RN-028).
  void _openFilterBottomSheet(BuildContext context, StoreDiscoveryState state) {
    String? tempCuisine = state.selectedCuisine;
    double? tempMinRating = state.minRating;
    bool tempFreeDelivery = state.onlyFreeDelivery;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Filtros de Descoberta (RN-028)',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tipo de Cozinha / Categoria',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _cuisines.map((cuisine) {
                      final isSelected = tempCuisine == cuisine;
                      return ChoiceChip(
                        label: Text(cuisine),
                        selected: isSelected,
                        onSelected: (selected) {
                          setModalState(() {
                            tempCuisine = selected ? cuisine : null;
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Apenas Entrega Grátis'),
                    subtitle: const Text('Mostrar lojas sem taxa de entrega'),
                    value: tempFreeDelivery,
                    onChanged: (v) => setModalState(() => tempFreeDelivery = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Avaliação 4.5+ ★'),
                    subtitle: const Text('Parceiros com excelente reputação (RN-019)'),
                    value: (tempMinRating ?? 0) >= 4.5,
                    onChanged: (v) =>
                        setModalState(() => tempMinRating = v ? 4.5 : null),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      _dispatchFilterUpdate(
                        state,
                        cuisine: tempCuisine,
                        clearCuisine: tempCuisine == null,
                        minRating: tempMinRating,
                        clearMinRating: tempMinRating == null,
                        onlyFreeDelivery: tempFreeDelivery,
                      );
                    },
                    child: const Text('Aplicar Filtros'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return BlocBuilder<StoreDiscoveryBloc, StoreDiscoveryState>(
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {},
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.location_on_rounded,
                        size: 20,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Entregar em • ${state.currentAddress.label}',
                            style: textTheme.labelMedium?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            state.currentAddress.fullAddress,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              // Botão de Filtros (RN-028)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: IconButton.filledTonal(
                  tooltip: 'Filtros (Cozinha, Avaliação, Entrega Grátis)',
                  onPressed: () => _openFilterBottomSheet(context, state),
                  icon: const Icon(Icons.tune_rounded),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              // Barra de pesquisa e chips rápidos de filtro (RN-028)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (query) =>
                      _dispatchFilterUpdate(state, searchQuery: query),
                  decoration: InputDecoration(
                    hintText: 'Pesquisar lojas, pratos ou categorias...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchController.clear();
                              _dispatchFilterUpdate(state, searchQuery: '');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    FilterChip(
                      avatar: const Icon(Icons.local_shipping_outlined, size: 18),
                      label: const Text('Entrega Grátis'),
                      selected: state.onlyFreeDelivery,
                      onSelected: (selected) => _dispatchFilterUpdate(
                        state,
                        onlyFreeDelivery: selected,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      avatar: const Icon(Icons.star_rounded, size: 18),
                      label: const Text('Avaliação 4.5+'),
                      selected: (state.minRating ?? 0) >= 4.5,
                      onSelected: (selected) => _dispatchFilterUpdate(
                        state,
                        minRating: selected ? 4.5 : null,
                        clearMinRating: !selected,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ..._cuisines.map((cuisine) {
                      final isSelected = state.selectedCuisine == cuisine;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(cuisine),
                          selected: isSelected,
                          onSelected: (selected) => _dispatchFilterUpdate(
                            state,
                            cuisine: selected ? cuisine : null,
                            clearCuisine: !selected,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Lista Vertical de Lojas em Cards Dinâmicos (RN-025, RN-026, RN-027, RN-029)
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (state is StoreDiscoveryLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (state is StoreDiscoveryError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.wifi_off_rounded,
                                size: 48,
                                color: colorScheme.error,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                state.message,
                                textAlign: TextAlign.center,
                                style: textTheme.bodyLarge,
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () => _dispatchFilterUpdate(state),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Tentar Novamente'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    if (state is StoreDiscoveryLoaded) {
                      if (state.stores.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'Nenhuma loja encontrada com cobertura para esta morada ou filtros selecionados (RN-025).',
                              textAlign: TextAlign.center,
                              style: textTheme.bodyLarge?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        );
                      }

                      return RefreshIndicator(
                        onRefresh: () async => _dispatchFilterUpdate(state),
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: state.stores.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 16),
                          itemBuilder: (context, index) {
                            final store = state.stores[index];
                            return _StoreDiscoveryCard(
                              store: store,
                              onTap: () {
                                final repository =
                                    context.read<CatalogRepository>();
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => BlocProvider(
                                      create: (_) => StoreMenuBloc(
                                        repository: repository,
                                      )..add(
                                          LoadStoreMenuEvent(storeId: store.id),
                                        ),
                                      child: StoreMenuScreen(store: store),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Card dinâmico de Loja exibindo imagem, nome, ETA, taxa de entrega, patrocinado e badge de Fechada (RN-026, RN-027, RN-029).
class _StoreDiscoveryCard extends StatelessWidget {
  final StoreSummaryModel store;
  final VoidCallback onTap;

  const _StoreDiscoveryCard({
    required this.store,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: store.isAberta ? 2 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Imagem de capa com badges sobrepostos (Fechada RN-026 / Patrocinado RN-027 / ETA RN-029)
            Stack(
              children: [
                ColorFiltered(
                  colorFilter: store.isAberta
                      ? const ColorFilter.mode(
                          Colors.transparent,
                          BlendMode.multiply,
                        )
                      : const ColorFilter.matrix(<double>[
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0,      0,      0,      1, 0,
                        ]),
                  child: AspectRatio(
                    aspectRatio: 16 / 8,
                    child: Image.network(
                      store.imagemUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.storefront_rounded,
                          size: 48,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),

                // Etiqueta transparente de Conteúdo Patrocinado (RN-027 / RN-062)
                if (store.isPatrocinado)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.75),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        store.etiquetaPatrocinado ?? 'Patrocinado',
                        style: textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                // Badge indicativo se a loja estiver Fechada (RN-026)
                if (!store.isAberta)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 16,
                            color: colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            store.proximoHorarioAbertura != null
                                ? 'Fechada • Abre ${store.proximoHorarioAbertura}'
                                : 'Fechada no momento',
                            style: textTheme.labelMedium?.copyWith(
                              color: colorScheme.onErrorContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Chip de ETA Estimada (RN-029)
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 16,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${store.etaMinutosEstimado}-${store.etaMinutosEstimado + 10} min',
                          style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // Detalhes da Loja (Nome, Score de Reputação, Distância e Taxa de Entrega)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          store.nome,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 16,
                              color: colorScheme.onPrimaryContainer,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              store.scoreReputacao.toStringAsFixed(1),
                              style: textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.delivery_dining_rounded,
                        size: 18,
                        color: store.isEntregaGratis
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        store.isEntregaGratis
                            ? 'Entrega Grátis'
                            : 'Taxa: ${formatarMoedaUnidadesMinimas(store.taxaEntregaCentimos)}',
                        style: textTheme.bodyMedium?.copyWith(
                          color: store.isEntregaGratis
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                          fontWeight: store.isEntregaGratis
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '• ${store.distanciaKm.toStringAsFixed(1)} km',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 6. ECRÃ 2: StoreMenuScreen (SliverAppBar, TabBar Horizontal e Itens RN-014/RN-015)
// ============================================================================

class StoreMenuScreen extends StatelessWidget {
  final StoreSummaryModel store;

  const StoreMenuScreen({
    super.key,
    required this.store,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return BlocBuilder<StoreMenuBloc, StoreMenuState>(
      builder: (context, state) {
        if (state is StoreMenuLoading) {
          return Scaffold(
            appBar: AppBar(title: Text(store.nome)),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        if (state is StoreMenuError) {
          return Scaffold(
            appBar: AppBar(title: Text(store.nome)),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(state.message, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => context
                          .read<StoreMenuBloc>()
                          .add(LoadStoreMenuEvent(storeId: store.id)),
                      child: const Text('Recarregar Menu'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final loadedState = state as StoreMenuLoaded;
        final categories = loadedState.categories;

        return DefaultTabController(
          length: categories.isEmpty ? 1 : categories.length,
          child: Scaffold(
            body: NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) {
                return [
                  // Cabeçalho Expansível da Loja Selecionada (SliverAppBar)
                  SliverAppBar(
                    expandedHeight: 220,
                    pinned: true,
                    stretch: true,
                    flexibleSpace: FlexibleSpaceBar(
                      title: Text(
                        store.nome,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(
                              blurRadius: 8,
                              color: Colors.black54,
                            ),
                          ],
                        ),
                      ),
                      background: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.network(
                            store.imagemUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: colorScheme.primaryContainer,
                            ),
                          ),
                          const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black26,
                                  Colors.transparent,
                                  Colors.black87,
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Lista de Categorias em formato de abas horizontais (TabBar)
                    bottom: categories.isNotEmpty
                        ? PreferredSize(
                            preferredSize: const Size.fromHeight(48),
                            child: Container(
                              color: colorScheme.surface,
                              child: TabBar(
                                isScrollable: true,
                                tabAlignment: TabAlignment.start,
                                labelColor: colorScheme.primary,
                                unselectedLabelColor:
                                    colorScheme.onSurfaceVariant,
                                indicatorColor: colorScheme.primary,
                                tabs: categories
                                    .map((cat) => Tab(text: cat.nome))
                                    .toList(),
                              ),
                            ),
                          )
                        : null,
                  ),
                ];
              },
              body: categories.isEmpty
                  ? const Center(
                      child: Text('Esta loja ainda não publicou itens no menu.'),
                    )
                  : TabBarView(
                      children: categories.map((category) {
                        if (category.itens.isEmpty) {
                          return const Center(
                            child: Text('Sem itens nesta categoria.'),
                          );
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                          itemCount: category.itens.length,
                          separatorBuilder: (_, __) => const Divider(height: 24),
                          itemBuilder: (context, index) {
                            final item = category.itens[index];
                            final quantityInCart =
                                loadedState.cartQuantities[item.id] ?? 0;

                            return _MenuItemTile(
                              item: item,
                              storeIsOpen: store.isAberta,
                              quantityInCart: quantityInCart,
                              onAddPressed: () {
                                context
                                    .read<StoreMenuBloc>()
                                    .add(AddMenuItemToCartEvent(item: item));
                              },
                            );
                          },
                        );
                      }).toList(),
                    ),
            ),

            // Barra inferior de resumo do carrinho (RN-040)
            bottomNavigationBar: loadedState.totalCartItems > 0
                ? SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: FilledButton(
                        onPressed: () {},
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '${loadedState.totalCartItems} item(ns) no carrinho',
                            ),
                            Text(
                              formatarMoedaUnidadesMinimas(
                                loadedState.cartSubtotalCentimos,
                              ),
                              style: textTheme.titleMedium?.copyWith(
                                color: colorScheme.onPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }
}

/// Componente de Item de Menu (RN-014, RN-015):
/// Se `item.isDisponivel == false`, aplica filtro cinzento (desaturação + opacidade reduzida),
/// exibe badge "Indisponível" e bloqueia estritamente o clique de adição ao carrinho.
class _MenuItemTile extends StatelessWidget {
  final MenuItemModel item;
  final bool storeIsOpen;
  final int quantityInCart;
  final VoidCallback onAddPressed;

  const _MenuItemTile({
    required this.item,
    required this.storeIsOpen,
    required this.quantityInCart,
    required this.onAddPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // RN-015: Só permite adicionar se o item estiver disponível e a loja aberta
    final bool canAdd = item.isDisponivel && storeIsOpen;

    return Opacity(
      opacity: item.isDisponivel ? 1.0 : 0.48,
      child: AbsorbPointer(
        absorbing: !canAdd,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: canAdd ? onAddPressed : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Informações Textuais do Item (Nome, Descrição, Alergénios e Preço)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              item.nome,
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                decoration: item.isDisponivel
                                    ? null
                                    : TextDecoration.lineThrough,
                              ),
                            ),
                          ),
                          if (!item.isDisponivel)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Indisponível',
                                style: textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (item.descricao.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.descricao,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (item.alergenos.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: item.alergenos.map((alergeno) {
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: colorScheme.outlineVariant,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                'Alergénio: $alergeno',
                                style: textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        formatarMoedaUnidadesMinimas(item.preco),
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: item.isDisponivel
                              ? colorScheme.primary
                              : colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),

                // Imagem do Item (em escala de cinzentos se indisponível) + Botão de Adicionar (RN-015)
                Column(
                  children: [
                    if (item.imagemUrl.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ColorFiltered(
                          colorFilter: item.isDisponivel
                              ? const ColorFilter.mode(
                                  Colors.transparent,
                                  BlendMode.multiply,
                                )
                              : const ColorFilter.matrix(<double>[
                                  0.2126, 0.7152, 0.0722, 0, 0,
                                  0.2126, 0.7152, 0.0722, 0, 0,
                                  0.2126, 0.7152, 0.0722, 0, 0,
                                  0,      0,      0,      1, 0,
                                ]),
                          child: Image.network(
                            item.imagemUrl,
                            width: 88,
                            height: 88,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 88,
                              height: 88,
                              color: colorScheme.surfaceContainerHighest,
                              child: const Icon(Icons.fastfood_outlined),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      // RN-015: `onPressed: null` quando `canAdd == false`
                      onPressed: canAdd ? onAddPressed : null,
                      icon: Icon(
                        canAdd ? Icons.add_rounded : Icons.block_rounded,
                        size: 18,
                      ),
                      label: Text(
                        !item.isDisponivel
                            ? 'Esgotado'
                            : (quantityInCart > 0
                                ? 'Adicionado ($quantityInCart)'
                                : 'Adicionar'),
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
}
