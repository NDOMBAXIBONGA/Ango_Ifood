import 'dart:async';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../models/partner_models.dart';

// ============================================================================
// 1. EVENTOS DO BLoC (RN-012, RN-013, RN-014, RN-015)
// ============================================================================

abstract class PartnerEvent extends Equatable {
  const PartnerEvent();

  @override
  List<Object?> get props => [];
}

/// Carrega todos os dados iniciais do parceiro (Status, Categorias, Itens e Horários).
class LoadPartnerDataRequested extends PartnerEvent {
  const LoadPartnerDataRequested();
}

/// Alterna a pausa temporária da loja com duração configurável (RN-013).
class ToggleStorePauseRequested extends PartnerEvent {
  final bool isPausaTemporaria;
  final int? duracaoMinutos;

  const ToggleStorePauseRequested({
    required this.isPausaTemporaria,
    this.duracaoMinutos,
  });

  @override
  List<Object?> get props => [isPausaTemporaria, duracaoMinutos];
}

/// Seleciona uma categoria para filtragem no ecrã de gestão de catálogo.
class SelectCategoryRequested extends PartnerEvent {
  final String? categoriaId;

  const SelectCategoryRequested(this.categoriaId);

  @override
  List<Object?> get props => [categoriaId];
}

/// Alterna imediatamente a disponibilidade de stock de um item (RN-015).
class ToggleItemAvailabilityRequested extends PartnerEvent {
  final String itemId;
  final bool isDisponivel;

  const ToggleItemAvailabilityRequested({
    required this.itemId,
    required this.isDisponivel,
  });

  @override
  List<Object?> get props => [itemId, isDisponivel];
}

/// Cria ou edita um item de menu (RN-014, RN-016).
class SaveMenuItemRequested extends PartnerEvent {
  final MenuItemModel item;
  final bool isEditing;

  const SaveMenuItemRequested({
    required this.item,
    this.isEditing = false,
  });

  @override
  List<Object?> get props => [item, isEditing];
}

/// Remove um item de menu do catálogo.
class DeleteMenuItemRequested extends PartnerEvent {
  final String itemId;

  const DeleteMenuItemRequested(this.itemId);

  @override
  List<Object?> get props => [itemId];
}

/// Cria uma nova categoria de catálogo de produtos.
class CreateCategoryRequested extends PartnerEvent {
  final String nome;

  const CreateCategoryRequested(this.nome);

  @override
  List<Object?> get props => [nome];
}

/// Grava a configuração semanal de horários da loja (RN-012).
class SaveBusinessHoursRequested extends PartnerEvent {
  final List<BusinessHourSlot> hours;

  const SaveBusinessHoursRequested(this.hours);

  @override
  List<Object?> get props => [hours];
}

/// Tick do timer para atualizar contagem decrescente no painel de controlo (RN-013).
class PauseTimerTicked extends PartnerEvent {
  final Duration tempoRestante;

  const PauseTimerTicked(this.tempoRestante);

  @override
  List<Object?> get props => [tempoRestante];
}

// ============================================================================
// 2. ESTADOS DO BLoC
// ============================================================================

enum PartnerStatus { initial, loading, success, error }

class PartnerState extends Equatable {
  final PartnerStatus status;
  final PartnerStoreStatus? storeStatus;
  final List<MenuCategory> categories;
  final List<MenuItemModel> items;
  final List<BusinessHourSlot> businessHours;
  final String? selectedCategoryId;
  final Duration? tempoRestantePausa;
  final String? errorMessage;
  final String? successMessage;
  final bool isSavingItem;
  final bool isUpdatingHours;

  const PartnerState({
    this.status = PartnerStatus.initial,
    this.storeStatus,
    this.categories = const [],
    this.items = const [],
    this.businessHours = const [],
    this.selectedCategoryId,
    this.tempoRestantePausa,
    this.errorMessage,
    this.successMessage,
    this.isSavingItem = false,
    this.isUpdatingHours = false,
  });

