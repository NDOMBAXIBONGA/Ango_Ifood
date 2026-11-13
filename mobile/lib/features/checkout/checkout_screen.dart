/// Ecrã de Checkout (`CheckoutScreen`) e Arquitetura de Estado (`flutter_bloc` + `dio`)
/// em Material Design 3 para a aplicação Mobile do Cliente.
///
/// Implementa rigorosamente as Secções 4, 5.1, 6.4, 6.5 e as Regras de Negócio:
/// - RN-040 a RN-045: Exibição de itens da loja única, opções personalizadas, notas,
///   taxa de pequeno pedido (RN-041) e timer visual regressivo de 15 minutos da cotação (RN-043).
/// - RN-050: Decomposição financeira transparente:
///   `Total = Subtotal + Taxa de Entrega + Taxa de Serviço + Taxa de Pequeno Pedido + Gorjeta - Descontos`.
/// - RN-051 / RN-052: Exibição da taxa de entrega com aviso explícito quando o Preço Dinâmico
///   (Surge Pricing) está ativo na zona.
/// - RN-055 / RN-056: Validação em tempo real de cupões de desconto via `/api/v1/orders/checkout/preview/`.
/// - RN-058: Seletor interativo de gorjeta para o estafeta (100% revertida ao estafeta).
/// - RN-059: Todos os valores monetários processados em unidades mínimas inteiras (Cêntimos/Kwanza).
/// - RN-065: Seletor de Meio de Pagamento (Cartão, Carteira Digital, Dinheiro/Numerário).

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/network/app_environment_config.dart';
import '../auth/storage/secure_token_storage.dart';
import '../cart/cart.dart';
import '../catalog/customer_catalog_screens.dart';
import '../tracking/order_real_time_tracking_screen.dart';

// ============================================================================
// 1. UTILITÁRIO DE FORMATAÇÃO MONETÁRIA INTEIRA (RN-059)
// ============================================================================

/// Formata valores inteiros em unidades mínimas (cêntimos: 100 unidades = 1,00 Kz)
/// sem recorrer a aritmética de vírgula flutuante imprecisa (RN-059).
class CurrencyFormatter {
  const CurrencyFormatter._();

  static String formatKwanza(int unidadesMinimas, {bool showZeroDecimals = false}) {
    final isNegativo = unidadesMinimas < 0;
    final valorAbs = unidadesMinimas.abs();
    final parteInteira = valorAbs ~/ 100;
    final centimos = valorAbs % 100;

    final strInteira = parteInteira.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (Match m) => '${m[1]}.',
        );

    final prefixo = isNegativo ? '-' : '';
    if (centimos == 0 && !showZeroDecimals) {
      return '$prefixo$strInteira Kz';
    }
    final strCentimos = centimos.toString().padLeft(2, '0');
    return '$prefixo$strInteira,$strCentimos Kz';
  }
}

// ============================================================================
// 2. MODELOS DE DADOS DO CHECKOUT E COTAÇÃO (Secções 5.1, 6.4, 6.5, RN-050)
// ============================================================================

/// Meios de pagamento disponíveis no Checkout (RN-065).
enum PaymentMethodType {
  cartao(
    id: 'CARTAO',
    titulo: 'Cartão Bancário',
    subtitulo: 'Débito ou Crédito (Visa, Mastercard, Multicaixa)',
    icone: Icons.credit_card_rounded,
  ),
  carteiraDigital(
    id: 'CARTEIRA_DIGITAL',
    titulo: 'Carteira Digital',
    subtitulo: 'Pagamento instantâneo via Mobile Money / Express',
    icone: Icons.account_balance_wallet_rounded,
  ),
  dinheiro(
    id: 'NUMERARIO',
    titulo: 'Dinheiro na Entrega',
    subtitulo: 'Pagamento em numerário diretamente ao estafeta',
    icone: Icons.payments_rounded,
  );

  final String id;
  final String titulo;
  final String subtitulo;
  final IconData icone;

  const PaymentMethodType({
    required this.id,
    required this.titulo,
    required this.subtitulo,
    required this.icone,
  });
}

/// Item do carrinho enviado como input para `/api/v1/orders/checkout/preview/`.
@immutable
class CheckoutCartItemInput extends Equatable {
  final String itemId;
  final String nome;
  final String imagemUrl;
  final int quantidade;
  final List<String> opcoesIds;
  final String notas;

  const CheckoutCartItemInput({
    required this.itemId,
    required this.nome,
    required this.imagemUrl,
    required this.quantidade,
    this.opcoesIds = const [],
    this.notas = '',
  });

  Map<String, dynamic> toJson() => {
        'item_id': itemId,
        'quantidade': quantidade,
        'opcoes': opcoesIds,
        if (notas.trim().isNotEmpty) 'notas': notas.trim(),
      };

  @override
  List<Object?> get props => [itemId, nome, imagemUrl, quantidade, opcoesIds, notas];
}

/// Opção personalizada de uma linha devolvida na cotação (RN-014, RN-020).
@immutable
class CheckoutLineOptionModel extends Equatable {
  final String opcaoId;
  final String grupoNome;
  final String nome;
  final int precoNoMomento;

  const CheckoutLineOptionModel({
    required this.opcaoId,
    required this.grupoNome,
    required this.nome,
    required this.precoNoMomento,
  });

