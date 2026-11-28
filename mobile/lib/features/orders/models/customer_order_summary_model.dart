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

/// Modelo de resumo e detalhes completos de pedido para apresentação na área de pedidos do cliente.
class CustomerOrderSummaryModel extends Equatable {
  final String id;
  final String lojaId;
  final String lojaNome;
  final String lojaMorada;
  final String lojaContacto;
  final String lojaScore;
  final String lojaImagem;
  final double lojaLat;
  final double lojaLng;
  final String estado;
  final String estadoDisplay;
  final int subtotalCentimos;
  final int taxaEntregaCentimos;
  final int taxaServicoCentimos;
  final int gorjetaCentimos;
  final int descontosCentimos;
  final int totalCobradoCentimos;
  final String pinEntrega;
  final String moradaEntrega;
  final String moradaReferencia;
  final String moradaAndarPorta;
  final String moradaInstrucoes;
  final double clienteLat;
  final double clienteLng;
  final String metodoPagamentoDisplay;
  final bool estafetaAtribuido;
  final String estafetaNome;
  final String estafetaTelemovel;
  final String estafetaEmail;
  final String estafetaTipoVeiculo;
  final String estafetaMarcaModelo;
  final String estafetaMatricula;
  final String estafetaScore;
  final String estafetaEtapaDisplay;
  final double distanciaKm;
  final int etaMinutos;
  final List<String> itensNomes;
  final List<CustomerOrderLineItem> linhas;
  final DateTime dataCriacao;

