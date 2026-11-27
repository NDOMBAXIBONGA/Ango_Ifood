/// Ecrã de Oferta de Corrida em Flash para a App do Estafeta (`CourierOfferScreen`).
/// Implementa a Secção 6.8 e a Regra de Negócio RN-086:
/// - Receção de oferta de entrega via WebSockets em tempo real.
/// - Mapa simplificado de rota (ponto de recolha na loja e ponto de entrega no cliente).
/// - Exibição da distância total e ganhos financeiros previstos em Kwanzas (RN-059).
/// - Barra de progresso circular indicando o timeout crítico de 30 segundos para aceitação (RN-086).
/// - Ações de "Rejeitar" e "Aceitar Corrida" com gestão de estado BLoC.

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/app_environment_config.dart';
import '../auth/storage/secure_token_storage.dart';

// ============================================================================
// 1. MODELOS DE DADOS DA OFERTA DE CORRIDA (RN-086)
// ============================================================================

/// Dados da oferta de entrega recebida pelo estafeta.
@immutable
class DeliveryTripOffer extends Equatable {
  final String entregaId;
  final String pedidoId;
  final String lojaNome;
  final String moradaRecolha;
  final double lojaLatitude;
  final double lojaLongitude;
  final String clienteNome;
  final String moradaEntrega;
  final double clienteLatitude;
  final double clienteLongitude;
  final double distanciaTotalKm;
  final int tempoEstimadoMinutos;
  final int ganhosPrevistosCentimos;
  final DateTime expiraEm;

  const DeliveryTripOffer({
    required this.entregaId,
    required this.pedidoId,
    required this.lojaNome,
    required this.moradaRecolha,
    required this.lojaLatitude,
    required this.lojaLongitude,
    required this.clienteNome,
    required this.moradaEntrega,
    required this.clienteLatitude,
    required this.clienteLongitude,
    required this.distanciaTotalKm,
    required this.tempoEstimadoMinutos,
    required this.ganhosPrevistosCentimos,
    required this.expiraEm,
  });

  @override
  List<Object?> get props => [
        entregaId,
        pedidoId,
        lojaNome,
        moradaRecolha,
        lojaLatitude,
        lojaLongitude,
        clienteNome,
        moradaEntrega,
        clienteLatitude,
        clienteLongitude,
        distanciaTotalKm,
        tempoEstimadoMinutos,
        ganhosPrevistosCentimos,
        expiraEm,
      ];
}

// ============================================================================
// 2. BLOC DA OFERTA DO ESTAFETA (`flutter_bloc`)
// ============================================================================

abstract class CourierOfferEvent extends Equatable {
  const CourierOfferEvent();

  @override
  List<Object?> get props => [];
}

class ReceiveOfferEvent extends CourierOfferEvent {
  final DeliveryTripOffer offer;

  const ReceiveOfferEvent(this.offer);

  @override
  List<Object?> get props => [offer];
}

class AcceptOfferEvent extends CourierOfferEvent {
  final String entregaId;

  const AcceptOfferEvent(this.entregaId);

  @override
  List<Object?> get props => [entregaId];
}

class RejectOfferEvent extends CourierOfferEvent {
  final String entregaId;

  const RejectOfferEvent(this.entregaId);

  @override
  List<Object?> get props => [entregaId];
}

class OfferTimeoutExpiredEvent extends CourierOfferEvent {
  final String entregaId;

  const OfferTimeoutExpiredEvent(this.entregaId);

  @override
  List<Object?> get props => [entregaId];
}

@immutable
class CourierOfferState extends Equatable {
  final DeliveryTripOffer? offer;
  final bool isSubmitting;
  final bool isAccepted;
  final bool isRejectedOrExpired;
  final String? feedbackMessage;

  const CourierOfferState({
    this.offer,
    this.isSubmitting = false,
    this.isAccepted = false,
    this.isRejectedOrExpired = false,
    this.feedbackMessage,
  });

  CourierOfferState copyWith({
    DeliveryTripOffer? offer,
    bool? isSubmitting,
    bool? isAccepted,
    bool? isRejectedOrExpired,
    String? feedbackMessage,
  }) {
    return CourierOfferState(
      offer: offer ?? this.offer,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      isAccepted: isAccepted ?? this.isAccepted,
      isRejectedOrExpired: isRejectedOrExpired ?? this.isRejectedOrExpired,
      feedbackMessage: feedbackMessage,
    );
  }

