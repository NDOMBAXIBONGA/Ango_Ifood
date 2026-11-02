/// Ecrã de Checkout e Confirmação Final (`CheckoutSummaryScreen`) em Flutter
/// com Material Design 3 e Gestão de Estado BLoC (`flutter_bloc` + `dio`).
///
/// Implementa rigorosamente as Secções 6.4, 6.5, 7.1 e as Regras de Negócio:
/// - RN-041: Taxa de pequeno pedido exibida condicionalmente quando subtotal < mínimo.
/// - RN-043: Cronómetro regressivo visual de 15 minutos (900s) da cotação no botão de confirmação,
///   com bloqueio ao expirar, diálogo modal e recálculo automático.
/// - RN-045: Observações de preparação do cliente nos itens do pedido.
/// - RN-046: Card de morada e seletor visual de entrega imediata vs agendada.
/// - RN-050: Composição financeira linear discriminada em unidades mínimas inteiras (Cêntimos/Kwanza).
/// - RN-051 / RN-052: Taxa de entrega com ícone de raio indicativo de alta procura (Surge Pricing).
/// - RN-056: Campo de validação de cupão com desconto destacado a verde.
/// - RN-058: Chips horizontais de gorjeta ao estafeta com atualização dinâmica do total.
/// - RN-065 / RN-069: Seletor de métodos de pagamento (Cartão, Carteira Digital, Dinheiro).
library checkout_summary_screen;

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

// ============================================================================
// 1. UTILITÁRIO DE FORMATAÇÃO MONETÁRIA INTEIRA (RN-059)
// ============================================================================

class CurrencyFormatter {
  const CurrencyFormatter._();

  /// Formata valores inteiros em unidades mínimas (100 unidades = 1 Kz)
  /// sem recorrer a números de vírgula flutuante (RN-059).
  static String formatKwanza(int unidadesMinimas) {
    final isNegativo = unidadesMinimas < 0;
    final valorAbs = unidadesMinimas.abs();
    final parteInteira = valorAbs ~/ 100;
    final centimos = valorAbs % 100;

    final strInteira = parteInteira.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (Match m) => '${m[1]}.',
        );

    final prefixo = isNegativo ? '-' : '';
    if (centimos == 0) {
      return '$prefixo$strInteira Kz';
    }
    final strCentimos = centimos.toString().padLeft(2, '0');
    return '$prefixo$strInteira,$strCentimos Kz';
  }
}

// ============================================================================
// 2. MODELOS DE DADOS DO CHECKOUT
// ============================================================================

