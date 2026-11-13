import 'package:equatable/equatable.dart';

/// Item individual de uma linha de pedido no histórico do cliente.
class CustomerOrderLineItem extends Equatable {
  final String itemId;
  final String nome;
  final int quantidade;
  final int precoUnitarioCentimos;
  final String notas;
  final List<String> opcoesIds;
  final List<String> opcoesNomes;

  const CustomerOrderLineItem({
    required this.itemId,
    required this.nome,
    required this.quantidade,
    required this.precoUnitarioCentimos,
    this.notas = '',
    this.opcoesIds = const [],
    this.opcoesNomes = const [],
  });

  factory CustomerOrderLineItem.fromJson(Map<String, dynamic> json) {
    final rawOpcoes =
        (json['opcoes_selecionadas'] ?? json['opcoes']) as List<dynamic>? ??
            const [];
    final parsedOpcoesIds = <String>[];
    final parsedOpcoesNomes = <String>[];
    for (final raw in rawOpcoes) {
      if (raw is Map<String, dynamic>) {
        final id = (raw['opcao'] ?? raw['opcao_id'] ?? raw['id'] ?? '')
            .toString()
            .trim();
        final nome =
            (raw['opcao_nome'] ?? raw['nome'] ?? '').toString().trim();
        if (id.isNotEmpty) parsedOpcoesIds.add(id);
        if (nome.isNotEmpty) parsedOpcoesNomes.add(nome);
      } else if (raw != null) {
        final id = raw.toString().trim();
        if (id.isNotEmpty) parsedOpcoesIds.add(id);
      }
    }

    return CustomerOrderLineItem(
      itemId: (json['item'] ?? json['item_id'] ?? '').toString(),
      nome: (json['item_nome'] ?? json['nome'] ?? 'Artigo').toString(),
      quantidade: (json['quantidade'] as num?)?.toInt() ?? 1,
      precoUnitarioCentimos:
          (json['preco_unitario_no_momento'] as num?)?.toInt() ?? 0,
      notas: (json['notas'] ?? '').toString(),
      opcoesIds: parsedOpcoesIds,
      opcoesNomes: parsedOpcoesNomes,
    );
  }

  @override
  List<Object?> get props => [
        itemId,
        nome,
        quantidade,
        precoUnitarioCentimos,
        notas,
        opcoesIds,
        opcoesNomes,
      ];
}

/// Modelo de resumo de pedido para apresentação no histórico do cliente.
class CustomerOrderSummaryModel extends Equatable {
  final String id;
  final String lojaId;
  final String lojaNome;
  final String lojaImagem;
  final String estado;
  final String estadoDisplay;
  final int totalCobradoCentimos;
  final String pinEntrega;
  final String moradaEntrega;
  final String metodoPagamentoDisplay;
  final List<String> itensNomes;
  final List<CustomerOrderLineItem> linhas;
  final DateTime dataCriacao;

  const CustomerOrderSummaryModel({
    required this.id,
    this.lojaId = '',
    required this.lojaNome,
    required this.lojaImagem,
    required this.estado,
    required this.estadoDisplay,
    required this.totalCobradoCentimos,
    this.pinEntrega = '4829',
    this.moradaEntrega = 'Luanda, Angola',
    this.metodoPagamentoDisplay = 'Carteira Digital',
    required this.itensNomes,
    this.linhas = const [],
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

  bool get podeCancelar {
    final s = estado.toUpperCase();
    return s == 'CRIADO' || s == 'PAGAMENTO' || s == 'AGUARDA_PARCEIRO';
  }

  int get etapaProgresso {
    final s = estado.toUpperCase();
    if (s == 'CRIADO' || s == 'PAGAMENTO' || s == 'AGUARDA_PARCEIRO') {
      return 1;
    }
    if (s == 'ACEITE' || s == 'EM_PREPARACAO') {
      return 2;
    }
    if (s == 'PRONTO' ||
        s == 'AGUARDA_ESTAFETA' ||
        s == 'RECOLHIDO' ||
        s == 'EM_ENTREGA' ||
        s == 'EM_TRANSITO') {
      return 3;
    }
    return 4;
  }

  factory CustomerOrderSummaryModel.fromJson(Map<String, dynamic> json) {
    final rawLinhas = json['linhas'] as List<dynamic>? ?? const [];
    final parsedLinhas = rawLinhas
        .whereType<Map<String, dynamic>>()
        .map(CustomerOrderLineItem.fromJson)
        .toList();
    final itens = parsedLinhas
        .map((l) => '${l.quantidade}x ${l.nome}')
        .where((n) => n.isNotEmpty)
        .toList();

    final rawLoja = json['loja'];
    final extractedLojaId = rawLoja is Map<String, dynamic>
        ? (rawLoja['id'] ?? '').toString()
        : (rawLoja ?? json['loja_id'] ?? '').toString();

    return CustomerOrderSummaryModel(
      id: (json['id'] ?? '').toString(),
      lojaId: extractedLojaId,
      lojaNome: (json['loja_nome'] ??
              (rawLoja is Map<String, dynamic> ? rawLoja['nome'] : null) ??
              'Restaurante Parceiro')
          .toString(),
      lojaImagem: (json['loja_imagem'] ??
              (rawLoja is Map<String, dynamic> ? rawLoja['imagem'] : null) ??
              '')
          .toString(),
      estado: (json['estado'] ?? 'CRIADO').toString(),
      estadoDisplay:
          (json['estado_display'] ?? json['estado'] ?? 'Processamento')
              .toString(),
      totalCobradoCentimos: (json['total_cobrado'] as num?)?.toInt() ?? 0,
      pinEntrega: (json['pin_entrega'] ?? '4829').toString(),
      moradaEntrega: (json['morada_entrega'] ?? 'Luanda, Angola').toString(),
      metodoPagamentoDisplay: (json['metodo_pagamento_display'] ??
              json['metodo_pagamento'] ??
              'Carteira Digital')
          .toString(),
      itensNomes: itens,
      linhas: parsedLinhas,
      dataCriacao: json['data_criacao'] != null
          ? DateTime.tryParse(json['data_criacao'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        lojaId,
        lojaNome,
        lojaImagem,
        estado,
        estadoDisplay,
        totalCobradoCentimos,
        pinEntrega,
        moradaEntrega,
        metodoPagamentoDisplay,
        itensNomes,
        linhas,
        dataCriacao,
      ];
}