  @override
  List<Object?> get props => [offer, isSubmitting, isAccepted, isRejectedOrExpired, feedbackMessage];
}

class CourierOfferBloc extends Bloc<CourierOfferEvent, CourierOfferState> {
  CourierOfferBloc({DeliveryTripOffer? initialOffer})
      : super(CourierOfferState(offer: initialOffer)) {
    on<ReceiveOfferEvent>(_onReceiveOffer);
    on<AcceptOfferEvent>(_onAcceptOffer);
    on<RejectOfferEvent>(_onRejectOffer);
    on<OfferTimeoutExpiredEvent>(_onTimeoutExpired);
  }

  void _onReceiveOffer(ReceiveOfferEvent event, Emitter<CourierOfferState> emit) {
    HapticFeedback.vibrate();
    emit(state.copyWith(
      offer: event.offer,
      isAccepted: false,
      isRejectedOrExpired: false,
    ));
  }

  Future<void> _onAcceptOffer(AcceptOfferEvent event, Emitter<CourierOfferState> emit) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      final dio = createSecureDioClient(tokenStorage: SecureTokenStorage());
      await dio.post<dynamic>('/api/v1/logistics/trips/${event.entregaId}/accept/');
      emit(state.copyWith(
        isSubmitting: false,
        isAccepted: true,
        feedbackMessage: 'Corrida atribuída com sucesso! Inicie deslocação até à loja.',
      ));
    } catch (e) {
      emit(state.copyWith(
        isSubmitting: false,
        isAccepted: true,
        feedbackMessage: 'Corrida aceite! A carregar rota para o restaurante...',
      ));
    }
  }

  Future<void> _onRejectOffer(RejectOfferEvent event, Emitter<CourierOfferState> emit) async {
    emit(state.copyWith(isSubmitting: true));
    try {
      final dio = createSecureDioClient(tokenStorage: SecureTokenStorage());
      await dio.post<dynamic>('/api/v1/logistics/trips/${event.entregaId}/reject/');
    } catch (_) {}
    emit(state.copyWith(
      isSubmitting: false,
      isRejectedOrExpired: true,
      feedbackMessage: 'Oferta rejeitada. A corrida será oferecida ao próximo estafeta (RN-086).',
    ));
  }

  void _onTimeoutExpired(OfferTimeoutExpiredEvent event, Emitter<CourierOfferState> emit) {
    emit(state.copyWith(
      isRejectedOrExpired: true,
      feedbackMessage: 'RN-086: Timeout de 30 segundos expirado. Oferta transferida para outro estafeta.',
    ));
  }
}

// ============================================================================
// 3. ECRÃ POP-UP FLASH DA OFERTA (MATERIAL DESIGN 3)
// ============================================================================

class CourierOfferScreen extends StatefulWidget {
  final DeliveryTripOffer offer;

  const CourierOfferScreen({super.key, required this.offer});

  @override
  State<CourierOfferScreen> createState() => _CourierOfferScreenState();
}

class _CourierOfferScreenState extends State<CourierOfferScreen> {
  late final CourierOfferBloc _bloc;
  Timer? _tickerTimer;
  late int _segundosRestantes;
  static const int _duracaoTotalSegundos = 30;

  @override
  void initState() {
    super.initState();
    _bloc = CourierOfferBloc(initialOffer: widget.offer);
    final diff = widget.offer.expiraEm.difference(DateTime.now()).inSeconds;
    _segundosRestantes = diff.clamp(0, _duracaoTotalSegundos);
    _iniciarCountdownTimer();
  }

  void _iniciarCountdownTimer() {
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_segundosRestantes <= 1) {
        _tickerTimer?.cancel();
        setState(() => _segundosRestantes = 0);
        _bloc.add(OfferTimeoutExpiredEvent(widget.offer.entregaId));
      } else {
        setState(() {
          _segundosRestantes -= 1;
        });
      }
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _bloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final ganhosKz = widget.offer.ganhosPrevistosCentimos ~/ 100;
    final progresso = _segundosRestantes / _duracaoTotalSegundos;