  const CustomerOrderSummaryModel({
    required this.id,
    this.lojaId = '',
    required this.lojaNome,
    this.lojaMorada = 'Luanda, Angola',
    this.lojaContacto = '+244 923 000 000',
    this.lojaScore = '5.00',
    required this.lojaImagem,
    this.lojaLat = -8.8368,
    this.lojaLng = 13.2343,
    required this.estado,
    required this.estadoDisplay,
    this.subtotalCentimos = 0,
    this.taxaEntregaCentimos = 0,
    this.taxaServicoCentimos = 0,
    this.gorjetaCentimos = 0,
    this.descontosCentimos = 0,
    required this.totalCobradoCentimos,
    this.pinEntrega = '4829',
    this.moradaEntrega = 'Luanda, Angola',
    this.moradaReferencia = '',
    this.moradaAndarPorta = '',
    this.moradaInstrucoes = '',
    this.clienteLat = -8.8147,
    this.clienteLng = 13.2343,
    this.metodoPagamentoDisplay = 'Carteira Digital',
    this.estafetaAtribuido = false,
    this.estafetaNome = '',
    this.estafetaTelemovel = '',
    this.estafetaEmail = '',
    this.estafetaTipoVeiculo = 'Mota',
    this.estafetaMarcaModelo = '',
    this.estafetaMatricula = '',
    this.estafetaScore = '4.95',
    this.estafetaEtapaDisplay = '',
    this.distanciaKm = 2.5,
    this.etaMinutos = 12,
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
    final lojaDet = (json['loja_detalhes'] as Map<String, dynamic>?) ?? {};
    final moradaDet = (json['morada_detalhes'] as Map<String, dynamic>?) ?? {};
    final estafetaDet =
        (json['estafeta_detalhes'] as Map<String, dynamic>?) ?? {};

    final extractedLojaId = (lojaDet['id'] ?? '').toString().isNotEmpty
        ? lojaDet['id'].toString()
        : (rawLoja is Map<String, dynamic>
            ? (rawLoja['id'] ?? '').toString()
            : (rawLoja ?? json['loja_id'] ?? '').toString());

    return CustomerOrderSummaryModel(
      id: (json['id'] ?? '').toString(),
      lojaId: extractedLojaId,
      lojaNome: (json['loja_nome'] ??
              lojaDet['nome'] ??
              (rawLoja is Map<String, dynamic> ? rawLoja['nome'] : null) ??
              'Restaurante Parceiro')
          .toString(),
      lojaMorada: (lojaDet['morada'] ?? 'Luanda, Angola').toString(),
      lojaContacto: (lojaDet['contacto'] ?? '+244 923 000 000').toString(),
      lojaScore: (lojaDet['score_reputacao'] ?? '5.00').toString(),
      lojaImagem: (json['loja_imagem'] ??
              (rawLoja is Map<String, dynamic> ? rawLoja['imagem'] : null) ??
              '')
          .toString(),
      lojaLat: (lojaDet['latitude'] as num?)?.toDouble() ?? -8.8368,
      lojaLng: (lojaDet['longitude'] as num?)?.toDouble() ?? 13.2343,
      estado: (json['estado'] ?? 'CRIADO').toString(),
      estadoDisplay:
          (json['estado_display'] ?? json['estado'] ?? 'Processamento')
              .toString(),
      subtotalCentimos: (json['subtotal'] as num?)?.toInt() ?? 0,
      taxaEntregaCentimos: (json['taxa_entrega'] as num?)?.toInt() ?? 0,
      taxaServicoCentimos: (json['taxa_servico'] as num?)?.toInt() ?? 0,
      gorjetaCentimos: (json['gorjeta_estafeta'] as num?)?.toInt() ?? 0,
      descontosCentimos: (json['descontos'] as num?)?.toInt() ?? 0,
      totalCobradoCentimos: (json['total_cobrado'] as num?)?.toInt() ?? 0,
      pinEntrega: (json['pin_entrega'] ?? '4829').toString(),
      moradaEntrega: (json['morada_entrega'] ??
              moradaDet['texto_endereco'] ??
              'Luanda, Angola')
          .toString(),
      moradaReferencia: (moradaDet['referencia'] ?? '').toString(),
      moradaAndarPorta: (moradaDet['andar_porta'] ?? '').toString(),
      moradaInstrucoes: (moradaDet['instrucoes_estafeta'] ?? '').toString(),
      clienteLat: (moradaDet['latitude'] as num?)?.toDouble() ?? -8.8147,
      clienteLng: (moradaDet['longitude'] as num?)?.toDouble() ?? 13.2343,
      metodoPagamentoDisplay: (json['metodo_pagamento_display'] ??
              json['metodo_pagamento'] ??
              'Carteira Digital')
          .toString(),
      estafetaAtribuido: estafetaDet['atribuido'] == true,
      estafetaNome: (estafetaDet['nome'] ?? '').toString(),
      estafetaTelemovel: (estafetaDet['telemovel'] ?? '').toString(),
      estafetaEmail: (estafetaDet['email'] ?? '').toString(),
      estafetaTipoVeiculo:
          (estafetaDet['tipo_veiculo_display'] ?? estafetaDet['tipo_veiculo'] ?? 'Mota')
              .toString(),
      estafetaMarcaModelo:
          (estafetaDet['marca_modelo_veiculo'] ?? 'Haojue 125').toString(),
      estafetaMatricula:
          (estafetaDet['matricula_veiculo'] ?? 'LD-44-99-AF').toString(),
      estafetaScore: (estafetaDet['score_reputacao'] ?? '4.95').toString(),
      estafetaEtapaDisplay: (estafetaDet['etapa_display'] ?? '').toString(),
      distanciaKm: (estafetaDet['distancia_km'] as num?)?.toDouble() ?? 2.5,
      etaMinutos: (estafetaDet['eta_minutos'] as num?)?.toInt() ?? 12,
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
        lojaMorada,
        lojaContacto,
        lojaImagem,
        estado,
        estadoDisplay,
        subtotalCentimos,
        taxaEntregaCentimos,
        taxaServicoCentimos,
        gorjetaCentimos,
        descontosCentimos,
        totalCobradoCentimos,
        pinEntrega,
        moradaEntrega,
        moradaReferencia,
        metodoPagamentoDisplay,
        estafetaAtribuido,
        estafetaNome,
        estafetaTelemovel,
        estafetaMatricula,
        estafetaEtapaDisplay,
        itensNomes,
        linhas,
        dataCriacao,
      ];
}