enum PaymentMethodType {
  cartao(
    id: 'CARTAO',
    titulo: 'Cartão Bancário',
    subtitulo: 'Multicaixa, Visa ou Mastercard',
    icone: Icons.credit_card_rounded,
  ),
  carteiraDigital(
    id: 'CARTEIRA_DIGITAL',
    titulo: 'Carteira Digital',
    subtitulo: 'Mobile Money, Express ou QR Code',
    icone: Icons.account_balance_wallet_rounded,
  ),
  dinheiro(
    id: 'NUMERARIO',
    titulo: 'Dinheiro na Entrega',
    subtitulo: 'Pagamento em numerário no ato da receção',
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

@immutable
class CartItemSummaryModel extends Equatable {
  final String itemId;
  final String nome;
  final int precoUnitario;
  final int quantidade;
  final List<String> opcoesNomes;
  final String notas;

  const CartItemSummaryModel({
    required this.itemId,
    required this.nome,
    required this.precoUnitario,
    required this.quantidade,
    this.opcoesNomes = const [],
    this.notas = '',
  });

  int get subtotalLinha => precoUnitario * quantidade;

  @override
  List<Object?> get props => [itemId, nome, precoUnitario, quantidade, opcoesNomes, notas];
}

@immutable
class CheckoutPriceBreakdown extends Equatable {
  final String cotacaoId;
  final int subtotal;
  final int taxaEntrega;
  final bool isSurgeAtivo;
  final String fatorSurge;
  final int taxaServico;
  final int taxaPequenoPedido;
  final int gorjetaEstafeta;
  final int descontoCupao;
  final String? cupaoCodigo;
  final int totalCobrado;
  final DateTime expiraEm;
  final int ttlSegundos;

  const CheckoutPriceBreakdown({
    required this.cotacaoId,
    required this.subtotal,
    required this.taxaEntrega,
    this.isSurgeAtivo = false,
    this.fatorSurge = '1.00',
    required this.taxaServico,
    this.taxaPequenoPedido = 0,
    this.gorjetaEstafeta = 0,
    this.descontoCupao = 0,
    this.cupaoCodigo,
    required this.totalCobrado,
    required this.expiraEm,
    this.ttlSegundos = 900,
  });

  @override
  List<Object?> get props => [
        cotacaoId,
        subtotal,
        taxaEntrega,
        isSurgeAtivo,
        fatorSurge,
        taxaServico,
        taxaPequenoPedido,
        gorjetaEstafeta,
        descontoCupao,
        cupaoCodigo,
        totalCobrado,
        expiraEm,
        ttlSegundos,
      ];
}

// ============================================================================
// 3. EVENTOS DO CHECKOUT BLOC
// ============================================================================

abstract class CheckoutEvent extends Equatable {
  const CheckoutEvent();

  @override
  List<Object?> get props => [];
}

class LoadCheckoutPreview extends CheckoutEvent {
  const LoadCheckoutPreview();
}

class ApplyCouponSubmitted extends CheckoutEvent {
  final String codigo;
  const ApplyCouponSubmitted(this.codigo);

  @override
  List<Object?> get props => [codigo];
}

class RemoveCouponSubmitted extends CheckoutEvent {
  const RemoveCouponSubmitted();
}

class TipChanged extends CheckoutEvent {
  final int valorUnidadesMinimas;
  const TipChanged(this.valorUnidadesMinimas);

  @override
  List<Object?> get props => [valorUnidadesMinimas];
}

class PaymentMethodChanged extends CheckoutEvent {
  final PaymentMethodType metodo;
  const PaymentMethodChanged(this.metodo);

  @override
  List<Object?> get props => [metodo];
}

class DeliveryScheduleToggled extends CheckoutEvent {
  final bool isAgendado;
  final DateTime? dataHoraAgendada;
  const DeliveryScheduleToggled({required this.isAgendado, this.dataHoraAgendada});

  @override
  List<Object?> get props => [isAgendado, dataHoraAgendada];
}

class QuotationTimerExpired extends CheckoutEvent {
  const QuotationTimerExpired();
}

class RefreshQuotationRequested extends CheckoutEvent {
  const RefreshQuotationRequested();
}

class ConfirmOrderSubmitted extends CheckoutEvent {
  const ConfirmOrderSubmitted();
}

// ============================================================================
// 4. ESTADOS DO CHECKOUT BLOC (Conforme especificado no pedido)
// ============================================================================

abstract class CheckoutState extends Equatable {
  const CheckoutState();

  @override
  List<Object?> get props => [];
}

class CheckoutLoading extends CheckoutState {
  final String? mensagem;
  const CheckoutLoading({this.mensagem});

  @override
  List<Object?> get props => [mensagem];
}

class CheckoutPriceUpdated extends CheckoutState {
  final String lojaId;
  final String lojaNome;
  final String moradaTexto;
  final List<CartItemSummaryModel> itens;
  final CheckoutPriceBreakdown precos;
  final PaymentMethodType metodoPagamento;
  final bool isAgendado;
  final DateTime? dataHoraAgendada;
  final bool isValidatingCoupon;

  const CheckoutPriceUpdated({
    required this.lojaId,
    required this.lojaNome,
    required this.moradaTexto,
    required this.itens,
    required this.precos,
    this.metodoPagamento = PaymentMethodType.cartao,
    this.isAgendado = false,
    this.dataHoraAgendada,
    this.isValidatingCoupon = false,
  });

  CheckoutPriceUpdated copyWith({
    CheckoutPriceBreakdown? precos,
    PaymentMethodType? metodoPagamento,
    bool? isAgendado,
    DateTime? dataHoraAgendada,
    bool? isValidatingCoupon,
  }) {
    return CheckoutPriceUpdated(
      lojaId: lojaId,
      lojaNome: lojaNome,
      moradaTexto: moradaTexto,
      itens: itens,
      precos: precos ?? this.precos,
      metodoPagamento: metodoPagamento ?? this.metodoPagamento,
      isAgendado: isAgendado ?? this.isAgendado,
      dataHoraAgendada: dataHoraAgendada ?? this.dataHoraAgendada,
      isValidatingCoupon: isValidatingCoupon ?? this.isValidatingCoupon,
    );
  }

  @override
  List<Object?> get props => [
        lojaId,
        lojaNome,
        moradaTexto,
        itens,
        precos,
        metodoPagamento,
        isAgendado,
        dataHoraAgendada,
        isValidatingCoupon,
      ];
}

class CheckoutSessionExpired extends CheckoutState {
  final String motivo;
  const CheckoutSessionExpired({
    this.motivo = 'A validade de 15 minutos da cotação expirou. As taxas e valores foram atualizados.',
  });

  @override
  List<Object?> get props => [motivo];
}

class CheckoutSuccess extends CheckoutState {
  final String pedidoId;
  final int totalCobrado;
  final String metodoPagamento;

  const CheckoutSuccess({
    required this.pedidoId,
    required this.totalCobrado,
    required this.metodoPagamento,
  });

  @override
  List<Object?> get props => [pedidoId, totalCobrado, metodoPagamento];
}

class CheckoutFailure extends CheckoutState {
  final String mensagemErro;
  final String? codigoRegra;

  const CheckoutFailure({required this.mensagemErro, this.codigoRegra});

  @override
  List<Object?> get props => [mensagemErro, codigoRegra];
}

// ============================================================================
// 5. BLOC: CheckoutBloc
// ============================================================================

class CheckoutBloc extends Bloc<CheckoutEvent, CheckoutState> {
  final Dio dio;
  final String lojaId;
  final String lojaNome;
  final String moradaId;
  final String moradaTexto;
  final List<CartItemSummaryModel> itens;

  CheckoutBloc({
    Dio? dioClient,
    required this.lojaId,
    required this.lojaNome,
    required this.moradaId,
    required this.moradaTexto,
    required this.itens,
  })  : dio = dioClient ??
            Dio(
              BaseOptions(
                baseUrl: const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000'),
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 12),
              ),
            ),
        super(const CheckoutLoading(mensagem: 'A calcular cotação do checkout...')) {
    on<LoadCheckoutPreview>(_onLoadCheckoutPreview);
    on<ApplyCouponSubmitted>(_onApplyCouponSubmitted);
    on<RemoveCouponSubmitted>(_onRemoveCouponSubmitted);
    on<TipChanged>(_onTipChanged);
    on<PaymentMethodChanged>(_onPaymentMethodChanged);
    on<DeliveryScheduleToggled>(_onDeliveryScheduleToggled);
    on<QuotationTimerExpired>(_onQuotationTimerExpired);
    on<RefreshQuotationRequested>(_onRefreshQuotationRequested);
    on<ConfirmOrderSubmitted>(_onConfirmOrderSubmitted);

    add(const LoadCheckoutPreview());
  }

  Future<void> _onLoadCheckoutPreview(
    LoadCheckoutPreview event,
    Emitter<CheckoutState> emit,
  ) async {
    emit(const CheckoutLoading(mensagem: 'A contactar servidor de preços...'));
    await _buscarCotacao(emit, gorjeta: 0, cupao: null);
  }

  Future<void> _onApplyCouponSubmitted(
    ApplyCouponSubmitted event,
    Emitter<CheckoutState> emit,
  ) async {
    final estadoAtual = state;
    if (estadoAtual is! CheckoutPriceUpdated) return;

    emit(estadoAtual.copyWith(isValidatingCoupon: true));
    await _buscarCotacao(
      emit,
      gorjeta: estadoAtual.precos.gorjetaEstafeta,
      cupao: event.codigo.trim().toUpperCase(),
      metodoPagamentoAnterior: estadoAtual.metodoPagamento,
      isAgendadoAnterior: estadoAtual.isAgendado,
      dataHoraAnterior: estadoAtual.dataHoraAgendada,
    );
  }

  Future<void> _onRemoveCouponSubmitted(
    RemoveCouponSubmitted event,
    Emitter<CheckoutState> emit,
  ) async {
    final estadoAtual = state;
    if (estadoAtual is! CheckoutPriceUpdated) return;

    emit(estadoAtual.copyWith(isValidatingCoupon: true));
    await _buscarCotacao(
      emit,
      gorjeta: estadoAtual.precos.gorjetaEstafeta,
      cupao: null,
      metodoPagamentoAnterior: estadoAtual.metodoPagamento,
      isAgendadoAnterior: estadoAtual.isAgendado,
      dataHoraAnterior: estadoAtual.dataHoraAgendada,
    );
  }

  Future<void> _onTipChanged(
    TipChanged event,
    Emitter<CheckoutState> emit,
  ) async {
    final estadoAtual = state;
    if (estadoAtual is! CheckoutPriceUpdated) return;

    await _buscarCotacao(
      emit,
      gorjeta: event.valorUnidadesMinimas,
      cupao: estadoAtual.precos.cupaoCodigo,
      metodoPagamentoAnterior: estadoAtual.metodoPagamento,
      isAgendadoAnterior: estadoAtual.isAgendado,
      dataHoraAnterior: estadoAtual.dataHoraAgendada,
    );
  }

  void _onPaymentMethodChanged(
    PaymentMethodChanged event,
    Emitter<CheckoutState> emit,
  ) {
    if (state is CheckoutPriceUpdated) {
      emit((state as CheckoutPriceUpdated).copyWith(metodoPagamento: event.metodo));
    }
  }

  void _onDeliveryScheduleToggled(
    DeliveryScheduleToggled event,
    Emitter<CheckoutState> emit,
  ) {
    if (state is CheckoutPriceUpdated) {
      emit((state as CheckoutPriceUpdated).copyWith(
        isAgendado: event.isAgendado,
        dataHoraAgendada: event.dataHoraAgendada,
      ));
    }
  }

  void _onQuotationTimerExpired(
    QuotationTimerExpired event,
    Emitter<CheckoutState> emit,
  ) {
    emit(const CheckoutSessionExpired());
  }

  Future<void> _onRefreshQuotationRequested(
    RefreshQuotationRequested event,
    Emitter<CheckoutState> emit,
  ) async {
    emit(const CheckoutLoading(mensagem: 'A atualizar cotação expirada...'));
    await _buscarCotacao(emit, gorjeta: 0, cupao: null);
  }

  Future<void> _onConfirmOrderSubmitted(
    ConfirmOrderSubmitted event,
    Emitter<CheckoutState> emit,
  ) async {
    final estadoAtual = state;
    if (estadoAtual is! CheckoutPriceUpdated) return;

    emit(const CheckoutLoading(mensagem: 'A confirmar pedido e autorizar pagamento...'));

    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/api/v1/orders/checkout/confirm/',
        data: {
          'id_cotacao': estadoAtual.precos.cotacaoId,
          'metodo_pagamento_id': estadoAtual.metodoPagamento.id,
        },
      );

      final data = response.data ?? {};
      final pedidoMap = (data['pedido'] as Map<String, dynamic>?) ?? data;
      final pedidoId = (pedidoMap['id'] ?? '').toString();
      final total = (pedidoMap['total_cobrado'] as num?)?.toInt() ?? estadoAtual.precos.totalCobrado;

      emit(CheckoutSuccess(
        pedidoId: pedidoId,
        totalCobrado: total,
        metodoPagamento: estadoAtual.metodoPagamento.titulo,
      ));
    } on DioException catch (e) {
      final errorMsg = _extrairMensagemErro(e);
      emit(CheckoutFailure(mensagemErro: errorMsg));
      // Re-emite o estado de preços para que o utilizador possa tentar novamente
      emit(estadoAtual);
    } catch (e) {
      emit(CheckoutFailure(mensagemErro: e.toString()));
      emit(estadoAtual);
    }
  }

  Future<void> _buscarCotacao(
    Emitter<CheckoutState> emit, {
    required int gorjeta,
    String? cupao,
    PaymentMethodType metodoPagamentoAnterior = PaymentMethodType.cartao,
    bool isAgendadoAnterior = false,
    DateTime? dataHoraAnterior,
  }) async {
    try {
      final payload = {
        'loja_id': lojaId,
        'morada_id': moradaId,
        'itens': itens
            .map((e) => {
                  'item_id': e.itemId,
                  'quantidade': e.quantidade,
                  'notas': e.notas,
                })
            .toList(),
        'gorjeta_estafeta': gorjeta,
        if (cupao != null && cupao.isNotEmpty) 'cupao_codigo': cupao,
      };

      final response = await dio.post<Map<String, dynamic>>(
        '/api/v1/orders/checkout/preview/',
        data: payload,
      );

      final data = response.data ?? {};
      final resumo = (data['discriminacao_financeira'] as Map<String, dynamic>?) ??
          (data['resumo_precos'] as Map<String, dynamic>?) ??
          data;
      final entregaDet = (data['detalhes_taxa_entrega'] as Map<String, dynamic>?) ?? {};
      final cupaoDet = data['detalhes_cupao'] as Map<String, dynamic>?;

      final expiraStr = (data['expira_em'] ?? '').toString();
      final expiraDate = DateTime.tryParse(expiraStr) ?? DateTime.now().add(const Duration(minutes: 15));

      final precos = CheckoutPriceBreakdown(
        cotacaoId: (data['cotacao_id'] ?? data['id_cotacao'] ?? '').toString(),
        subtotal: (resumo['subtotal'] as num?)?.toInt() ?? 0,
        taxaEntrega: (resumo['taxa_entrega'] as num?)?.toInt() ?? 0,
        isSurgeAtivo: entregaDet['fator_dinamico'] != null &&
            (double.tryParse(entregaDet['fator_dinamico'].toString()) ?? 1.0) > 1.0,
        fatorSurge: (entregaDet['fator_dinamico'] ?? '1.00').toString(),
        taxaServico: (resumo['taxa_servico'] as num?)?.toInt() ?? 0,
        taxaPequenoPedido: (resumo['taxa_pequeno_pedido'] as num?)?.toInt() ?? 0,
        gorjetaEstafeta: (resumo['gorjeta_estafeta'] as num?)?.toInt() ?? gorjeta,
        descontoCupao: (resumo['descontos'] as num?)?.toInt() ?? 0,
        cupaoCodigo: cupaoDet != null ? cupaoDet['codigo']?.toString() : cupao,
        totalCobrado: (resumo['total_cobrado'] as num?)?.toInt() ?? 0,
        expiraEm: expiraDate,
        ttlSegundos: (data['ttl_segundos'] as num?)?.toInt() ?? 900,
      );

      emit(CheckoutPriceUpdated(
        lojaId: lojaId,
        lojaNome: (data['loja'] is Map ? data['loja']['nome'] : null) ?? lojaNome,
        moradaTexto: (data['morada_entrega'] is Map ? data['morada_entrega']['texto_endereco'] : null) ?? moradaTexto,
        itens: itens,
        precos: precos,
        metodoPagamento: metodoPagamentoAnterior,
        isAgendado: isAgendadoAnterior,
        dataHoraAgendada: dataHoraAnterior,
        isValidatingCoupon: false,
      ));
    } on DioException catch (e) {
      final msg = _extrairMensagemErro(e);
      emit(CheckoutFailure(mensagemErro: msg));
    } catch (e) {
      emit(CheckoutFailure(mensagemErro: 'Erro inesperado: $e'));
    }
  }

  String _extrairMensagemErro(DioException e) {
    final data = e.response?.data;
    if (data is Map<String, dynamic>) {
      return (data['erro'] ?? data['mensagem'] ?? data['detail'] ?? 'Falha na comunicação com o servidor').toString();
    }
    return 'Não foi possível contactar o servidor. Verifique a ligação à internet.';
  }
}

