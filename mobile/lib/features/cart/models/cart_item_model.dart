import 'package:equatable/equatable.dart';

/// Modelo de item no carrinho de compras do cliente.
class CartItemModel extends Equatable {
  final String itemId;
  final String lojaId;
  final String lojaNome;
  final String nome;
  final String imagemUrl;
  final int precoUnitarioCentimos;
  final int quantidade;
  final List<String> opcoesIds;
  final String notas;

  const CartItemModel({
    required this.itemId,
    required this.lojaId,
    required this.lojaNome,
    required this.nome,
    required this.imagemUrl,
    required this.precoUnitarioCentimos,
    this.quantidade = 1,
    this.opcoesIds = const [],
    this.notas = '',
  });

  int get subtotalCentimos => precoUnitarioCentimos * quantidade;

  CartItemModel copyWith({
    String? itemId,
    String? lojaId,
    String? lojaNome,
    String? nome,
    String? imagemUrl,
    int? precoUnitarioCentimos,
    int? quantidade,
    List<String>? opcoesIds,
    String? notas,
  }) {
    return CartItemModel(
      itemId: itemId ?? this.itemId,
      lojaId: lojaId ?? this.lojaId,
      lojaNome: lojaNome ?? this.lojaNome,
      nome: nome ?? this.nome,
      imagemUrl: imagemUrl ?? this.imagemUrl,
      precoUnitarioCentimos:
          precoUnitarioCentimos ?? this.precoUnitarioCentimos,
      quantidade: quantidade ?? this.quantidade,
      opcoesIds: opcoesIds ?? this.opcoesIds,
      notas: notas ?? this.notas,
    );
  }

  @override
  List<Object?> get props => [
        itemId,
        lojaId,
        lojaNome,
        nome,
        imagemUrl,
        precoUnitarioCentimos,
        quantidade,
        opcoesIds,
        notas,
      ];
}

