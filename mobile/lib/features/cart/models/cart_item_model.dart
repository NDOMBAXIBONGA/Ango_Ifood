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
  final List<String> opcoesNomes;
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
    this.opcoesNomes = const [],
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
    List<String>? opcoesNomes,
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
      opcoesNomes: opcoesNomes ?? this.opcoesNomes,
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
        opcoesNomes,
        notas,
      ];
}