  factory CheckoutLineOptionModel.fromJson(Map<String, dynamic> json) {
    return CheckoutLineOptionModel(
      opcaoId: (json['opcao_id'] ?? json['id'] ?? '').toString(),
      grupoNome: (json['grupo_nome'] ?? '').toString(),
      nome: (json['nome'] ?? json['opcao_nome'] ?? '').toString(),
      precoNoMomento: (json['preco_no_momento'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  List<Object?> get props => [opcaoId, grupoNome, nome, precoNoMomento];
}

/// Linha de produto cotada no checkout com preço unitário congelado (RN-016, RN-042, RN-045).
@immutable
class CheckoutLineItemModel extends Equatable {
  final String itemId;
  final String nome;
  final String imagemUrl;
  final int quantidade;
  final int precoUnitarioBase;
  final int precoOpcoesUnitario;
  final int precoUnitarioNoMomento;
  final int subtotalLinha;
  final List<CheckoutLineOptionModel> opcoes;
  final String notas;

  const CheckoutLineItemModel({
    required this.itemId,
    required this.nome,
    required this.imagemUrl,
    required this.quantidade,
    required this.precoUnitarioBase,
    required this.precoOpcoesUnitario,
    required this.precoUnitarioNoMomento,
    required this.subtotalLinha,
    required this.opcoes,
    required this.notas,
  });

  factory CheckoutLineItemModel.fromJson(
    Map<String, dynamic> json, {
    String fallbackImageUrl =
        'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400',
  }) {
    final opcoesRaw = (json['opcoes'] as List<dynamic>?) ?? const [];
    return CheckoutLineItemModel(
      itemId: (json['item_id'] ?? '').toString(),
      nome: (json['nome'] ?? 'Artigo').toString(),
      imagemUrl: (json['imagem_url'] as String?)?.isNotEmpty == true
          ? json['imagem_url'] as String
          : fallbackImageUrl,
      quantidade: (json['quantidade'] as num?)?.toInt() ?? 1,
      precoUnitarioBase: (json['preco_unitario_base'] as num?)?.toInt() ?? 0,
      precoOpcoesUnitario: (json['preco_opcoes_unitario'] as num?)?.toInt() ?? 0,
      precoUnitarioNoMomento:
          (json['preco_unitario_no_momento'] as num?)?.toInt() ?? 0,
      subtotalLinha: (json['subtotal_linha'] as num?)?.toInt() ?? 0,
      opcoes: opcoesRaw
          .whereType<Map<String, dynamic>>()
          .map(CheckoutLineOptionModel.fromJson)
          .toList(),
      notas: (json['notas'] ?? '').toString(),
    );
  }

  @override
  List<Object?> get props => [
        itemId,
        nome,
        imagemUrl,
        quantidade,
        precoUnitarioBase,
        precoOpcoesUnitario,
        precoUnitarioNoMomento,
        subtotalLinha,
        opcoes,
        notas,
      ];
}

/// Metadados da taxa de entrega e Preço Dinâmico (RN-051, RN-052).
@immutable
class CheckoutDeliveryDetailsModel extends Equatable {
  final int distanciaMetros;
  final String distanciaKm;
  final int baseTaxa;
  final int precoPorKm;
  final int taxaSemPrecoDinamico;
  final String fatorPrecoDinamico;
  final bool isPrecoDinamicoAtivo;

  const CheckoutDeliveryDetailsModel({
    required this.distanciaMetros,
    required this.distanciaKm,
    required this.baseTaxa,
    required this.precoPorKm,
    required this.taxaSemPrecoDinamico,
    required this.fatorPrecoDinamico,
    required this.isPrecoDinamicoAtivo,
  });

  factory CheckoutDeliveryDetailsModel.fromJson(Map<String, dynamic> json) {
    return CheckoutDeliveryDetailsModel(
      distanciaMetros: (json['distancia_metros'] as num?)?.toInt() ?? 0,
      distanciaKm: (json['distancia_km'] ?? '0.00').toString(),
      baseTaxa: (json['base_taxa'] as num?)?.toInt() ?? 0,
      precoPorKm: (json['preco_por_km'] as num?)?.toInt() ?? 0,
      taxaSemPrecoDinamico:
          (json['taxa_entrega_sem_preco_dinamico'] as num?)?.toInt() ?? 0,
      fatorPrecoDinamico: (json['fator_preco_dinamico'] ?? '1.00').toString(),
      isPrecoDinamicoAtivo: (json['is_preco_dinamico_ativo'] as bool?) ?? false,
    );
  }

  @override
  List<Object?> get props => [
        distanciaMetros,
        distanciaKm,
        baseTaxa,
        precoPorKm,
        taxaSemPrecoDinamico,
        fatorPrecoDinamico,
        isPrecoDinamicoAtivo,
      ];
}

/// Detalhes do cupão validado na cotação (RN-055, RN-056).
@immutable
class CheckoutCouponDetailsModel extends Equatable {
  final String cupaoId;
  final String codigo;
  final String tipoDesconto;
  final int valorConfigurado;
  final int descontoAplicado;
  final String financiador;

  const CheckoutCouponDetailsModel({
    required this.cupaoId,
    required this.codigo,
    required this.tipoDesconto,
    required this.valorConfigurado,
    required this.descontoAplicado,
    required this.financiador,
  });

  factory CheckoutCouponDetailsModel.fromJson(Map<String, dynamic> json) {
    return CheckoutCouponDetailsModel(
      cupaoId: (json['cupao_id'] ?? '').toString(),
      codigo: (json['codigo'] ?? '').toString(),
      tipoDesconto: (json['tipo_desconto'] ?? 'FIXO').toString(),
      valorConfigurado: (json['valor_configurado'] as num?)?.toInt() ?? 0,
      descontoAplicado: (json['desconto_aplicado'] as num?)?.toInt() ?? 0,
      financiador: (json['financiador'] ?? 'PLATAFORMA').toString(),
    );
  }

  @override
  List<Object?> get props => [
        cupaoId,
        codigo,
        tipoDesconto,
        valorConfigurado,
        descontoAplicado,
        financiador,
      ];
}

/// Modelo completo da cotação devolvida por `POST /api/v1/orders/checkout/preview/` (RN-043, RN-050).
@immutable
class CheckoutQuoteModel extends Equatable {
  final String idCotacao;
  final String lojaId;
  final String lojaNome;
  final String moradaId;
  final String moradaTexto;
  final int subtotal;
  final int taxaEntrega;
  final int taxaServico;
  final int taxaPequenoPedido;
  final int gorjetaEstafeta;
  final int descontos;
  final int totalCobrado;
  final CheckoutDeliveryDetailsModel detalhesEntrega;
  final CheckoutCouponDetailsModel? cupao;
  final List<CheckoutLineItemModel> itens;
  final DateTime expiraEm;
  final int ttlSegundos;

  const CheckoutQuoteModel({
    required this.idCotacao,
    required this.lojaId,
    required this.lojaNome,
    required this.moradaId,
    required this.moradaTexto,
    required this.subtotal,
    required this.taxaEntrega,
    required this.taxaServico,
    required this.taxaPequenoPedido,
    required this.gorjetaEstafeta,
    required this.descontos,
    required this.totalCobrado,
    required this.detalhesEntrega,
    this.cupao,
    required this.itens,
    required this.expiraEm,
    required this.ttlSegundos,
  });

  /// RN-050: Verifica que o total obedece estritamente à fórmula linear:
  /// Total = Subtotal + Taxa de Entrega + Taxa de Serviço + Taxa Pequeno Pedido + Gorjeta - Descontos
  int get totalCalculadoFormulaRn050 {
    final soma = subtotal +
        taxaEntrega +
        taxaServico +
        taxaPequenoPedido +
        gorjetaEstafeta -
        descontos;
    return soma < 0 ? 0 : soma;
  }

  factory CheckoutQuoteModel.fromJson(
    Map<String, dynamic> json, {
    Map<String, String> itemImagesById = const {},
  }) {
    final resumo = (json['resumo_precos'] as Map<String, dynamic>?) ?? json;
    final entregaMap =
        (json['detalhes_entrega'] as Map<String, dynamic>?) ?? const {};
    final cupaoMap = json['cupao'] as Map<String, dynamic>?;
    final itensList = (json['itens'] as List<dynamic>?) ?? const [];

    final expiraStr = (json['expira_em'] ?? '').toString();
    final expiraDate = DateTime.tryParse(expiraStr) ??
        DateTime.now().add(const Duration(minutes: 15));

    return CheckoutQuoteModel(
      idCotacao: (json['id_cotacao'] ?? json['cotacao_id'] ?? '').toString(),
      lojaId: (json['loja_id'] ?? '').toString(),
      lojaNome: (json['loja_nome'] ?? 'Loja Parceira').toString(),
      moradaId: (json['morada_id'] ?? '').toString(),
      moradaTexto: (json['morada_texto'] ?? '').toString(),
      subtotal: (resumo['subtotal'] as num?)?.toInt() ?? 0,
      taxaEntrega: (resumo['taxa_entrega'] as num?)?.toInt() ?? 0,
      taxaServico: (resumo['taxa_servico'] as num?)?.toInt() ?? 0,
      taxaPequenoPedido: (resumo['taxa_pequeno_pedido'] as num?)?.toInt() ?? 0,
      gorjetaEstafeta: (resumo['gorjeta_estafeta'] as num?)?.toInt() ?? 0,
      descontos: (resumo['descontos'] as num?)?.toInt() ?? 0,
      totalCobrado: (resumo['total_cobrado'] as num?)?.toInt() ?? 0,
      detalhesEntrega: CheckoutDeliveryDetailsModel.fromJson(entregaMap),
      cupao: cupaoMap != null
          ? CheckoutCouponDetailsModel.fromJson(cupaoMap)
          : null,
      itens: itensList.whereType<Map<String, dynamic>>().map((itemJson) {
        final itemId = (itemJson['item_id'] ?? '').toString();
        return CheckoutLineItemModel.fromJson(
          itemJson,
          fallbackImageUrl: itemImagesById[itemId] ??
              'https://images.unsplash.com/photo-1546069901-ba9599a7e63c?w=400',
        );
      }).toList(),
      expiraEm: expiraDate,
      ttlSegundos: (json['ttl_segundos'] as num?)?.toInt() ?? 900,
    );
  }

  @override
  List<Object?> get props => [
        idCotacao,
        lojaId,
        lojaNome,
        moradaId,
        moradaTexto,
        subtotal,
        taxaEntrega,
        taxaServico,
        taxaPequenoPedido,
        gorjetaEstafeta,
        descontos,
        totalCobrado,
        detalhesEntrega,
        cupao,
        itens,
        expiraEm,
        ttlSegundos,
      ];
}

/// Resposta da confirmação do pedido `POST /api/v1/orders/checkout/confirm/` (Secção 5.1).
@immutable
class ConfirmedOrderResult extends Equatable {
  final String pedidoId;
  final String estado;
  final String estadoDisplay;
  final String metodoPagamento;
  final int totalCobrado;
  final String eventoGerado;
  final String pinEntrega;

  const ConfirmedOrderResult({
    required this.pedidoId,
    required this.estado,
    required this.estadoDisplay,
    required this.metodoPagamento,
    required this.totalCobrado,
    required this.eventoGerado,
    this.pinEntrega = '4829',
  });

  factory ConfirmedOrderResult.fromJson(Map<String, dynamic> json) {
    final pedidoMap = (json['pedido'] as Map<String, dynamic>?) ?? json;
    return ConfirmedOrderResult(
      pedidoId: (pedidoMap['id'] ?? '').toString(),
      estado: (pedidoMap['estado'] ?? 'PAGAMENTO').toString(),
      estadoDisplay:
          (pedidoMap['estado_display'] ?? '2. Pagamento (Autorizado/Capturado)')
              .toString(),
      metodoPagamento: (pedidoMap['metodo_pagamento'] ?? '').toString(),
      totalCobrado: (pedidoMap['total_cobrado'] as num?)?.toInt() ?? 0,
      eventoGerado: (json['evento_gerado'] ?? 'order.created').toString(),
      pinEntrega: (pedidoMap['pin_entrega'] ?? '4829').toString(),
    );
  }

  @override
  List<Object?> get props => [
        pedidoId,
        estado,
        estadoDisplay,
        metodoPagamento,
        totalCobrado,
        eventoGerado,
        pinEntrega,
      ];
}

// ============================================================================
// 3. REPOSITÓRIO DE CHECKOUT COM DIO (`/preview/` e `/confirm/`)
// ============================================================================

class CheckoutRepositoryException implements Exception {
  final String message;
  final String? ruleCode;

  const CheckoutRepositoryException(this.message, {this.ruleCode});

  @override
  String toString() => message;
}

class CheckoutRepository {
  final Dio _dio;

  CheckoutRepository({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: AppEnvironmentConfig.baseHttpUrl,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                headers: const {
                  'Content-Type': 'application/json',
                  'Accept': 'application/json',
                },
              ),
            );

  Future<Options> _buildAuthOptions() async {
    final token = await SecureTokenStorage().getAccessToken();
    return Options(
      headers: {
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      },
    );
  }

  /// Executa `POST /api/v1/orders/checkout/preview/` para calcular/recalcular a cotação
  /// em unidades mínimas inteiras e obter um `id_cotacao` válido por 15 minutos em Redis (RN-043).
  Future<CheckoutQuoteModel> previewCheckout({
    required String lojaId,
    required String moradaId,
    required List<CheckoutCartItemInput> itens,
    required int gorjetaEstafeta,
    String? cupaoCodigo,
  }) async {
    final imageMap = {
      for (final item in itens) item.itemId: item.imagemUrl,
    };

    try {
      final authOptions = await _buildAuthOptions();
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/orders/checkout/preview/',
        options: authOptions,
        data: {
          'loja_id': lojaId,
          'morada_id': moradaId.isEmpty ? 'morada_principal' : moradaId,
          'itens': itens.map((e) => e.toJson()).toList(),
          'gorjeta_estafeta': gorjetaEstafeta,
          if (cupaoCodigo != null && cupaoCodigo.trim().isNotEmpty)
            'cupao_codigo': cupaoCodigo.trim().toUpperCase(),
        },
      );

      final data = response.data;
      if (data == null) {
        throw const CheckoutRepositoryException(
          'Resposta vazia ao calcular a cotação do checkout.',
        );
      }
      return CheckoutQuoteModel.fromJson(data, itemImagesById: imageMap);
    } on DioException catch (e) {
      throw _parseDioException(e);
    }
  }

  /// Executa `POST /api/v1/orders/checkout/confirm/` enviando `id_cotacao` e `metodo_pagamento_id`.
  /// Cria o Pedido em `1. CRIADO`, persiste as linhas, limpa o carrinho e avança para `2. PAGAMENTO`
  /// com emissão do evento `order.created` (Secção 5.1, RN-043).
  Future<ConfirmedOrderResult> confirmCheckout({
    required String idCotacao,
    required String metodoPagamentoId,
  }) async {
    try {
      final authOptions = await _buildAuthOptions();
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/v1/orders/checkout/confirm/',
        options: authOptions,
        data: {
          'id_cotacao': idCotacao,
          'metodo_pagamento_id': metodoPagamentoId,
        },
      );

      final data = response.data;
      if (data == null) {
        throw const CheckoutRepositoryException(
          'Resposta inválida ao confirmar o pedido.',
        );
      }
      return ConfirmedOrderResult.fromJson(data);
    } on DioException catch (e) {
      throw _parseDioException(e);
    }
  }

  CheckoutRepositoryException _parseDioException(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final erroMsg = data['erro'] ?? data['detail'] ?? data['mensagem'];
      final codigoRegra = data['codigo_regra']?.toString();
      if (erroMsg != null) {
        return CheckoutRepositoryException(
          erroMsg.toString(),
          ruleCode: codigoRegra,
        );
      }
      if (data.values.isNotEmpty) {
        final firstVal = data.values.first;
        if (firstVal is List && firstVal.isNotEmpty) {
          return CheckoutRepositoryException(firstVal.first.toString());
        }
        return CheckoutRepositoryException(firstVal.toString());
      }
    }
    return const CheckoutRepositoryException(
      'Não foi possível comunicar com o servidor. Verifique a sua ligação.',
    );
  }
}

// ============================================================================
// 4. EVENTOS, ESTADOS E BLOC DO CHECKOUT (`flutter_bloc`)
// ============================================================================

abstract class CheckoutEvent extends Equatable {
  const CheckoutEvent();