// ============================================================================
// 6. UI: CheckoutSummaryScreen (Material Design 3 + BlocConsumer)
// ============================================================================

class CheckoutSummaryScreen extends StatefulWidget {
  final String lojaId;
  final String lojaNome;
  final String moradaId;
  final String moradaTexto;
  final List<CartItemSummaryModel> itens;

  const CheckoutSummaryScreen({
    super.key,
    required this.lojaId,
    required this.lojaNome,
    required this.moradaId,
    required this.moradaTexto,
    required this.itens,
  });

  @override
  State<CheckoutSummaryScreen> createState() => _CheckoutSummaryScreenState();
}

class _CheckoutSummaryScreenState extends State<CheckoutSummaryScreen> {
  late final TextEditingController _couponController;
  Timer? _countdownTimer;
  Duration _tempoRestante = const Duration(minutes: 15);

  @override
  void initState() {
    super.initState();
    _couponController = TextEditingController();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _couponController.dispose();
    super.dispose();
  }

  void _iniciarTimerRegressivo(DateTime expiraEm, BuildContext context) {
    _countdownTimer?.cancel();
    final diff = expiraEm.difference(DateTime.now());
    _tempoRestante = diff.isNegative ? Duration.zero : diff;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final novoRestante = expiraEm.difference(DateTime.now());
      if (novoRestante.isNegative || novoRestante.inSeconds <= 0) {
        timer.cancel();
        setState(() => _tempoRestante = Duration.zero);
        context.read<CheckoutBloc>().add(const QuotationTimerExpired());
      } else {
        setState(() => _tempoRestante = novoRestante);
      }
    });
  }

  void _mostrarDialogoSessaoExpirada(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return AlertDialog(
          icon: const Icon(Icons.timer_off_rounded, color: Colors.orange, size: 40),
          title: const Text('Cotação Expirada (15 min)'),
          content: const Text(
            'A validade temporal da cotação atingiu o limite de 15 minutos (RN-043). '
            'Para garantir a precisão dos preços, taxas e stock, é necessário recalcular o carrinho.',
          ),
          actions: [
            FilledButton.icon(
              onPressed: () {
                Navigator.of(dialogCtx).pop();
                context.read<CheckoutBloc>().add(const RefreshQuotationRequested());
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Atualizar Cotação'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocProvider(
      create: (ctx) => CheckoutBloc(
        lojaId: widget.lojaId,
        lojaNome: widget.lojaNome,
        moradaId: widget.moradaId,
        moradaTexto: widget.moradaTexto,
        itens: widget.itens,
      ),
      child: BlocConsumer<CheckoutBloc, CheckoutState>(
        listener: (context, state) {
          if (state is CheckoutPriceUpdated) {
            _iniciarTimerRegressivo(state.precos.expiraEm, context);
            if (state.precos.cupaoCodigo != null && _couponController.text.isEmpty) {
              _couponController.text = state.precos.cupaoCodigo!;
            }
          } else if (state is CheckoutSessionExpired) {
            _countdownTimer?.cancel();
            _mostrarDialogoSessaoExpirada(context);
          } else if (state is CheckoutFailure) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.mensagemErro),
                backgroundColor: colorScheme.error,
                behavior: SnackBarBehavior.floating,
              ),
            );
          } else if (state is CheckoutSuccess) {
            _countdownTimer?.cancel();
            _mostrarSucessoDialogo(context, state);
          }
        },
        builder: (context, state) {
          final isCarregando = state is CheckoutLoading;
          final isExpirado = state is CheckoutSessionExpired || _tempoRestante == Duration.zero;

          return Scaffold(
            appBar: AppBar(
              title: const Text('Sumário do Checkout'),
              centerTitle: true,
              elevation: 0,
            ),
            body: isCarregando && state is! CheckoutPriceUpdated
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          (state as CheckoutLoading).mensagem ?? 'A carregar...',
                          style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.outline),
                        ),
                      ],
                    ),
                  )
                : state is CheckoutPriceUpdated
                    ? Stack(
                        children: [
                          ListView(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                            children: [
                              // 1. Bloco de Endereço e Agendamento (RN-046)
                              _buildAddressAndScheduleCard(context, state),
                              const SizedBox(height: 16),

                              // 2. Sumário dos Itens do Pedido (RN-045)
                              _buildItemsSummaryCard(context, state),
                              const SizedBox(height: 16),

                              // 3. Widget de Validação de Cupão (RN-056)
                              _buildCouponValidationWidget(context, state),
                              const SizedBox(height: 16),

                              // 4. Bloco de Composição Financeira Discriminada (RN-050, RN-058)
                              _buildFinancialBreakdownCard(context, state),
                              const SizedBox(height: 16),

                              // 5. Seletor de Meio de Pagamento (RN-065)
                              _buildPaymentMethodSelector(context, state),
                            ],
                          ),
                          if (state.isValidatingCoupon || isCarregando)
                            Container(
                              color: Colors.black26,
                              child: const Center(child: CircularProgressIndicator()),
                            ),
                        ],
                      )
                    : const SizedBox.shrink(),
            // 6. Botão Flutuante de Confirmação com Timer Regressivo (RN-043)
            bottomSheet: state is CheckoutPriceUpdated
                ? _buildBottomConfirmationBar(context, state, isExpirado)
                : null,
          );
        },
      ),
    );
  }

  // ==========================================================================
  // WIDGETS MODULARES DA INTERFACE
  // ==========================================================================

  /// 1. Card de Endereço Minimalista e Agendamento (RN-046)
  Widget _buildAddressAndScheduleCard(BuildContext context, CheckoutPriceUpdated state) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.location_on_rounded, color: colorScheme.primary, size: 22),
                const SizedBox(width: 8),
                Text('Morada de Entrega', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              state.moradaTexto,
              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      state.isAgendado ? Icons.schedule_rounded : Icons.flash_on_rounded,
                      color: state.isAgendado ? Colors.blue.shade700 : Colors.amber.shade800,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      state.isAgendado ? 'Entrega Agendada' : 'Entrega Imediata (~30-45 min)',
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                Switch(
                  value: state.isAgendado,
                  onChanged: (val) {
                    if (val) {
                      _selecionarHorarioAgendamento(context);
                    } else {
                      context.read<CheckoutBloc>().add(const DeliveryScheduleToggled(isAgendado: false));
                    }
                  },
                ),
              ],
            ),
            if (state.isAgendado && state.dataHoraAgendada != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event_available_rounded, size: 16, color: colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Agendado para: ${_formatarDataHora(state.dataHoraAgendada!)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 2. Sumário Colapsável dos Itens do Pedido (RN-045)
  Widget _buildItemsSummaryCard(BuildContext context, CheckoutPriceUpdated state) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          leading: Icon(Icons.shopping_bag_outlined, color: colorScheme.primary),
          title: Text(
            'Itens do Pedido (${state.itens.length})',
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            state.lojaNome,
            style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline),
          ),
          children: [
            const Divider(height: 1),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollException(),
              itemCount: state.itens.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (ctx, index) {
                final item = state.itens[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${item.quantidade}x',
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.nome,
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (item.opcoesNomes.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                item.opcoesNomes.join(' • '),
                                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline),
                              ),
                            ],
                            if (item.notas.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Icon(Icons.edit_note_rounded, size: 14, color: colorScheme.primary),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      item.notas,
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
                      const SizedBox(width: 8),
                      Text(
                        CurrencyFormatter.formatKwanza(item.subtotalLinha),
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 3. Widget de Validação de Cupão (RN-056)
  Widget _buildCouponValidationWidget(BuildContext context, CheckoutPriceUpdated state) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cupaoAplicado = state.precos.cupaoCodigo;
    final temCupaoAtivo = cupaoAplicado != null && state.precos.descontoCupao > 0;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: temCupaoAtivo ? Colors.green.shade400 : colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.local_offer_outlined,
                  color: temCupaoAtivo ? Colors.green.shade700 : colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text('Cupão de Desconto', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            if (temCupaoAtivo)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.check_circle_rounded, color: Colors.green.shade700, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          '$cupaoAplicado (-${CurrencyFormatter.formatKwanza(state.precos.descontoCupao)})',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.green.shade800,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        _couponController.clear();
                        context.read<CheckoutBloc>().add(const RemoveCouponSubmitted());
                      },
                    ),
                  ],
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _couponController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        hintText: 'Inserir código promocional',
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      final codigo = _couponController.text.trim();
                      if (codigo.isNotEmpty) {
                        context.read<CheckoutBloc>().add(ApplyCouponSubmitted(codigo));
                      }
                    },
                    child: const Text('Aplicar'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 4. Bloco de Composição Financeira Discriminada (RN-050, RN-058, Secção 7.1)
  Widget _buildFinancialBreakdownCard(BuildContext context, CheckoutPriceUpdated state) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final precos = state.precos;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Resumo de Preços', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),

            // Subtotal
            _buildPriceRow(context, 'Subtotal dos produtos', CurrencyFormatter.formatKwanza(precos.subtotal)),

            // Taxa de Entrega com Preço Dinâmico (RN-051, RN-052)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Text('Taxa de Entrega'),
                      if (precos.isSurgeAtivo) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Preço dinâmico ativo (${precos.fatorSurge}x) devido à elevada procura',
                          child: Icon(Icons.bolt_rounded, color: Colors.amber.shade800, size: 18),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    CurrencyFormatter.formatKwanza(precos.taxaEntrega),
                    style: TextStyle(
                      color: precos.isSurgeAtivo ? Colors.amber.shade900 : null,
                      fontWeight: precos.isSurgeAtivo ? FontWeight.bold : null,
                    ),
                  ),
                ],
              ),
            ),

            // Taxa de Serviço (RN-053)
            _buildPriceRow(context, 'Taxa de Serviço', CurrencyFormatter.formatKwanza(precos.taxaServico)),

            // Taxa de Pequeno Pedido (Apenas se subtotal < mínimo) (RN-041)
            if (precos.taxaPequenoPedido > 0)
              _buildPriceRow(
                context,
                'Suplemento de Pequeno Pedido',
                CurrencyFormatter.formatKwanza(precos.taxaPequenoPedido),
                destaqueCor: Colors.orange.shade800,
              ),

            // Desconto de Cupão (RN-056)
            if (precos.descontoCupao > 0)
              _buildPriceRow(
                context,
                'Desconto de Cupão',
                '-${CurrencyFormatter.formatKwanza(precos.descontoCupao)}',
                destaqueCor: Colors.green.shade700,
              ),

            const SizedBox(height: 12),
            // Seletor Horizontal de Gorjeta ao Estafeta (RN-058)
            Text(
              'Gorjeta ao Estafeta (100% repassada)',
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.outline),
            ),
            const SizedBox(height: 8),
            _buildTipSelector(context, state),

            const Divider(height: 24),
            // Total Final em Destaque (RN-050)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total a Pagar',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                Text(
                  CurrencyFormatter.formatKwanza(precos.totalCobrado),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceRow(
    BuildContext context,
    String titulo,
    String valor, {
    Color? destaqueCor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(titulo),
          Text(
            valor,
            style: TextStyle(
              color: destaqueCor,
              fontWeight: destaqueCor != null ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  /// Chips Interativos de Gorjeta ao Estafeta (RN-058)
  Widget _buildTipSelector(BuildContext context, CheckoutPriceUpdated state) {
    final valores = [0, 20000, 50000, 100000]; // em unidades mínimas inteiras (0, 200, 500, 1000 Kz)
    final gorjetaAtual = state.precos.gorjetaEstafeta;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ...valores.map((val) {
            final isSelecionado = gorjetaAtual == val;
            final label = val == 0 ? 'Sem Gorjeta' : CurrencyFormatter.formatKwanza(val);
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(label),
                selected: isSelecionado,
                onSelected: (_) {
                  context.read<CheckoutBloc>().add(TipChanged(val));
                },
              ),
            );
          }),
          FilterChip(
            label: const Text('Outro'),
            selected: !valores.contains(gorjetaAtual),
            onSelected: (_) => _mostrarDialogoGorjetaPersonalizada(context),
          ),
        ],
      ),
    );
  }

  /// 5. Seletor de Métodos de Pagamento (RN-065, RN-069)
  Widget _buildPaymentMethodSelector(BuildContext context, CheckoutPriceUpdated state) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final metodoAtual = state.metodoPagamento;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Método de Pagamento', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...PaymentMethodType.values.map((metodo) {
              final isSelected = metodoAtual == metodo;
              return Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? colorScheme.primary : colorScheme.outlineVariant,
                    width: isSelected ? 1.5 : 1,
                  ),
                  color: isSelected ? colorScheme.primaryContainer.withOpacity(0.15) : null,
                ),
                child: RadioListTile<PaymentMethodType>(
                  value: metodo,
                  groupValue: metodoAtual,
                  title: Text(metodo.titulo, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(metodo.subtitulo, style: theme.textTheme.bodySmall),
                  secondary: Icon(metodo.icone, color: isSelected ? colorScheme.primary : colorScheme.outline),
                  onChanged: (novo) {
                    if (novo != null) {
                      context.read<CheckoutBloc>().add(PaymentMethodChanged(novo));
                    }
                  },
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// 6. Botão Flutuante de Confirmação com Cronómetro Regressivo (RN-043)
  Widget _buildBottomConfirmationBar(
    BuildContext context,
    CheckoutPriceUpdated state,
    bool isExpirado,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final minutos = _tempoRestante.inMinutes.toString().padLeft(2, '0');
    final segundos = (_tempoRestante.inSeconds % 60).toString().padLeft(2, '0');
    final textoTimer = '$minutos:$segundos';
    final timerQuaseEsgotado = _tempoRestante.inMinutes < 2;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: isExpirado ? colorScheme.surfaceVariant : colorScheme.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: isExpirado
                ? () => _mostrarDialogoSessaoExpirada(context)
                : () {
                    HapticFeedback.mediumImpact();
                    context.read<CheckoutBloc>().add(const ConfirmOrderSubmitted());
                  },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      size: 18,
                      color: isExpirado
                          ? Colors.grey
                          : (timerQuaseEsgotado ? Colors.amberAccent : Colors.white),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isExpirado ? 'Expirado' : textoTimer,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: isExpirado
                            ? Colors.grey
                            : (timerQuaseEsgotado ? Colors.amberAccent : Colors.white),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Text(
                  isExpirado ? 'Atualizar Cotação' : 'Confirmar Pedido',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  CurrencyFormatter.formatKwanza(state.precos.totalCobrado),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // MÉTODOS AUXILIARES DE DIÁLOGOS
  // ==========================================================================

  void _mostrarDialogoGorjetaPersonalizada(BuildContext context) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dCtx) {
        return AlertDialog(
          title: const Text('Gorjeta ao Estafeta (Kz)'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              hintText: 'Ex.: 350',
              suffixText: 'Kz',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dCtx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                final valorKz = int.tryParse(controller.text) ?? 0;
                // Converte para unidades mínimas (1 Kz = 100 centimos)
                context.read<CheckoutBloc>().add(TipChanged(valorKz * 100));
                Navigator.pop(dCtx);
              },
              child: const Text('Gravar'),
            ),
          ],
        );
      },
    );
  }

  void _selecionarHorarioAgendamento(BuildContext context) async {
    final agora = DateTime.now();
    final data = await showDatePicker(
      context: context,
      initialDate: agora.add(const Duration(hours: 1)),
      firstDate: agora,
      lastDate: agora.add(const Duration(days: 3)),
    );

    if (data == null || !mounted) return;

    final hora = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(agora.add(const Duration(hours: 2))),
    );

    if (hora == null || !mounted) return;

    final dataHoraCompleta = DateTime(data.year, data.month, data.day, hora.hour, hora.minute);
    context.read<CheckoutBloc>().add(
          DeliveryScheduleToggled(isAgendado: true, dataHoraAgendada: dataHoraCompleta),
        );
  }

  void _mostrarSucessoDialogo(BuildContext context, CheckoutSuccess state) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dCtx) {
        return AlertDialog(
          icon: const Icon(Icons.check_circle_rounded, color: Colors.green, size: 50),
          title: const Text('Pedido Confirmado!'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'O seu pedido foi recebido com sucesso e o pagamento foi autorizado.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Total: ${CurrencyFormatter.formatKwanza(state.totalCobrado)}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              Text('Via: ${state.metodoPagamento}', style: const TextStyle(color: Colors.grey)),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(dCtx);
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
              child: const Text('Acompanhar Pedido'),
            ),
          ],
        );
      },
    );
  }

  String _formatarDataHora(DateTime dt) {
    final dia = dt.day.toString().padLeft(2, '0');
    final mes = dt.month.toString().padLeft(2, '0');
    final hora = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$dia/$mes às $hora:$min';
  }
}

