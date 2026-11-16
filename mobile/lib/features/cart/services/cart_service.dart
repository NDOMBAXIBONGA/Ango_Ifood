import 'package:flutter/foundation.dart';

import '../../checkout/checkout_screen.dart';
import '../models/cart_item_model.dart';

/// Serviço reativo de gestão de estado do carrinho de compras do cliente (Singleton).
/// Permite sincronizar os itens selecionados em `StoreMenuScreen`, visualizá-los
/// no `CartScreen` e enviá-los diretamente para o `CheckoutScreen`.
class CartService extends ChangeNotifier {
  static final CartService instance = CartService._internal();

  CartService._internal();

  String? _lojaId;
  String? _lojaNome;
  final Map<String, CartItemModel> _items = {};

  // Estado partilhado de Morada ativa do Cliente (RN-005, RN-025)
  String _moradaId = 'morada_principal';
  String _moradaLabel = 'Centro de Luanda';
  String _moradaTexto = 'Centro de Luanda, Ingombota, Luanda';
  String _moradaReferencia = 'Próximo à Marginal de Luanda';
  double _latitude = -8.8147;
  double _longitude = 13.2343;

  // Preferência de pagamento do Cliente (RN-065)
  String _preferredPaymentCode = 'CARTEIRA_DIGITAL';
  String _preferredMcxPhone = '+244 923 000 000';

  String? get lojaId => _lojaId;
  String? get lojaNome => _lojaNome;
  String get moradaId => _moradaId;
  String get moradaLabel => _moradaLabel;
  String get moradaTexto => _moradaTexto;
  String get moradaReferencia => _moradaReferencia;
  double get latitude => _latitude;
  double get longitude => _longitude;
  String get preferredPaymentCode => _preferredPaymentCode;
  String get metodoPagamentoPreferido => _preferredPaymentCode;
  String get preferredMcxPhone => _preferredMcxPhone;

  List<CartItemModel> get items => _items.values.toList();
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;

  /// RN-040: Verifica se já existem itens no carrinho pertencentes a outra loja.
  bool hasStoreConflict(String targetLojaId) =>
      _lojaId != null && _lojaId != targetLojaId && _items.isNotEmpty;

  void updateActiveAddress({
    required String id,
    required String label,
    required String fullAddress,
    String referencia = '',
    required double latitude,
    required double longitude,
  }) {
    _moradaId = id.isNotEmpty ? id : 'morada_principal';
    _moradaLabel = label.isNotEmpty ? label : 'Morada de Entrega';
    _moradaTexto = fullAddress;
    _moradaReferencia = referencia;
    _latitude = latitude;
    _longitude = longitude;
    notifyListeners();
  }

  void updatePreferredPayment({
    required String paymentCode,
    String? mcxPhone,
  }) {
    _preferredPaymentCode = paymentCode;
    if (mcxPhone != null) {
      _preferredMcxPhone = mcxPhone;
    }
    notifyListeners();
  }

  int get totalItemsCount =>
      _items.values.fold(0, (sum, item) => sum + item.quantidade);

  int get totalSubtotalCentimos =>
      _items.values.fold(0, (sum, item) => sum + item.subtotalCentimos);

  int get subtotalCentimos => totalSubtotalCentimos;

  int getQuantity(String itemId) => _items[itemId]?.quantidade ?? 0;

  /// Adiciona um item ao carrinho. Se o item pertencer a uma loja diferente,
  /// o carrinho anterior é substituído de acordo com a regra de unicidade de loja (RN-040).
  void addItem({
    required String itemId,
    required String lojaId,
    required String lojaNome,
    required String nome,
    required String imagemUrl,
    required int precoUnitarioCentimos,
    int quantidade = 1,
    List<String> opcoesIds = const [],
    List<String> opcoesNomes = const [],
    String notas = '',
  }) {
    if (_lojaId != null && _lojaId != lojaId) {
      _items.clear();
    }
    _lojaId = lojaId;
    _lojaNome = lojaNome;

    if (_items.containsKey(itemId)) {
      final existing = _items[itemId]!;
      _items[itemId] = existing.copyWith(
        quantidade: existing.quantidade + quantidade,
        precoUnitarioCentimos: precoUnitarioCentimos,
        opcoesIds: opcoesIds.isNotEmpty ? opcoesIds : existing.opcoesIds,
        opcoesNomes: opcoesNomes.isNotEmpty ? opcoesNomes : existing.opcoesNomes,
        notas: notas.isNotEmpty ? notas : existing.notas,
      );
    } else {
      _items[itemId] = CartItemModel(
        itemId: itemId,
        lojaId: lojaId,
        lojaNome: lojaNome,
        nome: nome,
        imagemUrl: imagemUrl,
        precoUnitarioCentimos: precoUnitarioCentimos,
        quantidade: quantidade,
        opcoesIds: opcoesIds,
        opcoesNomes: opcoesNomes,
        notas: notas,
      );
    }
    notifyListeners();
  }

  /// Incrementa ou decrementa a quantidade de um item.
  /// Se a quantidade atingir 0, o item é removido do carrinho.
  void updateQuantity(String itemId, int delta) {
    if (!_items.containsKey(itemId)) return;

    final existing = _items[itemId]!;
    final novaQuantidade = existing.quantidade + delta;

    if (novaQuantidade <= 0) {
      _items.remove(itemId);
      if (_items.isEmpty) {
        _lojaId = null;
        _lojaNome = null;
      }
    } else {
      _items[itemId] = existing.copyWith(quantidade: novaQuantidade);
    }
    notifyListeners();
  }

  /// Remove completamente um item do carrinho.
  void removeItem(String itemId) {
    if (_items.containsKey(itemId)) {
      _items.remove(itemId);
      if (_items.isEmpty) {
        _lojaId = null;
        _lojaNome = null;
      }
      notifyListeners();
    }
  }

  /// Limpa todos os itens do carrinho e desvincula a loja ativa.
  void clear() {
    _items.clear();
    _lojaId = null;
    _lojaNome = null;
    notifyListeners();
  }

  void clearCart() => clear();

  /// Converte os itens do carrinho para a lista esperada pelo `CheckoutScreen`.
  List<CheckoutCartItemInput> toCheckoutInputs() {
    return _items.values.map((item) {
      return CheckoutCartItemInput(
        itemId: item.itemId,
        nome: item.nome,
        imagemUrl: item.imagemUrl,
        quantidade: item.quantidade,
        opcoesIds: item.opcoesIds,
        notas: item.notas,
      );
    }).toList();
  }
}