  @override
  List<Object?> get props => [];
}

/// Carrega ou recalcula a cotação inicial do carrinho (`POST /preview/`).
class LoadCheckoutPreviewEvent extends CheckoutEvent {
  const LoadCheckoutPreviewEvent();
}

/// Atualiza a gorjeta atribuída ao estafeta (RN-058) e recalcula a cotação no servidor.
class UpdateCourierTipEvent extends CheckoutEvent {
  final int gorjetaUnidadesMinimas;

  const UpdateCourierTipEvent(this.gorjetaUnidadesMinimas);

  @override
  List<Object?> get props => [gorjetaUnidadesMinimas];
}

/// Aplica e valida um código de cupão de desconto em tempo real (RN-055, RN-056).
class ApplyCouponRealtimeEvent extends CheckoutEvent {
  final String codigoCupao;

  const ApplyCouponRealtimeEvent(this.codigoCupao);

  @override
  List<Object?> get props => [codigoCupao];
}

/// Remove o cupão de desconto atualmente aplicado e recalcula a cotação.
class RemoveCouponEvent extends CheckoutEvent {
  const RemoveCouponEvent();
}

/// Seleciona o Meio de Pagamento (Cartão, Carteira Digital, Dinheiro - RN-065).
class SelectPaymentMethodEvent extends CheckoutEvent {
  final PaymentMethodType metodoPagamento;

