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

import '../../core/network/app_environment_config.dart';
import '../auth/storage/secure_token_storage.dart';
import '../cart/cart.dart';
import '../checkout/checkout_screen.dart';

// ============================================================================
// 1. MODELOS DE DADOS DO CATÁLOGO E DESCOBERTA (RN-014, RN-015, RN-025 a RN-029)
// ============================================================================

/// Representa a morada atual geolocalizada do Cliente (RN-005, RN-025).
@immutable
class CustomerGeoAddress extends Equatable {
  final String id;
  final String label;
  final String fullAddress;
  final String referencia;
  final String andarPorta;
  final String instrucoesEstafeta;
  final double latitude;
  final double longitude;

  const CustomerGeoAddress({
    this.id = 'morada_principal',
    required this.label,
    required this.fullAddress,
    this.referencia = '',
    this.andarPorta = '',
    this.instrucoesEstafeta = '',
    required this.latitude,
    required this.longitude,
  });

  factory CustomerGeoAddress.fromMoradaJson(Map<String, dynamic> json) {
    final texto = (json['texto_endereco'] as String?) ?? 'Luanda, Angola';
    final ref = (json['referencia'] as String?) ?? '';
    final labelExtraido = ref.trim().isNotEmpty
        ? ref.trim()
        : texto.split(',').first.trim();
    return CustomerGeoAddress(
      id: '${json['id'] ?? 'morada_principal'}',
      label: labelExtraido.isNotEmpty ? labelExtraido : 'Morada de Entrega',
      fullAddress: texto,
      referencia: ref,
      andarPorta: (json['andar_porta'] as String?) ?? '',
      instrucoesEstafeta: (json['instrucoes_estafeta'] as String?) ?? '',
      latitude: (json['lat'] as num?)?.toDouble() ?? -8.8147,
      longitude: (json['lng'] as num?)?.toDouble() ?? 13.2343,
    );
  }

  @override
  List<Object?> get props => [
        id,
        label,
        fullAddress,
        referencia,
        andarPorta,
        instrucoesEstafeta,
        latitude,
        longitude,
      ];
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
      id: '${json['id']}',
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
  void initState() {
    super.initState();
    _syncDefaultAddressFromBackend();
  }

