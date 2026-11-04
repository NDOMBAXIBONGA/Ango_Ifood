import 'package:equatable/equatable.dart';

/// Modelo de resumo de pedido para apresentação no histórico do cliente.
class CustomerOrderSummaryModel extends Equatable {
  final String id;
  final String lojaNome;
  final String lojaImagem;
  final String estado;
  final String estadoDisplay;
  final int totalCobradoCentimos;
  final List<String> itensNomes;
  final DateTime dataCriacao;

  const CustomerOrderSummaryModel({
    required this.id,
    required this.lojaNome,
    required this.lojaImagem,
    required this.estado,
    required this.estadoDisplay,
    required this.totalCobradoCentimos,
    required this.itensNomes,
    required this.dataCriacao,
  });

  bool get isAtivo {
    final s = estado.toUpperCase();
    return s != 'CONCLUIDO' &&
        s != 'ENTREGUE' &&
        s != 'CANCELADO' &&
        s != 'REJEITADO' &&
        s != 'FALHA_ENTREGA' &&
        s != 'REEMBOLSADO';
  }

  factory CustomerOrderSummaryModel.fromJson(Map<String, dynamic> json) {
    final linhas = json['linhas'] as List<dynamic>? ?? [];
    final itens = linhas.map((l) => (l['item_nome'] ?? l['nome'] ?? '').toString()).where((n) => n.isNotEmpty).toList();

    return CustomerOrderSummaryModel(
      id: (json['id'] ?? '').toString(),
      lojaNome: (json['loja_nome'] ?? json['loja']?['nome'] ?? 'Restaurante Parceiro').toString(),
      lojaImagem: (json['loja_imagem'] ?? json['loja']?['imagem'] ?? '').toString(),
      estado: (json['estado'] ?? 'CRIADO').toString(),
      estadoDisplay: (json['estado_display'] ?? json['estado'] ?? 'Processamento').toString(),
      totalCobradoCentimos: (json['total_cobrado'] as num?)?.toInt() ?? 0,
      itensNomes: itens,
      dataCriacao: json['data_criacao'] != null
          ? DateTime.tryParse(json['data_criacao'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        lojaNome,
        lojaImagem,
        estado,
        estadoDisplay,
        totalCobradoCentimos,
        itensNomes,
        dataCriacao,
      ];
}