  const SelectPaymentMethodEvent(this.metodoPagamento);

  @override
  List<Object?> get props => [metodoPagamento];
}

/// Notifica que o timer regressivo de 15 minutos da cotação expirou (RN-043).
class QuoteTimerExpiredEvent extends CheckoutEvent {
  const QuoteTimerExpiredEvent();
}

/// Confirma e submete o pagamento do pedido (`POST /confirm/`).
class ConfirmAndPayOrderEvent extends CheckoutEvent {
  const ConfirmAndPayOrderEvent();
}

/// Atualiza a morada de entrega diretamente no ecrã de Checkout e recalcula a cotação.
class ChangeCheckoutAddressEvent extends CheckoutEvent {
  final String moradaId;
  final String moradaLabel;
  final String moradaTexto;

  const ChangeCheckoutAddressEvent({
    required this.moradaId,
    required this.moradaLabel,
    required this.moradaTexto,
  });

  @override
  List<Object?> get props => [moradaId, moradaLabel, moradaTexto];
}

@immutable
class CheckoutState extends Equatable {
  final String lojaId;
  final String lojaNome;
  final String moradaId;
  final String moradaLabel;
  final String moradaTexto;
  final List<CheckoutCartItemInput> itensInput;
  final CheckoutQuoteModel? cotacao;
  final int gorjetaSelecionada;
  final String? cupaoAplicado;
  final PaymentMethodType metodoPagamentoSelecionado;
  final bool isLoadingPreview;
  final bool isValidatingCoupon;
  final bool isSubmittingOrder;
  final bool isQuoteExpired;
  final String? couponErrorMessage;
  final String? generalErrorMessage;
  final ConfirmedOrderResult? pedidoConfirmado;

  const CheckoutState({
    required this.lojaId,
    required this.lojaNome,
    required this.moradaId,
    required this.moradaLabel,
    required this.moradaTexto,
    required this.itensInput,
    this.cotacao,
    this.gorjetaSelecionada = 0,
    this.cupaoAplicado,
    this.metodoPagamentoSelecionado = PaymentMethodType.cartao,
    this.isLoadingPreview = false,
    this.isValidatingCoupon = false,
    this.isSubmittingOrder = false,
    this.isQuoteExpired = false,
    this.couponErrorMessage,
    this.generalErrorMessage,
    this.pedidoConfirmado,
  });

  CheckoutState copyWith({
    String? moradaId,
    String? moradaLabel,
    String? moradaTexto,
    CheckoutQuoteModel? cotacao,
    int? gorjetaSelecionada,
    String? cupaoAplicado,
    bool clearCupaoAplicado = false,
    PaymentMethodType? metodoPagamentoSelecionado,
    bool? isLoadingPreview,
    bool? isValidatingCoupon,
    bool? isSubmittingOrder,
    bool? isQuoteExpired,
    String? couponErrorMessage,
    bool clearCouponError = false,
    String? generalErrorMessage,
    bool clearGeneralError = false,
    ConfirmedOrderResult? pedidoConfirmado,
  }) {
    return CheckoutState(
      lojaId: lojaId,
      lojaNome: lojaNome,
      moradaId: moradaId ?? this.moradaId,
      moradaLabel: moradaLabel ?? this.moradaLabel,
      moradaTexto: moradaTexto ?? this.moradaTexto,
      itensInput: itensInput,
      cotacao: cotacao ?? this.cotacao,
      gorjetaSelecionada: gorjetaSelecionada ?? this.gorjetaSelecionada,
      cupaoAplicado:
          clearCupaoAplicado ? null : (cupaoAplicado ?? this.cupaoAplicado),
      metodoPagamentoSelecionado:
          metodoPagamentoSelecionado ?? this.metodoPagamentoSelecionado,
      isLoadingPreview: isLoadingPreview ?? this.isLoadingPreview,
      isValidatingCoupon: isValidatingCoupon ?? this.isValidatingCoupon,
      isSubmittingOrder: isSubmittingOrder ?? this.isSubmittingOrder,
      isQuoteExpired: isQuoteExpired ?? this.isQuoteExpired,
      couponErrorMessage: clearCouponError
          ? null
          : (couponErrorMessage ?? this.couponErrorMessage),
      generalErrorMessage: clearGeneralError
          ? null
          : (generalErrorMessage ?? this.generalErrorMessage),
      pedidoConfirmado: pedidoConfirmado ?? this.pedidoConfirmado,
    );
  }

  @override
  List<Object?> get props => [
        lojaId,
        lojaNome,
        moradaId,
        moradaLabel,
        moradaTexto,
        itensInput,
        cotacao,
        gorjetaSelecionada,
        cupaoAplicado,
        metodoPagamentoSelecionado,
        isLoadingPreview,
        isValidatingCoupon,
        isSubmittingOrder,
        isQuoteExpired,
        couponErrorMessage,
        generalErrorMessage,
        pedidoConfirmado,
      ];
}

class CheckoutBloc extends Bloc<CheckoutEvent, CheckoutState> {
  final CheckoutRepository _repository;

  CheckoutBloc({
    required CheckoutRepository repository,
    required CheckoutState initialState,
  })  : _repository = repository,
        super(initialState) {
    on<LoadCheckoutPreviewEvent>(_onLoadPreview);
    on<UpdateCourierTipEvent>(_onUpdateTip);
    on<ApplyCouponRealtimeEvent>(_onApplyCoupon);
    on<RemoveCouponEvent>(_onRemoveCoupon);
    on<SelectPaymentMethodEvent>(_onSelectPaymentMethod);
    on<QuoteTimerExpiredEvent>(_onQuoteTimerExpired);
    on<ConfirmAndPayOrderEvent>(_onConfirmAndPay);
    on<ChangeCheckoutAddressEvent>(_onChangeAddress);
  }

  Future<void> _onChangeAddress(
    ChangeCheckoutAddressEvent event,
    Emitter<CheckoutState> emit,
  ) async {
    emit(
      state.copyWith(
        moradaId: event.moradaId,
        moradaLabel: event.moradaLabel,
        moradaTexto: event.moradaTexto,
      ),
    );
    await _onLoadPreview(const LoadCheckoutPreviewEvent(), emit);
  }

  Future<void> _onLoadPreview(
    LoadCheckoutPreviewEvent event,
    Emitter<CheckoutState> emit,
  ) async {
    emit(
      state.copyWith(
        isLoadingPreview: true,
        isQuoteExpired: false,
        clearGeneralError: true,
      ),
    );

    try {
      final quote = await _repository.previewCheckout(
        lojaId: state.lojaId,
        moradaId: state.moradaId,
        itens: state.itensInput,
        gorjetaEstafeta: state.gorjetaSelecionada,
        cupaoCodigo: state.cupaoAplicado,
      );

      emit(
        state.copyWith(
          cotacao: quote,
          isLoadingPreview: false,
          isQuoteExpired: false,
          clearGeneralError: true,
        ),
      );
    } on CheckoutRepositoryException catch (e) {
      emit(
        state.copyWith(
          isLoadingPreview: false,
          generalErrorMessage: e.message,
        ),
      );
    }
  }