  Future<void> _syncDefaultAddressFromBackend() async {
    try {
      final token = await SecureTokenStorage().getAccessToken();
      if (token == null || token.isEmpty) return;

      final dio = Dio(BaseOptions(baseUrl: AppEnvironmentConfig.baseHttpUrl));
      final resp = await dio.get<dynamic>(
        '/api/v1/auth/moradas/',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final rawData = resp.data;
      List<dynamic> list = const [];
      if (rawData is List) {
        list = rawData;
      } else if (rawData is Map<String, dynamic> && rawData['results'] is List) {
        list = rawData['results'] as List<dynamic>;
      }
      if (list.isNotEmpty && list.first is Map<String, dynamic>) {
        final addr = CustomerGeoAddress.fromMoradaJson(
          list.first as Map<String, dynamic>,
        );
        CartService.instance.updateActiveAddress(
          id: addr.id,
          label: addr.label,
          fullAddress: addr.fullAddress,
          referencia: addr.referencia,
          latitude: addr.latitude,
          longitude: addr.longitude,
        );
        if (mounted) {
          final currentState = context.read<StoreDiscoveryBloc>().state;
          _dispatchFilterUpdate(currentState, address: addr);
        }
      }
    } catch (_) {
      // Mantém morada inicial em caso de falha silenciosa
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _dispatchFilterUpdate(
    StoreDiscoveryState state, {
    CustomerGeoAddress? address,
    String? cuisine,
    bool clearCuisine = false,
    double? minRating,
    bool clearMinRating = false,
    bool? onlyFreeDelivery,
    String? searchQuery,
  }) {
    context.read<StoreDiscoveryBloc>().add(
          LoadStoresForLocationEvent(
            address: address ?? state.currentAddress,
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
              onTap: () {
                showCustomerAddressSelectionSheet(
                  context,
                  currentAddress: state.currentAddress,
                  onAddressSelected: (newAddr) {
                    _dispatchFilterUpdate(state, address: newAddr);
                  },
                );
              },
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
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  'Entregar em • ${state.currentAddress.label}',
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelMedium?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 16,
                                color: colorScheme.primary,
                              ),
                            ],
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

    return AnimatedBuilder(
      animation: CartService.instance,
      builder: (context, _) {
        final cart = CartService.instance;
        final isThisStoreCart = cart.lojaId == store.id && cart.isNotEmpty;

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
                          child: Text(
                              'Esta loja ainda não publicou itens no menu.'),
                        )
                      : TabBarView(
                          children: categories.map((category) {
                            if (category.itens.isEmpty) {
                              return const Center(
                                child: Text('Sem itens nesta categoria.'),
                              );
                            }
                            return ListView.separated(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 16, 16, 100),
                              itemCount: category.itens.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 24),
                              itemBuilder: (context, index) {
                                final item = category.itens[index];
                                final quantityInCart = isThisStoreCart
                                    ? cart.getQuantity(item.id)
                                    : 0;

                                return _MenuItemTile(
                                  item: item,
                                  storeIsOpen: store.isAberta,
                                  quantityInCart: quantityInCart,
                                  onAddPressed: () =>
                                      _handleMenuItemTap(context, store, item),
                                );
                              },
                            );
                          }).toList(),
                        ),
                ),

                // Barra inferior de resumo do carrinho (RN-040)
                bottomNavigationBar: isThisStoreCart
                    ? SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: FilledButton(
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => CheckoutScreen(
                                    lojaId: store.id,
                                    lojaNome: store.nome,
                                    moradaId: cart.moradaId,
                                    moradaLabel: cart.moradaLabel,
                                    moradaTexto: cart.moradaTexto,
                                    itensCarrinho: cart.toCheckoutInputs(),
                                  ),
                                ),
                              );
                            },
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '${cart.totalItemsCount} item(ns) • Ver Pedido',
                                ),
                                Text(
                                  formatarMoedaUnidadesMinimas(
                                    cart.totalSubtotalCentimos,
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
      },
    );
  }

  Future<void> _handleMenuItemTap(
    BuildContext context,
    StoreSummaryModel store,
    MenuItemModel item,
  ) async {
    final cart = CartService.instance;
    if (cart.hasStoreConflict(store.id)) {
      final confirmClear = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('Limpar sacola atual? (RN-040)'),
          content: Text(
            'A sua sacola já contém itens de "${cart.lojaNome ?? 'outra loja'}". '
            'Deseja limpar a sacola atual e iniciar um novo pedido em "${store.nome}"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('Sim, limpar e continuar'),
            ),
          ],
        ),
      );
      if (confirmClear != true || !context.mounted) return;
      cart.clear();
    }

    showItemCustomizationBottomSheet(
      context,
      store: store,
      item: item,
      onItemAdded: () {
        if (context.mounted) {
          context
              .read<StoreMenuBloc>()
              .add(AddMenuItemToCartEvent(item: item));
        }
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

// ============================================================================
// 7. MODAL DE PERSONALIZAÇÃO DE ITEM DE MENU (RN-014, RN-042, RN-045)
// ============================================================================

Future<void> showItemCustomizationBottomSheet(
  BuildContext context, {
  required StoreSummaryModel store,
  required MenuItemModel item,
  VoidCallback? onItemAdded,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _ItemCustomizationSheet(
      store: store,
      item: item,
      onItemAdded: onItemAdded,
    ),
  );
}

class _ItemCustomizationSheet extends StatefulWidget {
  final StoreSummaryModel store;
  final MenuItemModel item;
  final VoidCallback? onItemAdded;

  const _ItemCustomizationSheet({
    required this.store,
    required this.item,
    this.onItemAdded,
  });

  @override
  State<_ItemCustomizationSheet> createState() =>
      _ItemCustomizationSheetState();
}

class _ItemCustomizationSheetState extends State<_ItemCustomizationSheet> {
  int _quantity = 1;
  final Map<String, Set<String>> _selectedOptionsByGroup = {};
  final TextEditingController _notesController = TextEditingController();
  String? _validationError;

  @override
  void initState() {
    super.initState();
    for (final group in widget.item.gruposOpcoes) {
      _selectedOptionsByGroup[group.id] = <String>{};
      // Se for obrigatório e tiver pelo menos 1 opção disponível, pré-seleciona a primeira para conveniência
      if (group.isObrigatorio) {
        final available = group.opcoes.where((o) => o.isDisponivel).toList();
        final minNeeded = group.minimoEscolhas > 0 ? group.minimoEscolhas : 1;
        for (var i = 0; i < minNeeded && i < available.length; i++) {
          _selectedOptionsByGroup[group.id]!.add(available[i].id);
        }
      }
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  int get _optionsExtraCentimos {
    var extra = 0;
    for (final group in widget.item.gruposOpcoes) {
      final selectedSet = _selectedOptionsByGroup[group.id] ?? const <String>{};
      for (final opt in group.opcoes) {
        if (selectedSet.contains(opt.id)) {
          extra += opt.precoAdicional;
        }
      }
    }
    return extra;
  }

  int get _unitPriceCentimos => widget.item.preco + _optionsExtraCentimos;

  int get _totalPriceCentimos => _unitPriceCentimos * _quantity;

  bool _validateGroups() {
    for (final group in widget.item.gruposOpcoes) {
      final count = (_selectedOptionsByGroup[group.id] ?? const <String>{}).length;
      final minRequired = group.isObrigatorio
          ? (group.minimoEscolhas > 0 ? group.minimoEscolhas : 1)
          : group.minimoEscolhas;
      if (count < minRequired) {
        setState(() {
          _validationError =
              'Selecione pelo menos $minRequired opção(ões) em "${group.nome}" (RN-014).';
        });
        return false;
      }
      if (group.maximoEscolhas > 0 && count > group.maximoEscolhas) {
        setState(() {
          _validationError =
              'Máximo de ${group.maximoEscolhas} opção(ões) permitido em "${group.nome}" (RN-014).';
        });
        return false;
      }
    }
    setState(() => _validationError = null);
    return true;
  }

  void _toggleOption(MenuOptionGroupModel group, MenuOptionItemModel option) {
    if (!option.isDisponivel) return;
    final set = _selectedOptionsByGroup.putIfAbsent(group.id, () => <String>{});
    setState(() {
      _validationError = null;
      if (set.contains(option.id)) {
        set.remove(option.id);
      } else {
        if (group.maximoEscolhas == 1) {
          set
            ..clear()
            ..add(option.id);
        } else if (group.maximoEscolhas <= 0 ||
            set.length < group.maximoEscolhas) {
          set.add(option.id);
        } else {
          _validationError =
              'Já selecionou o limite máximo (${group.maximoEscolhas}) para "${group.nome}".';
        }
      }
    });
  }

  void _confirmAdd() {
    if (!_validateGroups()) return;

    final selectedIds = <String>[];
    final selectedNames = <String>[];
    for (final group in widget.item.gruposOpcoes) {
      final set = _selectedOptionsByGroup[group.id] ?? const <String>{};
      for (final opt in group.opcoes) {
        if (set.contains(opt.id)) {
          selectedIds.add(opt.id);
          selectedNames.add(opt.nome);
        }
      }
    }

    CartService.instance.addItem(
      itemId: widget.item.id,
      lojaId: widget.store.id,
      lojaNome: widget.store.nome,
      nome: widget.item.nome,
      imagemUrl: widget.item.imagemUrl,
      precoUnitarioCentimos: _unitPriceCentimos,
      quantidade: _quantity,
      opcoesIds: selectedIds,
      opcoesNomes: selectedNames,
      notas: _notesController.text.trim(),
    );

    widget.onItemAdded?.call();
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_quantity}x ${widget.item.nome} adicionado à sacola!',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                children: [
                  if (widget.item.imagemUrl.isNotEmpty) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: AspectRatio(
                        aspectRatio: 16 / 9,
                        child: Image.network(
                          widget.item.imagemUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.fastfood_rounded, size: 48),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    widget.item.nome,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    formatarMoedaUnidadesMinimas(widget.item.preco),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (widget.item.descricao.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.item.descricao,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (widget.item.gruposOpcoes.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const Divider(),
                    ...widget.item.gruposOpcoes.map((group) {
                      final selectedSet =
                          _selectedOptionsByGroup[group.id] ?? const <String>{};
                      final minRequired = group.isObrigatorio
                          ? (group.minimoEscolhas > 0 ? group.minimoEscolhas : 1)
                          : group.minimoEscolhas;

                      return Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        group.nome,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        minRequired > 0
                                            ? 'Escolha de $minRequired até ${group.maximoEscolhas}'
                                            : 'Escolha até ${group.maximoEscolhas} (Opcional)',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: group.isObrigatorio
                                        ? colorScheme.primaryContainer
                                        : colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    group.isObrigatorio
                                        ? 'Obrigatório'
                                        : 'Opcional',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: group.isObrigatorio
                                          ? colorScheme.onPrimaryContainer
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...group.opcoes.map((opt) {
                              final isSelected = selectedSet.contains(opt.id);
                              return CheckboxListTile(
                                value: isSelected,
                                enabled: opt.isDisponivel,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                onChanged: opt.isDisponivel
                                    ? (_) => _toggleOption(group, opt)
                                    : null,
                                title: Text(
                                  opt.nome,
                                  style: TextStyle(
                                    decoration: opt.isDisponivel
                                        ? null
                                        : TextDecoration.lineThrough,
                                  ),
                                ),
                                secondary: Text(
                                  opt.precoAdicional > 0
                                      ? '+ ${formatarMoedaUnidadesMinimas(opt.precoAdicional)}'
                                      : 'Grátis',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Observações para a cozinha (RN-045)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _notesController,
                    maxLines: 2,
                    maxLength: 200,
                    decoration: InputDecoration(
                      hintText:
                          'Ex.: Sem cebola, molho à parte, bem passado...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  if (_validationError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _validationError!,
                        style: TextStyle(
                          color: colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Barra inferior: Quantidade + Botão Adicionar
            SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _quantity > 1
                                ? () => setState(() => _quantity--)
                                : null,
                            icon: const Icon(Icons.remove_rounded),
                          ),
                          Text(
                            '$_quantity',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            onPressed: _quantity < 20
                                ? () => setState(() => _quantity++)
                                : null,
                            icon: const Icon(Icons.add_rounded),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _confirmAdd,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(
                          'Adicionar • ${formatarMoedaUnidadesMinimas(_totalPriceCentimos)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 8. MODAL DE GESTÃO E SELEÇÃO DE MORADAS DE ENTREGA (RN-005, RN-025)
// ============================================================================

Future<void> showCustomerAddressSelectionSheet(
  BuildContext context, {
  CustomerGeoAddress? currentAddress,
  ValueChanged<CustomerGeoAddress>? onAddressSelected,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _CustomerAddressSelectionSheet(
      currentAddress: currentAddress,
      onAddressSelected: onAddressSelected,
    ),
  );
}

class _CustomerAddressSelectionSheet extends StatefulWidget {
  final CustomerGeoAddress? currentAddress;
  final ValueChanged<CustomerGeoAddress>? onAddressSelected;

  const _CustomerAddressSelectionSheet({
    this.currentAddress,
    this.onAddressSelected,
  });

  @override
  State<_CustomerAddressSelectionSheet> createState() =>
      _CustomerAddressSelectionSheetState();
}

class _CustomerAddressSelectionSheetState
    extends State<_CustomerAddressSelectionSheet> {
  bool _isLoading = true;
  bool _isCreating = false;
  bool _showForm = false;
  String? _errorMsg;
  List<CustomerGeoAddress> _savedAddresses = [];

  final _enderecoController = TextEditingController();
  final _referenciaController = TextEditingController();
  final _andarPortaController = TextEditingController();
  final _instrucoesController = TextEditingController();
  int _selectedPresetIndex = 0;

  static const List<CustomerGeoAddress> _luandaDistrictPresets = [
    CustomerGeoAddress(
      id: 'preset_ingombota',
      label: 'Ingombota / Centro',
      fullAddress: 'Avenida 4 de Fevereiro, Marginal de Luanda, Ingombota',
      referencia: 'Centro de Luanda',
      latitude: -8.8147,
      longitude: 13.2343,
    ),
    CustomerGeoAddress(
      id: 'preset_talatona',
      label: 'Talatona',
      fullAddress: 'Via S8, Condomínio Belas Business Park, Talatona, Luanda',
      referencia: 'Talatona Shopping',
      latitude: -8.9167,
      longitude: 13.1833,
    ),
    CustomerGeoAddress(
      id: 'preset_kilamba',
      label: 'Centralidade do Kilamba',
      fullAddress: 'Quarteirão Q, Centralidade do Kilamba, Belas, Luanda',
      referencia: 'Kero Kilamba',
      latitude: -8.9950,
      longitude: 13.2680,
    ),
    CustomerGeoAddress(
      id: 'preset_maianga',
      label: 'Maianga / Alvalade',
      fullAddress: 'Rua Comandante Gika, Alvalade, Maianga, Luanda',
      referencia: 'Hotel Alvalade',
      latitude: -8.8399,
      longitude: 13.2345,
    ),
    CustomerGeoAddress(
      id: 'preset_morro_bento',
      label: 'Morro Bento',
      fullAddress: 'Avenida 21 de Janeiro, Morro Bento, Luanda',
      referencia: 'Rotunda da Multiperfil',
      latitude: -8.8850,
      longitude: 13.1950,
    ),
    CustomerGeoAddress(
      id: 'preset_viana',
      label: 'Viana / Zango',
      fullAddress: 'Estrada de Catete, Vila de Viana, Luanda',
      referencia: 'Administração de Viana',
      latitude: -8.9030,
      longitude: 13.3740,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  @override
  void dispose() {
    _enderecoController.dispose();
    _referenciaController.dispose();
    _andarPortaController.dispose();
    _instrucoesController.dispose();
    super.dispose();
  }

  Future<Dio?> _buildAuthDio() async {
    final token = await const SecureTokenStorage().getAccessToken();
    if (token == null || token.isEmpty) return null;
    return Dio(
      BaseOptions(
        baseUrl: AppEnvironmentConfig.baseHttpUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );
  }

  Future<void> _loadAddresses() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    try {
      final dio = await _buildAuthDio();
      if (dio == null) {
        setState(() {
          _savedAddresses = _luandaDistrictPresets;
          _isLoading = false;
        });
        return;
      }
      final resp = await dio.get<dynamic>('/api/v1/auth/moradas/');
      final raw = resp.data;
      List<dynamic> list = const [];
      if (raw is List) {
        list = raw;
      } else if (raw is Map<String, dynamic> && raw['results'] is List) {
        list = raw['results'] as List<dynamic>;
      }
      final parsed = list
          .whereType<Map<String, dynamic>>()
          .map(CustomerGeoAddress.fromMoradaJson)
          .toList();

      if (mounted) {
        setState(() {
          _savedAddresses = parsed;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _savedAddresses = _luandaDistrictPresets;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _selectAndActivate(
    CustomerGeoAddress address, {
    bool persistIfPreset = false,
  }) async {
    var chosen = address;
    if (persistIfPreset && address.id.startsWith('preset_')) {
      try {
        final dio = await _buildAuthDio();
        if (dio != null) {
          final resp = await dio.post<Map<String, dynamic>>(
            '/api/v1/auth/moradas/',
            data: {
              'texto_endereco': address.fullAddress,
              'referencia': address.label,
              'andar_porta': address.andarPorta,
              'instrucoes_estafeta': address.instrucoesEstafeta,
              'latitude': address.latitude,
              'longitude': address.longitude,
            },
          );
          if (resp.data != null) {
            chosen = CustomerGeoAddress.fromMoradaJson(resp.data!);
          }
        }
      } catch (_) {}
    }

    CartService.instance.updateActiveAddress(
      id: chosen.id,
      label: chosen.label,
      fullAddress: chosen.fullAddress,
      referencia: chosen.referencia,
      latitude: chosen.latitude,
      longitude: chosen.longitude,
    );
    widget.onAddressSelected?.call(chosen);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _createNewAddress() async {
    final texto = _enderecoController.text.trim();
    if (texto.length < 5) {
      setState(() => _errorMsg = 'Informe o endereço completo (mín. 5 letras).');
      return;
    }

    setState(() {
      _isCreating = true;
      _errorMsg = null;
    });

    final preset = _luandaDistrictPresets[_selectedPresetIndex];
    final ref = _referenciaController.text.trim().isNotEmpty
        ? _referenciaController.text.trim()
        : preset.label;

    try {
      final dio = await _buildAuthDio();
      if (dio != null) {
        final resp = await dio.post<Map<String, dynamic>>(
          '/api/v1/auth/moradas/',
          data: {
            'texto_endereco': '$texto, ${preset.label}, Luanda',
            'referencia': ref,
            'andar_porta': _andarPortaController.text.trim(),
            'instrucoes_estafeta': _instrucoesController.text.trim(),
            'latitude': preset.latitude,
            'longitude': preset.longitude,
          },
        );
        if (resp.data != null) {
          final created = CustomerGeoAddress.fromMoradaJson(resp.data!);
          await _selectAndActivate(created);
          return;
        }
      }
      // Fallback caso offline
      final fallback = CustomerGeoAddress(
        id: 'morada_principal',
        label: ref,
        fullAddress: '$texto, ${preset.label}, Luanda',
        referencia: ref,
        andarPorta: _andarPortaController.text.trim(),
        instrucoesEstafeta: _instrucoesController.text.trim(),
        latitude: preset.latitude,
        longitude: preset.longitude,
      );
      await _selectAndActivate(fallback);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _errorMsg = 'Não foi possível guardar a morada. Tente novamente.';
        });
      }
    }
  }

  Future<void> _deleteAddress(CustomerGeoAddress addr) async {
    if (addr.id.startsWith('preset_') || addr.id == 'morada_principal') return;
    try {
      final dio = await _buildAuthDio();
      if (dio != null) {
        await dio.delete<void>('/api/v1/auth/moradas/${addr.id}/');
      }
      await _loadAddresses();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final activeId = CartService.instance.moradaId;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _showForm
                      ? 'Nova Morada de Entrega'
                      : 'Morada de Entrega (RN-005)',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _showForm = !_showForm),
                  icon: Icon(_showForm ? Icons.close : Icons.add_location_alt),
                  label: Text(_showForm ? 'Voltar' : 'Nova Morada'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_errorMsg != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _errorMsg!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
            if (_showForm) ...[
              Text(
                'Selecione a Zona / Município em Luanda:',
                style: theme.textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(_luandaDistrictPresets.length, (i) {
                  final p = _luandaDistrictPresets[i];
                  return ChoiceChip(
                    label: Text(p.label),
                    selected: _selectedPresetIndex == i,
                    onSelected: (_) => setState(() => _selectedPresetIndex = i),
                  );
                }),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _enderecoController,
                decoration: const InputDecoration(
                  labelText: 'Rua, Avenida ou Condomínio *',
                  hintText: 'Ex.: Rua Comandante Gika, Casa 24',
                  prefixIcon: Icon(Icons.home_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _referenciaController,
                decoration: const InputDecoration(
                  labelText: 'Nome / Ponto de Referência (ex.: Casa, Trabalho)',
                  hintText: 'Ex.: Em frente à Clínica Multiperfil',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _andarPortaController,
                      decoration: const InputDecoration(
                        labelText: 'Andar / Porta',
                        hintText: 'Ex.: 2.º Andar, Porta B',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _instrucoesController,
                      decoration: const InputDecoration(
                        labelText: 'Instruções p/ Estafeta',
                        hintText: 'Ex.: Tocar campainha',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isCreating ? null : _createNewAddress,
                icon: _isCreating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: const Text('Guardar e Usar Esta Morada'),
              ),
            ] else ...[
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                if (_savedAddresses.isNotEmpty) ...[
                  Text(
                    'As Minhas Moradas Guardadas',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._savedAddresses.map((addr) {
                    final isSelected = addr.id == activeId ||
                        addr.fullAddress == CartService.instance.moradaTexto;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: 0,
                      color: isSelected
                          ? colorScheme.primaryContainer.withOpacity(0.35)
                          : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: isSelected
                              ? colorScheme.primary
                              : colorScheme.outlineVariant,
                        ),
                      ),
                      child: ListTile(
                        onTap: () => _selectAndActivate(addr),
                        leading: Icon(
                          isSelected
                              ? Icons.radio_button_checked_rounded
                              : Icons.location_on_outlined,
                          color: colorScheme.primary,
                        ),
                        title: Text(
                          addr.label,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          addr.fullAddress,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: _savedAddresses.length > 1 &&
                                !addr.id.startsWith('preset_')
                            ? IconButton(
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: colorScheme.error,
                                ),
                                onPressed: () => _deleteAddress(addr),
                              )
                            : null,
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
                Text(
                  'Zonas Rápidas de Luanda',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ..._luandaDistrictPresets.map((preset) {
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: const Icon(Icons.my_location_rounded, size: 20),
                    title: Text(
                      preset.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      preset.fullAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _selectAndActivate(
                      preset,
                      persistIfPreset: true,
                    ),
                  );
                }),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