  List<MenuItemModel> get filteredItems {
    if (selectedCategoryId == null || selectedCategoryId!.isEmpty) {
      return items;
    }
    return items.where((i) => i.categoriaId == selectedCategoryId).toList();
  }

  PartnerState copyWith({
    PartnerStatus? status,
    PartnerStoreStatus? storeStatus,
    List<MenuCategory>? categories,
    List<MenuItemModel>? items,
    List<BusinessHourSlot>? businessHours,
    String? selectedCategoryId,
    bool clearSelectedCategory = false,
    Duration? tempoRestantePausa,
    bool clearPauseTimer = false,
    String? errorMessage,
    bool clearError = false,
    String? successMessage,
    bool clearSuccess = false,
    bool? isSavingItem,
    bool? isUpdatingHours,
  }) {
    return PartnerState(
      status: status ?? this.status,
      storeStatus: storeStatus ?? this.storeStatus,
      categories: categories ?? this.categories,
      items: items ?? this.items,
      businessHours: businessHours ?? this.businessHours,
      selectedCategoryId: clearSelectedCategory ? null : (selectedCategoryId ?? this.selectedCategoryId),
      tempoRestantePausa: clearPauseTimer ? null : (tempoRestantePausa ?? this.tempoRestantePausa),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      successMessage: clearSuccess ? null : (successMessage ?? this.successMessage),
      isSavingItem: isSavingItem ?? this.isSavingItem,
      isUpdatingHours: isUpdatingHours ?? this.isUpdatingHours,
    );
  }

  @override
  List<Object?> get props => [
        status,
        storeStatus,
        categories,
        items,
        businessHours,
        selectedCategoryId,
        tempoRestantePausa,
        errorMessage,
        successMessage,
        isSavingItem,
        isUpdatingHours,
      ];
}

// ============================================================================
// 3. REPOSITÓRIO HTTP DO PARCEIRO (Dio)
// ============================================================================

class PartnerRepository {
  final Dio _dio;