  Future<void> _onUpdateTip(
    UpdateCourierTipEvent event,
    Emitter<CheckoutState> emit,
  ) async {
    final novaGorjeta = event.gorjetaUnidadesMinimas < 0
        ? 0
        : event.gorjetaUnidadesMinimas;

    emit(
      state.copyWith(
        gorjetaSelecionada: novaGorjeta,
        isLoadingPreview: true,
        clearGeneralError: true,
      ),
    );

    try {
      final quote = await _repository.previewCheckout(
        lojaId: state.lojaId,
        moradaId: state.moradaId,
        itens: state.itensInput,
        gorjetaEstafeta: novaGorjeta,
        cupaoCodigo: state.cupaoAplicado,
      );

      emit(
        state.copyWith(
          cotacao: quote,
          isLoadingPreview: false,
          isQuoteExpired: false,
        ),
      );
    } on CheckoutRepositoryException catch (e) {
      emit(
        state.copyWith(
          isLoadingPreview: false,
          generalErrorMessage: e.message,
        ),
      );
    }
  }

  Future<void> _onApplyCoupon(
    ApplyCouponRealtimeEvent event,
    Emitter<CheckoutState> emit,
  ) async {
    final codigo = event.codigoCupao.trim().toUpperCase();
    if (codigo.isEmpty) {
      emit(
        state.copyWith(
          couponErrorMessage: 'Introduza um código de cupão válido.',
        ),
      );
      return;
    }

    emit(
      state.copyWith(
        isValidatingCoupon: true,
        clearCouponError: true,
        clearGeneralError: true,
      ),
    );

    try {
      final quote = await _repository.previewCheckout(
        lojaId: state.lojaId,
        moradaId: state.moradaId,
        itens: state.itensInput,
        gorjetaEstafeta: state.gorjetaSelecionada,
        cupaoCodigo: codigo,
      );

      emit(
        state.copyWith(
          cotacao: quote,
          cupaoAplicado: codigo,
          isValidatingCoupon: false,
          isQuoteExpired: false,
          clearCouponError: true,
        ),
      );
    } on CheckoutRepositoryException catch (e) {
      emit(
        state.copyWith(
          isValidatingCoupon: false,
          couponErrorMessage: e.message,
        ),
      );
    }
  }

  Future<void> _onRemoveCoupon(
    RemoveCouponEvent event,
    Emitter<CheckoutState> emit,
  ) async {
    emit(
      state.copyWith(
        clearCupaoAplicado: true,
        clearCouponError: true,
        isValidatingCoupon: true,
      ),
    );

    try {
      final quote = await _repository.previewCheckout(
        lojaId: state.lojaId,
        moradaId: state.moradaId,
        itens: state.itensInput,
        gorjetaEstafeta: state.gorjetaSelecionada,
        cupaoCodigo: null,
      );

      emit(
        state.copyWith(
          cotacao: quote,
          isValidatingCoupon: false,
          isQuoteExpired: false,
        ),
      );
    } on CheckoutRepositoryException catch (e) {
      emit(
        state.copyWith(
          isValidatingCoupon: false,
          generalErrorMessage: e.message,
        ),
      );
    }
  }

  void _onSelectPaymentMethod(
    SelectPaymentMethodEvent event,
    Emitter<CheckoutState> emit,
  ) {
    emit(
      state.copyWith(
        metodoPagamentoSelecionado: event.metodoPagamento,
        clearGeneralError: true,
      ),
    );
  }

  void _onQuoteTimerExpired(
    QuoteTimerExpiredEvent event,
    Emitter<CheckoutState> emit,
  ) {
    emit(
      state.copyWith(
        isQuoteExpired: true,
        generalErrorMessage:
            'RN-043: A cotação de preços expirou após 15 minutos. Recalcule a cotação para atualizar as taxas.',
      ),
    );
  }

  Future<void> _onConfirmAndPay(
    ConfirmAndPayOrderEvent event,
    Emitter<CheckoutState> emit,
  ) async {
    final cotacaoAtual = state.cotacao;
    if (cotacaoAtual == null || state.isQuoteExpired) {
      emit(
        state.copyWith(
          generalErrorMessage:
              'RN-043: A cotação expirou. Toque em "Recalcular Cotação" antes de confirmar.',
        ),
      );
      return;
    }

    emit(
      state.copyWith(
        isSubmittingOrder: true,
        clearGeneralError: true,
      ),
    );

    try {
      final resultado = await _repository.confirmCheckout(
        idCotacao: cotacaoAtual.idCotacao,
        metodoPagamentoId: state.metodoPagamentoSelecionado.id,
      );

      emit(
        state.copyWith(
          isSubmittingOrder: false,
          pedidoConfirmado: resultado,
        ),
      );
    } on CheckoutRepositoryException catch (e) {
      final isExpiredRule = e.ruleCode == 'RN-043';
      emit(
        state.copyWith(
          isSubmittingOrder: false,
          isQuoteExpired: isExpiredRule ? true : state.isQuoteExpired,
          generalErrorMessage: e.message,
        ),
      );
    }
  }
}

// ============================================================================
// 5. ECRÃ PRINCIPAL DE CHECKOUT EM MATERIAL DESIGN 3 (`CheckoutScreen`)
// ============================================================================

class CheckoutScreen extends StatefulWidget {
  final String lojaId;
  final String lojaNome;
  final String moradaId;
  final String moradaLabel;
  final String moradaTexto;
  final List<CheckoutCartItemInput> itensCarrinho;
  final CheckoutQuoteModel? cotacaoInicial;
  final CheckoutRepository? repository;
  final VoidCallback? onChangeAddressTap;