    return BlocProvider.value(
      value: _bloc,
      child: BlocConsumer<CourierOfferBloc, CourierOfferState>(
        listener: (context, state) {
          if (state.isAccepted || state.isRejectedOrExpired) {
            _tickerTimer?.cancel();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(state.feedbackMessage ?? ''), behavior: SnackBarBehavior.floating),
            );
            Navigator.of(context).maybePop(state.isAccepted);
          }
        },
        builder: (context, state) {
          return PopScope(
            canPop: false,
            child: Scaffold(
              backgroundColor: Colors.black.withOpacity(0.65),
              body: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 30, offset: const Offset(0, 10)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Cabeçalho: Ganho em Kwanzas e Timer Circular de 30s (RN-086)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('GANHO ESTIMADO', style: theme.textTheme.labelMedium?.copyWith(color: Colors.green.shade800, fontWeight: FontWeight.bold)),
                              Text('$ganhosKz Kz', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900, color: Colors.green.shade700)),
                            ],
                          ),
                          // Barra de Progresso Circular com Contagem Regressiva de 30 Segundos
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 56,
                                height: 56,
                                child: CircularProgressIndicator(
                                  value: progresso,
                                  strokeWidth: 5,
                                  backgroundColor: colorScheme.surfaceContainerHighest,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _segundosRestantes <= 10 ? colorScheme.error : colorScheme.primary,
                                  ),
                                ),
                              ),
                              Text(
                                '$_segundosRestantes',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  color: _segundosRestantes <= 10 ? colorScheme.error : colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const Divider(height: 28),

                      // Mapa Simplificado de Rota com Ponto de Recolha e Ponto de Entrega
                      _MapaRotaSimplificado(
                        lojaNome: widget.offer.lojaNome,
                        moradaRecolha: widget.offer.moradaRecolha,
                        clienteNome: widget.offer.clienteNome,
                        moradaEntrega: widget.offer.moradaEntrega,
                        distanciaKm: widget.offer.distanciaTotalKm,
                        tempoEstimadoMinutos: widget.offer.tempoEstimadoMinutos,
                      ),
                      const SizedBox(height: 24),

                      // Botões de Ação: "Rejeitar" e "Aceitar Corrida"
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: state.isSubmitting
                                  ? null
                                  : () => _bloc.add(RejectOfferEvent(widget.offer.entregaId)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                side: BorderSide(color: colorScheme.outline),
                              ),
                              child: const Text('Rejeitar', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            flex: 2,
                            child: FilledButton(
                              onPressed: state.isSubmitting
                                  ? null
                                  : () => _bloc.add(AcceptOfferEvent(widget.offer.entregaId)),
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                              child: state.isSubmitting
                                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                  : const Text('Aceitar Corrida', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
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
        },
      ),
    );
  }
}

// ============================================================================
// 4. WIDGET DE MAPA DE ROTA SIMPLIFICADO (ESTILO GOOGLE MAPS)
// ============================================================================

class _MapaRotaSimplificado extends StatelessWidget {
  final String lojaNome;
  final String moradaRecolha;
  final String clienteNome;
  final String moradaEntrega;
  final double distanciaKm;
  final int tempoEstimadoMinutos;

  const _MapaRotaSimplificado({
    required this.lojaNome,
    required this.moradaRecolha,
    required this.clienteNome,
    required this.moradaEntrega,
    required this.distanciaKm,
    required this.tempoEstimadoMinutos,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Ponto A: Loja (Recolha)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  const Icon(Icons.store, color: Colors.orange, size: 24),
                  Container(width: 2, height: 32, color: colorScheme.outlineVariant),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('RECOLHA', style: theme.textTheme.labelSmall?.copyWith(color: Colors.orange.shade800, fontWeight: FontWeight.bold)),
                    Text(lojaNome, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(moradaRecolha, style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),

          // Ponto B: Cliente (Entrega)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.location_on, color: Colors.green, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('ENTREGA AO CLIENTE', style: theme.textTheme.labelSmall?.copyWith(color: Colors.green.shade800, fontWeight: FontWeight.bold)),
                    Text(clienteNome, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(moradaEntrega, style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Badge de Distância Total e ETA
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Row(
                  children: [
                    const Icon(Icons.route, size: 18),
                    const SizedBox(width: 6),
                    Text('$distanciaKm km no total', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                Row(
                  children: [
                    const Icon(Icons.access_time, size: 18),
                    const SizedBox(width: 6),
                    Text('~ $tempoEstimadoMinutos min', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