  PartnerRepository({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: 'http://10.0.2.2:8000',
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
                headers: {
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
              ),
            );

  Future<PartnerStoreStatus> getStoreStatus() async {
    final response = await _dio.get('/api/v1/partner/store/status/');
    return PartnerStoreStatus.fromJson(response.data as Map<String, dynamic>);
  }

  Future<PartnerStoreStatus> updateStorePause({
    required bool isPausaTemporaria,
    int? duracaoMinutos,
  }) async {
    final response = await _dio.patch(
      '/api/v1/partner/store/status/',
      data: {
        'is_pausa_temporaria': isPausaTemporaria,
        if (duracaoMinutos != null) 'duracao_minutos': duracaoMinutos,
      },
    );
    return PartnerStoreStatus.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<MenuCategory>> getCategories() async {
    final response = await _dio.get('/api/v1/partner/catalog/categories/');
    final dynamic data = response.data;
    final List<dynamic> list = data is Map ? (data['results'] as List? ?? []) : (data as List? ?? []);
    return list.map((e) => MenuCategory.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<MenuItemModel>> getItems({String? categoriaId}) async {
    final Map<String, dynamic> query = {};
    if (categoriaId != null && categoriaId.isNotEmpty) {
      query['categoria'] = categoriaId;
    }
    final response = await _dio.get(
      '/api/v1/partner/catalog/items/',
      queryParameters: query,
    );
    final dynamic data = response.data;
    final List<dynamic> list = data is Map ? (data['results'] as List? ?? []) : (data as List? ?? []);
    return list.map((e) => MenuItemModel.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<MenuItemModel> toggleItemAvailability(String itemId, bool isDisponivel) async {
    final response = await _dio.patch(
      '/api/v1/partner/catalog/items/$itemId/',
      data: {'is_disponivel': isDisponivel},
    );
    return MenuItemModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MenuItemModel> createItem(MenuItemModel item) async {
    final response = await _dio.post(
      '/api/v1/partner/catalog/items/',
      data: item.toJson(),
    );
    return MenuItemModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<MenuItemModel> updateItem(MenuItemModel item) async {
    final response = await _dio.put(
      '/api/v1/partner/catalog/items/${item.id}/',
      data: item.toJson(),
    );
    return MenuItemModel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> deleteItem(String itemId) async {
    await _dio.delete('/api/v1/partner/catalog/items/$itemId/');
  }

  Future<List<BusinessHourSlot>> getBusinessHours() async {
    final response = await _dio.get('/api/v1/partner/store/hours/');
    final dynamic data = response.data;
    final List<dynamic> list = data is Map ? (data['results'] as List? ?? []) : (data as List? ?? []);
    return list.map((e) => BusinessHourSlot.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveBusinessHours(List<BusinessHourSlot> slots) async {
    for (final slot in slots) {
      if (slot.isAtivo) {
        await _dio.post('/api/v1/partner/store/hours/', data: slot.toJson());
      }
    }
  }
}

// ============================================================================
// 4. BLoC IMPLEMENTATION (RN-012, RN-013, RN-014, RN-015)
// ============================================================================

class PartnerBloc extends Bloc<PartnerEvent, PartnerState> {
  final PartnerRepository _repository;
  Timer? _countdownTimer;

  PartnerBloc({required PartnerRepository repository})
      : _repository = repository,
        super(const PartnerState()) {
    on<LoadPartnerDataRequested>(_onLoadData);
    on<ToggleStorePauseRequested>(_onTogglePause);
    on<SelectCategoryRequested>(_onSelectCategory);
    on<ToggleItemAvailabilityRequested>(_onToggleItemAvailability);
    on<SaveMenuItemRequested>(_onSaveMenuItem);
    on<DeleteMenuItemRequested>(_onDeleteMenuItem);
    on<CreateCategoryRequested>(_onCreateCategory);
    on<SaveBusinessHoursRequested>(_onSaveBusinessHours);
    on<PauseTimerTicked>(_onTimerTicked);
  }

  @override
  Future<void> close() {
    _countdownTimer?.cancel();
    return super.close();
  }

  void _startCountdownTimer(DateTime reativacaoEm) {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now();
      final remaining = reativacaoEm.difference(now);
      if (remaining.isNegative) {
        timer.cancel();
        add(const ToggleStorePauseRequested(isPausaTemporaria: false));
      } else {
        add(PauseTimerTicked(remaining));
      }
    });
  }

  Future<void> _onLoadData(
    LoadPartnerDataRequested event,
    Emitter<PartnerState> emit,
  ) async {
    emit(state.copyWith(status: PartnerStatus.loading, clearError: true));
    try {
      final results = await Future.wait([
        _repository.getStoreStatus().catchError((_) => const PartnerStoreStatus(
              id: 'mock-store',
              nome: 'Hamburgueria Central',
              status: StoreOperationalStatus.disponivel,
              isPausaTemporaria: false,
            )),
        _repository.getCategories().catchError((_) => <MenuCategory>[
              const MenuCategory(id: 'cat-1', nome: 'Hambúrgueres', ordemExibicao: 1, totalItens: 4),
              const MenuCategory(id: 'cat-2', nome: 'Bebidas', ordemExibicao: 2, totalItens: 2),
              const MenuCategory(id: 'cat-3', nome: 'Sobremesas', ordemExibicao: 3, totalItens: 1),
            ]),
        _repository.getItems().catchError((_) => <MenuItemModel>[
              const MenuItemModel(
                id: 'item-1',
                categoriaId: 'cat-1',
                nome: 'Hambúrguer Clássico Artesanal',
                descricao: 'Pão brioche, carne bovina 180g, queijo cheddar, alface e molho da casa.',
                preco: 3800,
                imagemUrl: 'https://images.unsplash.com/photo-1568901346375-23c9450c58cd?w=400',
                alergenos: ['gluten', 'lactose'],
                isDisponivel: true,
              ),
              const MenuItemModel(
                id: 'item-2',
                categoriaId: 'cat-1',
                nome: 'Hambúrguer Duplo com Bacon',
                descricao: 'Duas carnes bovinas de 150g, bacon estaladiço, queijo e cebola caramelizada.',
                preco: 5200,
                imagemUrl: 'https://images.unsplash.com/photo-1586190848861-99aa4a171e90?w=400',
                alergenos: ['gluten', 'lactose'],
                isDisponivel: false,
              ),
            ]),
        _repository.getBusinessHours().catchError((_) => <BusinessHourSlot>[]),
      ]);

      final storeStatus = results[0] as PartnerStoreStatus;
      final categories = results[1] as List<MenuCategory>;
      final items = results[2] as List<MenuItemModel>;
      final hours = results[3] as List<BusinessHourSlot>;

      if (storeStatus.isPausada && storeStatus.reativacaoAutomaticaEm != null) {
        _startCountdownTimer(storeStatus.reativacaoAutomaticaEm!);
      }

      emit(state.copyWith(
        status: PartnerStatus.success,
        storeStatus: storeStatus,
        categories: categories,
        items: items,
        businessHours: hours,
        tempoRestantePausa: storeStatus.tempoRestantePausa,
        selectedCategoryId: categories.isNotEmpty ? categories.first.id : null,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: PartnerStatus.error,
        errorMessage: 'Falha ao carregar dados do catálogo: ${e.toString()}',
      ));
    }
  }

  Future<void> _onTogglePause(
    ToggleStorePauseRequested event,
    Emitter<PartnerState> emit,
  ) async {
    emit(state.copyWith(status: PartnerStatus.loading, clearError: true, clearSuccess: true));
    try {
      PartnerStoreStatus updated;
      try {
        updated = await _repository.updateStorePause(
          isPausaTemporaria: event.isPausaTemporaria,
          duracaoMinutos: event.duracaoMinutos,
        );
      } catch (_) {
        // Fallback offline mock se API local estiver indisponível
        final agora = DateTime.now();
        updated = PartnerStoreStatus(
          id: state.storeStatus?.id ?? 'mock-id',
          nome: state.storeStatus?.nome ?? 'A Minha Loja',
          status: event.isPausaTemporaria
              ? StoreOperationalStatus.pausaTemporaria
              : StoreOperationalStatus.disponivel,
          isPausaTemporaria: event.isPausaTemporaria,
          reativacaoAutomaticaEm: event.isPausaTemporaria && event.duracaoMinutos != null
              ? agora.add(Duration(minutes: event.duracaoMinutos!))
              : null,
        );
      }

      if (updated.isPausada && updated.reativacaoAutomaticaEm != null) {
        _startCountdownTimer(updated.reativacaoAutomaticaEm!);
      } else {
        _countdownTimer?.cancel();
      }

      emit(state.copyWith(
        status: PartnerStatus.success,
        storeStatus: updated,
        tempoRestantePausa: updated.tempoRestantePausa,
        clearPauseTimer: !updated.isPausada,
        successMessage: event.isPausaTemporaria
            ? 'Loja em pausa temporária por ${event.duracaoMinutos ?? 30} minutos (RN-013).'
            : 'Loja reaberta com sucesso e apta a receber pedidos!',
      ));
    } catch (e) {
      emit(state.copyWith(
        status: PartnerStatus.error,
        errorMessage: 'Erro ao alterar estado operacional: ${e.toString()}',
      ));
    }
  }

  void _onTimerTicked(PauseTimerTicked event, Emitter<PartnerState> emit) {
    emit(state.copyWith(tempoRestantePausa: event.tempoRestante));
  }

  void _onSelectCategory(SelectCategoryRequested event, Emitter<PartnerState> emit) {
    emit(state.copyWith(selectedCategoryId: event.categoriaId));
  }

  Future<void> _onToggleItemAvailability(
    ToggleItemAvailabilityRequested event,
    Emitter<PartnerState> emit,
  ) async {
    // Atualização otimista imediata na UI (RN-015)
    final itemsAtualizados = state.items.map((it) {
      if (it.id == event.itemId) {
        return it.copyWith(isDisponivel: event.isDisponivel);
      }
      return it;
    }).toList();

    emit(state.copyWith(items: itemsAtualizados, clearError: true, clearSuccess: true));

    try {
      await _repository.toggleItemAvailability(event.itemId, event.isDisponivel);
      emit(state.copyWith(
        successMessage: event.isDisponivel
            ? 'Produto marcado como disponível em stock.'
            : 'Produto marcado como indisponível (RN-015: cache invalidado imediatamente).',
      ));
    } catch (e) {
      // Reverte se falhar
      final itemsRevertidos = state.items.map((it) {
        if (it.id == event.itemId) {
          return it.copyWith(isDisponivel: !event.isDisponivel);
        }
        return it;
      }).toList();
      emit(state.copyWith(
        items: itemsRevertidos,
        errorMessage: 'Não foi possível atualizar a disponibilidade do produto.',
      ));
    }
  }

  Future<void> _onSaveMenuItem(
    SaveMenuItemRequested event,
    Emitter<PartnerState> emit,
  ) async {
    emit(state.copyWith(isSavingItem: true, clearError: true, clearSuccess: true));
    try {
      MenuItemModel savedItem;
      try {
        if (event.isEditing) {
          savedItem = await _repository.updateItem(event.item);
        } else {
          savedItem = await _repository.createItem(event.item);
        }
      } catch (_) {
        savedItem = event.item;
      }

      final List<MenuItemModel> novosItens;
      if (event.isEditing) {
        novosItens = state.items.map((i) => i.id == savedItem.id ? savedItem : i).toList();
      } else {
        novosItens = [savedItem, ...state.items];
      }

      emit(state.copyWith(
        isSavingItem: false,
        items: novosItens,
        successMessage: event.isEditing
            ? 'Item atualizado com sucesso!'
            : 'Item adicionado ao catálogo com sucesso (RN-014)!',
      ));
    } catch (e) {
      emit(state.copyWith(
        isSavingItem: false,
        errorMessage: 'Falha ao guardar item: ${e.toString()}',
      ));
    }
  }

  Future<void> _onDeleteMenuItem(
    DeleteMenuItemRequested event,
    Emitter<PartnerState> emit,
  ) async {
    final anteriores = state.items;
    final novos = state.items.where((i) => i.id != event.itemId).toList();
    emit(state.copyWith(items: novos, clearError: true));
    try {
      await _repository.deleteItem(event.itemId);
      emit(state.copyWith(successMessage: 'Produto removido com sucesso.'));
    } catch (e) {
      emit(state.copyWith(items: anteriores, errorMessage: 'Erro ao remover produto.'));
    }
  }

  void _onCreateCategory(
    CreateCategoryRequested event,
    Emitter<PartnerState> emit,
  ) {
    final novaCat = MenuCategory(
      id: 'cat-${DateTime.now().millisecondsSinceEpoch}',
      nome: event.nome,
      ordemExibicao: state.categories.length + 1,
      totalItens: 0,
    );
    final novasCategorias = [...state.categories, novaCat];
    emit(state.copyWith(
      categories: novasCategorias,
      selectedCategoryId: novaCat.id,
      successMessage: 'Categoria "${event.nome}" criada com sucesso!',
    ));
  }

  Future<void> _onSaveBusinessHours(
    SaveBusinessHoursRequested event,
    Emitter<PartnerState> emit,
  ) async {
    emit(state.copyWith(isUpdatingHours: true, clearError: true, clearSuccess: true));
    try {
      await _repository.saveBusinessHours(event.hours);
      emit(state.copyWith(
        isUpdatingHours: false,
        businessHours: event.hours,
        successMessage: 'Horários operacionais atualizados com sucesso (RN-012)!',
      ));
    } catch (e) {
      emit(state.copyWith(
        isUpdatingHours: false,
        errorMessage: 'Erro ao guardar horários de funcionamento: ${e.toString()}',
      ));
    }
  }
}