  const CheckoutScreen({
    super.key,
    required this.lojaId,
    required this.lojaNome,
    required this.moradaId,
    this.moradaLabel = 'Casa / Entrega Principal',
    required this.moradaTexto,
    required this.itensCarrinho,
    this.cotacaoInicial,
    this.repository,
    this.onChangeAddressTap,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  late final CheckoutBloc _checkoutBloc;
  final TextEditingController _couponController = TextEditingController();

  Timer? _countdownTimer;
  Duration _remainingTime = const Duration(minutes: 15);

  @override
  void initState() {
    super.initState();
    _checkoutBloc = CheckoutBloc(
      repository: widget.repository ?? CheckoutRepository(),
      initialState: CheckoutState(
        lojaId: widget.lojaId,
        lojaNome: widget.lojaNome,
        moradaId: widget.moradaId,
        moradaLabel: widget.moradaLabel,
        moradaTexto: widget.moradaTexto,
        itensInput: widget.itensCarrinho,
        cotacao: widget.cotacaoInicial,
      ),
    );

    if (widget.cotacaoInicial != null) {
      _startQuoteTimer(widget.cotacaoInicial!.expiraEm);
    } else {
      _checkoutBloc.add(const LoadCheckoutPreviewEvent());
    }
  }

  /// RN-043: Inicia ou reinicia o timer visual regressivo de 15 minutos baseado
  /// na data/hora de expiração (`expiraEm`) da cotação na cache Redis.
  void _startQuoteTimer(DateTime expiraEm) {
    _countdownTimer?.cancel();

    void updateRemaining() {
      final diff = expiraEm.difference(DateTime.now());
      if (!mounted) return;

      if (diff.isNegative || diff.inSeconds <= 0) {
        setState(() {
          _remainingTime = Duration.zero;
        });
        _countdownTimer?.cancel();
        _checkoutBloc.add(const QuoteTimerExpiredEvent());
      } else {
        setState(() {
          _remainingTime = diff;
        });
      }
    }

    updateRemaining();
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => updateRemaining(),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _couponController.dispose();
    _checkoutBloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocProvider.value(
      value: _checkoutBloc,
      child: BlocConsumer<CheckoutBloc, CheckoutState>(
        listenWhen: (previous, current) =>
            previous.cotacao?.idCotacao != current.cotacao?.idCotacao ||
            previous.pedidoConfirmado != current.pedidoConfirmado ||
            (previous.generalErrorMessage != current.generalErrorMessage &&
                current.generalErrorMessage != null),
        listener: (context, state) {
          // Sempre que uma nova cotação é gerada, reinicia o timer de 15 minutos (RN-043)
          if (state.cotacao != null && !state.isQuoteExpired) {
            _startQuoteTimer(state.cotacao!.expiraEm);
          }

          // Quando o pedido é confirmado e avança para '2. PAGAMENTO' (evento order.created)
          if (state.pedidoConfirmado != null) {
            _showOrderConfirmedSheet(context, state.pedidoConfirmado!);
          } else if (state.generalErrorMessage != null) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: colorScheme.errorContainer,
                  content: Text(
                    state.generalErrorMessage!,
                    style: TextStyle(color: colorScheme.onErrorContainer),
                  ),
                ),
              );
          }
        },
        builder: (context, state) {
          final cotacao = state.cotacao;

          return Scaffold(
            backgroundColor: colorScheme.surfaceContainerLowest,
            appBar: AppBar(
              centerTitle: false,
              title: const Text(
                'Finalizar Pedido',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              actions: [
                // Pill do Timer Regressivo de 15 Minutos no topo da AppBar (RN-043)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _QuoteCountdownBadge(
                    remaining: _remainingTime,
                    isExpired: state.isQuoteExpired,
                    onRefreshTap: () => _checkoutBloc.add(
                      const LoadCheckoutPreviewEvent(),
                    ),
                  ),
                ),
              ],
            ),
            body: state.isLoadingPreview && cotacao == null
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () async {
                      _checkoutBloc.add(const LoadCheckoutPreviewEvent());
                    },
                    child: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // Banner de aviso caso a cotação de 15 minutos tenha expirado (RN-043)
                        if (state.isQuoteExpired)
                          SliverToBoxAdapter(
                            child: _QuoteExpiredAlertBanner(
                              onRecalculate: () => _checkoutBloc.add(
                                const LoadCheckoutPreviewEvent(),
                              ),
                            ),
                          ),

                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate([
                              // ------------------------------------------------
                              // BLOCO 1: CABEÇALHO COM NOME DA LOJA E MORADA DE ENTREGA
                              // ------------------------------------------------
                              _StoreAndAddressHeaderCard(
                                lojaNome: cotacao?.lojaNome ?? state.lojaNome,
                                moradaLabel: state.moradaLabel,
                                moradaTexto:
                                    cotacao?.moradaTexto ?? state.moradaTexto,
                                distanciaKm:
                                    cotacao?.detalhesEntrega.distanciaKm,
                                onChangeAddressTap: widget.onChangeAddressTap ??
                                    () {
                                      showCustomerAddressSelectionSheet(
                                        context,
                                        onAddressSelected: (newAddr) {
                                          _checkoutBloc.add(
                                            ChangeCheckoutAddressEvent(
                                              moradaId: newAddr.id,
                                              moradaLabel: newAddr.label,
                                              moradaTexto: newAddr.fullAddress,
                                            ),
                                          );
                                        },
                                      );
                                    },
                              ),
                              const SizedBox(height: 16),

                              // ------------------------------------------------
                              // BLOCO 2: LISTA DE ITENS COM IMAGEM, QUANTIDADE E OPÇÕES
                              // ------------------------------------------------
                              _CartItemsSectionCard(
                                itensCotados: cotacao?.itens ?? const [],
                                itensFallback: state.itensInput,
                              ),
                              const SizedBox(height: 16),

                              // ------------------------------------------------
                              // BLOCO 3: CAMPO DE CUPÃO DE DESCONTO EM TEMPO REAL (RN-056)
                              // ------------------------------------------------
                              _CouponRealtimeSectionCard(
                                controller: _couponController,
                                cupaoAplicado: cotacao?.cupao,
                                isValidating: state.isValidatingCoupon,
                                errorMessage: state.couponErrorMessage,
                                onApplyCoupon: (codigo) {
                                  _checkoutBloc.add(
                                    ApplyCouponRealtimeEvent(codigo),
                                  );
                                },
                                onRemoveCoupon: () {
                                  _couponController.clear();
                                  _checkoutBloc.add(const RemoveCouponEvent());
                                },
                              ),
                              const SizedBox(height: 16),

                              // ------------------------------------------------
                              // BLOCO 4: RESUMO FINANCEIRO DETALHADO + GORJETA (RN-050 a RN-058)
                              // ------------------------------------------------
                              if (cotacao != null) ...[
                                _FinancialSummaryAndTipCard(
                                  cotacao: cotacao,
                                  gorjetaSelecionada: state.gorjetaSelecionada,
                                  isRecalculating: state.isLoadingPreview,
                                  onSelectTip: (valorGorjeta) {
                                    _checkoutBloc.add(
                                      UpdateCourierTipEvent(valorGorjeta),
                                    );
                                  },
                                ),
                                const SizedBox(height: 16),
                              ],

                              // ------------------------------------------------
                              // BLOCO 5: SELETOR DE MEIO DE PAGAMENTO (RN-065)
                              // ------------------------------------------------
                              _PaymentMethodSelectorCard(
                                selecionado: state.metodoPagamentoSelecionado,
                                onChanged: (metodo) {
                                  _checkoutBloc.add(
                                    SelectPaymentMethodEvent(metodo),
                                  );
                                },
                              ),
                            ]),
                          ),
                        ),
                      ],
                    ),
                  ),

            // ------------------------------------------------------------------
            // BLOCO 6: BOTÃO FLUTUANTE "CONFIRMAR E PAGAR" + TIMER RN-043
            // ------------------------------------------------------------------
            bottomNavigationBar: _FloatingConfirmAndPayBar(
              cotacao: cotacao,
              remainingTime: _remainingTime,
              isQuoteExpired: state.isQuoteExpired,
              isLoadingPreview: state.isLoadingPreview,
              isSubmitting: state.isSubmittingOrder,
              selectedPaymentMethod: state.metodoPagamentoSelecionado,
              onConfirmAndPay: () {
                _checkoutBloc.add(const ConfirmAndPayOrderEvent());
              },
              onRecalculateQuote: () {
                _checkoutBloc.add(const LoadCheckoutPreviewEvent());
              },
            ),
          );
        },
      ),
    );
  }

  void _showOrderConfirmedSheet(
    BuildContext context,
    ConfirmedOrderResult resultado,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    CartService.instance.clear();

    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 40,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Pedido Confirmado!',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Estado atual: ${resultado.estadoDisplay}\n'
                  'Evento emitido: ${resultado.eventoGerado}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: colorScheme.primary.withOpacity(0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.pin_outlined,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'PIN de Entrega (RN-094):',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      Text(
                        resultado.pinEntrega,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 3,
                          color: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Total Cobrado:',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        CurrencyFormatter.formatKwanza(resultado.totalCobrado),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final token =
                          await SecureTokenStorage().getAccessToken() ?? '';
                      if (!sheetContext.mounted) return;
                      Navigator.of(sheetContext).pop();
                      if (!context.mounted) return;
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute<void>(
                          builder: (_) => OrderRealTimeTrackingScreen(
                            pedidoId: resultado.pedidoId,
                            jwtToken: token,
                            baseHttpUrl: AppEnvironmentConfig.baseHttpUrl,
                            baseWsUrl: AppEnvironmentConfig.baseWsUrl,
                            nomeLoja: widget.lojaNome,
                            moradaLojaTexto: 'Restaurante ${widget.lojaNome}',
                            coordenadasLoja: const LatLng(-8.839988, 13.289437),
                            moradaClienteTexto:
                                _checkoutBloc.state.moradaTexto,
                            coordenadasCliente: LatLng(
                              CartService.instance.latitude,
                              CartService.instance.longitude,
                            ),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.delivery_dining_rounded),
                    label: const Text('Acompanhar Pedido em Tempo Real'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// 6. COMPONENTES MODULARES DE UI (BLOCOS 1 A 6 + TIMER RN-043)
// ============================================================================

/// Badge do Timer Regressivo de 15 minutos da cotação (RN-043).
class _QuoteCountdownBadge extends StatelessWidget {
  final Duration remaining;
  final bool isExpired;
  final VoidCallback onRefreshTap;

  const _QuoteCountdownBadge({
    required this.remaining,
    required this.isExpired,
    required this.onRefreshTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUrgent = !isExpired && remaining.inSeconds <= 120;

    final minutes =
        remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        remaining.inSeconds.remainder(60).toString().padLeft(2, '0');

    final bgColor = isExpired
        ? colorScheme.errorContainer
        : isUrgent
            ? Colors.amber.shade100
            : colorScheme.secondaryContainer;

    final fgColor = isExpired
        ? colorScheme.onErrorContainer
        : isUrgent
            ? Colors.orange.shade900
            : colorScheme.onSecondaryContainer;

    return InkWell(
      onTap: isExpired ? onRefreshTap : null,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isExpired ? Icons.timer_off_outlined : Icons.timer_outlined,
              size: 16,
              color: fgColor,
            ),
            const SizedBox(width: 6),
            Text(
              isExpired ? 'Expirada' : '$minutes:$seconds',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: fgColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Banner de alerta exibido quando a cotação de 15 minutos expira (RN-043).
class _QuoteExpiredAlertBanner extends StatelessWidget {
  final VoidCallback onRecalculate;

  const _QuoteExpiredAlertBanner({required this.onRecalculate});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'A validade de 15 minutos desta cotação expirou (RN-043). Atualize os preços para prosseguir.',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: onRecalculate,
            child: const Text('Atualizar'),
          ),
        ],
      ),
    );
  }
}

/// BLOCO 1: Cabeçalho com o nome da loja e a morada de entrega selecionada.
class _StoreAndAddressHeaderCard extends StatelessWidget {
  final String lojaNome;
  final String moradaLabel;
  final String moradaTexto;
  final String? distanciaKm;
  final VoidCallback? onChangeAddressTap;

  const _StoreAndAddressHeaderCard({
    required this.lojaNome,
    required this.moradaLabel,
    required this.moradaTexto,
    this.distanciaKm,
    this.onChangeAddressTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Linha da Loja Parceira
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.storefront_rounded,
                    color: colorScheme.onPrimaryContainer,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PEDIDO EM',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lojaNome,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                if (distanciaKm != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$distanciaKm km',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),

            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),

            // Linha da Morada de Entrega selecionada (RN-005, RN-025)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.location_on_rounded,
                    color: colorScheme.onSecondaryContainer,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        moradaLabel,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        moradaTexto,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onChangeAddressTap != null)
                  TextButton(
                    onPressed: onChangeAddressTap,
                    child: const Text('Alterar'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// BLOCO 2: Lista dos itens adicionados com imagem, quantidade e opções personalizadas.
class _CartItemsSectionCard extends StatelessWidget {
  final List<CheckoutLineItemModel> itensCotados;
  final List<CheckoutCartItemInput> itensFallback;

  const _CartItemsSectionCard({
    required this.itensCotados,
    required this.itensFallback,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Itens do Pedido',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${itensCotados.isNotEmpty ? itensCotados.length : itensFallback.length} artigo(s)',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (itensCotados.isNotEmpty)
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: itensCotados.length,
                separatorBuilder: (_, __) => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1),
                ),
                itemBuilder: (context, index) {
                  final item = itensCotados[index];
                  return _CheckoutLineItemRow(item: item);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _CheckoutLineItemRow extends StatelessWidget {
  final CheckoutLineItemModel item;

  const _CheckoutLineItemRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Imagem do Produto
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            item.imagemUrl,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 64,
              height: 64,
              color: colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.fastfood_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),

        // Quantidade, Nome, Opções Personalizadas e Notas
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${item.quantidade}x',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.nome,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    CurrencyFormatter.formatKwanza(item.subtotalLinha),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),

              // Opções personalizadas (RN-014)
              if (item.opcoes.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: item.opcoes.map((op) {
                    final extraStr = op.precoNoMomento > 0
                        ? ' (+${CurrencyFormatter.formatKwanza(op.precoNoMomento)})'
                        : '';
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest
                            .withOpacity(0.7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '• ${op.nome}$extraStr',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 11.5,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],

              // Notas de preparação ao parceiro (RN-045)
              if (item.notas.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.notes_rounded,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Nota: "${item.notas}"',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// BLOCO 3: Campo para introduzir e validar cupões de desconto em tempo real (RN-055, RN-056).
class _CouponRealtimeSectionCard extends StatelessWidget {
  final TextEditingController controller;
  final CheckoutCouponDetailsModel? cupaoAplicado;
  final bool isValidating;
  final String? errorMessage;
  final ValueChanged<String> onApplyCoupon;
  final VoidCallback onRemoveCoupon;

  const _CouponRealtimeSectionCard({
    required this.controller,
    required this.cupaoAplicado,
    required this.isValidating,
    required this.errorMessage,
    required this.onApplyCoupon,
    required this.onRemoveCoupon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_offer_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Cupão de Desconto',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (cupaoAplicado != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.green.shade600),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.verified_rounded,
                      color: Colors.green.shade700,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Cupão ${cupaoAplicado!.codigo} aplicado!',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Colors.green.shade900,
                            ),
                          ),
                          Text(
                            'Poupança imediata de ${CurrencyFormatter.formatKwanza(cupaoAplicado!.descontoAplicado)}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.green.shade800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remover cupão',
                      onPressed: isValidating ? null : onRemoveCoupon,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[a-zA-Z0-9_-]'),
                        ),
                      ],
                      decoration: InputDecoration(
                        hintText: 'Ex.: BEMVINDO1000',
                        isDense: true,
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest
                            .withOpacity(0.45),
                        errorText: errorMessage,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(
                          Icons.confirmation_number_outlined,
                        ),
                      ),
                      onSubmitted: onApplyCoupon,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 48,
                    child: FilledButton.tonal(
                      onPressed: isValidating
                          ? null
                          : () => onApplyCoupon(controller.text),
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: isValidating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(
                              'Validar',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// BLOCO 4: Resumo Financeiro Detalhado (Subtotal, Taxa de Entrega + Aviso Preço Dinâmico,
/// Taxa de Serviço, Taxa Pequeno Pedido, Seletor de Gorjeta, Descontos e Total a Pagar - RN-050).
class _FinancialSummaryAndTipCard extends StatelessWidget {
  final CheckoutQuoteModel cotacao;
  final int gorjetaSelecionada;
  final bool isRecalculating;
  final ValueChanged<int> onSelectTip;

  // Opções rápidas de gorjeta em unidades mínimas (0 Kz, 200 Kz, 500 Kz, 1.000 Kz — RN-058)
  static const List<int> _presetTipsCentimos = [0, 20000, 50000, 100000];

  const _FinancialSummaryAndTipCard({
    required this.cotacao,
    required this.gorjetaSelecionada,
    required this.isRecalculating,
    required this.onSelectTip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final entrega = cotacao.detalhesEntrega;

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sub-bloco: Seletor de Gorjeta ao Estafeta (RN-058)
            Row(
              children: [
                Icon(
                  Icons.volunteer_activism_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Gorjeta ao Estafeta (100% para o estafeta)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presetTipsCentimos.map((tipValue) {
                final isSelected = gorjetaSelecionada == tipValue;
                final label = tipValue == 0
                    ? 'Sem gorjeta'
                    : '+${CurrencyFormatter.formatKwanza(tipValue)}';
                return ChoiceChip(
                  label: Text(
                    label,
                    style: TextStyle(
                      fontWeight:
                          isSelected ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
                  selected: isSelected,
                  onSelected: isRecalculating
                      ? null
                      : (_) => onSelectTip(tipValue),
                );
              }).toList(),
            ),

            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Divider(height: 1),
            ),

            // Título do Bloco de Resumo Financeiro (RN-050)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Resumo Financeiro',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (isRecalculating)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 14),

            // 1. Subtotal dos Itens
            _PriceLineRow(
              label: 'Subtotal dos artigos',
              value: CurrencyFormatter.formatKwanza(cotacao.subtotal),
            ),
            const SizedBox(height: 10),

            // 2. Taxa de Entrega + Aviso de Preço Dinâmico se ativo (RN-051, RN-052)
            _PriceLineRow(
              label: 'Taxa de Entrega (${entrega.distanciaKm} km)',
              value: cotacao.taxaEntrega == 0
                  ? 'Grátis'
                  : CurrencyFormatter.formatKwanza(cotacao.taxaEntrega),
              badge: entrega.isPrecoDinamicoAtivo
                  ? Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.amber.shade100,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.bolt_rounded,
                            size: 13,
                            color: Colors.orange.shade900,
                          ),
                          Text(
                            'Tarifa Dinâmica ${entrega.fatorPrecoDinamico}x',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Colors.orange.shade900,
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
            ),

            // Aviso explicativo transparente se Preço Dinâmico estiver ativo (RN-052)
            if (entrega.isPrecoDinamicoAtivo) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: Colors.orange.shade900,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'RN-052: Procura elevada na sua zona. A taxa de entrega inclui o fator dinâmico temporário de ${entrega.fatorPrecoDinamico}x.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Colors.orange.shade900,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),

            // 3. Taxa de Serviço da Plataforma (RN-053)
            _PriceLineRow(
              label: 'Taxa de Serviço',
              value: CurrencyFormatter.formatKwanza(cotacao.taxaServico),
            ),

            // 4. Taxa de Pequeno Pedido (se aplicável - RN-041)
            if (cotacao.taxaPequenoPedido > 0) ...[
              const SizedBox(height: 10),
              _PriceLineRow(
                label: 'Taxa de Pequeno Pedido (RN-041)',
                value: CurrencyFormatter.formatKwanza(cotacao.taxaPequenoPedido),
              ),
            ],

            // 5. Gorjeta ao Estafeta (RN-058)
            if (cotacao.gorjetaEstafeta > 0) ...[
              const SizedBox(height: 10),
              _PriceLineRow(
                label: 'Gorjeta ao Estafeta',
                value: CurrencyFormatter.formatKwanza(cotacao.gorjetaEstafeta),
              ),
            ],

            // 6. Descontos Promocionais / Cupão (RN-050, RN-056)
            if (cotacao.descontos > 0) ...[
              const SizedBox(height: 10),
              _PriceLineRow(
                label: cotacao.cupao != null
                    ? 'Desconto (${cotacao.cupao!.codigo})'
                    : 'Descontos aplicados',
                value: '-${CurrencyFormatter.formatKwanza(cotacao.descontos)}',
                isDiscount: true,
              ),
            ],

            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(height: 1),
            ),

            // 7. Linha de Destaque com o TOTAL A PAGAR (RN-050)
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withOpacity(0.45),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total a Pagar',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        'Impostos e taxas incluídos (RN-016 / RN-050)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    CurrencyFormatter.formatKwanza(cotacao.totalCobrado),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: colorScheme.primary,
                    ),
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

class _PriceLineRow extends StatelessWidget {
  final String label;
  final String value;
  final Widget? badge;
  final bool isDiscount;

  const _PriceLineRow({
    required this.label,
    required this.value,
    this.badge,
    this.isDiscount = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final textColor =
        isDiscount ? Colors.green.shade700 : colorScheme.onSurface;

    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: isDiscount
                  ? Colors.green.shade700
                  : colorScheme.onSurfaceVariant,
              fontWeight: isDiscount ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        if (badge != null) badge!,
        const Spacer(),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ],
    );
  }
}

/// BLOCO 5: Seletor de Meio de Pagamento (Cartão, Carteira Digital, Dinheiro - RN-065).
class _PaymentMethodSelectorCard extends StatelessWidget {
  final PaymentMethodType selecionado;
  final ValueChanged<PaymentMethodType> onChanged;

  const _PaymentMethodSelectorCard({
    required this.selecionado,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Meio de Pagamento',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            ...PaymentMethodType.values.map((metodo) {
              final isSelected = metodo == selecionado;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onChanged(metodo),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colorScheme.primaryContainer.withOpacity(0.35)
                          : colorScheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.outlineVariant.withOpacity(0.6),
                        width: isSelected ? 1.8 : 1.0,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          metodo.icone,
                          color: isSelected
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                metodo.titulo,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                metodo.subtitulo,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Radio<PaymentMethodType>(
                          value: metodo,
                          groupValue: selecionado,
                          onChanged: (val) {
                            if (val != null) onChanged(val);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// BLOCO 6: Barra flutuante inferior com botão "Confirmar e Pagar" e Timer RN-043.
class _FloatingConfirmAndPayBar extends StatelessWidget {
  final CheckoutQuoteModel? cotacao;
  final Duration remainingTime;
  final bool isQuoteExpired;
  final bool isLoadingPreview;
  final bool isSubmitting;
  final PaymentMethodType selectedPaymentMethod;
  final VoidCallback onConfirmAndPay;
  final VoidCallback onRecalculateQuote;

  const _FloatingConfirmAndPayBar({
    required this.cotacao,
    required this.remainingTime,
    required this.isQuoteExpired,
    required this.isLoadingPreview,
    required this.isSubmitting,
    required this.selectedPaymentMethod,
    required this.onConfirmAndPay,
    required this.onRecalculateQuote,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final minutes =
        remainingTime.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds =
        remainingTime.inSeconds.remainder(60).toString().padLeft(2, '0');

    final totalStr = cotacao != null
        ? CurrencyFormatter.formatKwanza(cotacao!.totalCobrado)
        : '--';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Linha informativa da validade da cotação (RN-043)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.lock_clock_outlined,
                      size: 14,
                      color: isQuoteExpired
                          ? colorScheme.error
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isQuoteExpired
                          ? 'Cotação expirada (RN-043)'
                          : 'Preço garantido por $minutes:$seconds',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: isQuoteExpired
                            ? colorScheme.error
                            : colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  selectedPaymentMethod.titulo,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Botão Principal "Confirmar e Pagar" (ou "Recalcular Cotação" se expirada)
            SizedBox(
              width: double.infinity,
              height: 54,
              child: isQuoteExpired
                  ? FilledButton.icon(
                      onPressed: isLoadingPreview ? null : onRecalculateQuote,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text(
                        'Recalcular Cotação (Expirada)',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    )
                  : FilledButton(
                      onPressed: (cotacao == null ||
                              isLoadingPreview ||
                              isSubmitting)
                          ? null
                          : onConfirmAndPay,
                      style: FilledButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: isSubmitting
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    color: colorScheme.onPrimary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'A processar pedido...',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Confirmar e Pagar',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        colorScheme.onPrimary.withOpacity(0.18),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    totalStr,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w900,
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

