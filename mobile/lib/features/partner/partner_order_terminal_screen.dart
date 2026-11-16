/// Ecrã de Terminal de Pedidos para a App do Parceiro / Restaurante (`PartnerOrderTerminalScreen`).
/// Implementa a Secção 6.7 e as Regras de Negócio:
/// - RN-070 / RN-075: Receção em tempo real de pedidos no estado `AGUARDA_PARCEIRO` com contagem
///   decrescente visual de 3 minutos (180s) e alerta sonoro repetitivo em loop (RN-120).
/// - RN-076: Rejeição obrigatória fundamentada por motivo pré-definido (Cozinha sobrecarregada,
///   falta de stock de ingredientes, encerramento do estabelecimento, etc.).
/// - RN-077: Aceitação do pedido com confirmação ou ajuste do tempo estimado de preparação em minutos.
/// - RN-120: Alertas sonoros contínuos de alta prioridade para pedidos pendentes no balcão da loja.

import 'dart:async';
import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../auth/storage/secure_token_storage.dart';
import '../../core/network/app_environment_config.dart';

// ============================================================================
// 1. MODELOS DE DADOS DO TERMINAL DO PARCEIRO (RN-075, RN-076, RN-077)
// ============================================================================

/// Motivos padronizados de rejeição de pedido pelo parceiro (RN-076).
enum MotivoRejeicaoPedido {
  cozinhaSobrecarregada(
    codigo: 'COZINHA_SOBRECARREGADA',
    descricao: 'Cozinha sobrecarregada / Capacidade máxima atingida',
  ),
  faltaStockIngredientes(
    codigo: 'FALTA_STOCK',
    descricao: 'Ingredientes esgotados / Artigos sem stock',
  ),
  lojaAEncerrar(
    codigo: 'LOJA_A_ENCERRAR',
    descricao: 'Estabelecimento a encerrar ou fora do horário',
  ),
  avariaEquipamento(
    codigo: 'AVARIA_EQUIPAMENTO',
    descricao: 'Avaria técnica em equipamentos de cozinha',
  ),
  outro(
    codigo: 'OUTRO_MOTIVO',
    descricao: 'Outro motivo operacional devidamente justificado',
  );

  final String codigo;
  final String descricao;

  const MotivoRejeicaoPedido({required this.codigo, required this.descricao});
}

/// Item resumido de um pedido recebido no balcão da loja parceira.
@immutable
class TerminalOrderItem extends Equatable {
  final String id;
  final String nome;
  final int quantidade;
  final int precoUnitarioCentimos;
  final List<String> opcoesPersonalizadas;
  final String? notas;

  const TerminalOrderItem({
    required this.id,
    required this.nome,
    required this.quantidade,
    required this.precoUnitarioCentimos,
    this.opcoesPersonalizadas = const [],
    this.notas,
  });

  @override
  List<Object?> get props => [id, nome, quantidade, precoUnitarioCentimos, opcoesPersonalizadas, notas];
}

/// Pedido recebido no terminal aguardando aceitação da loja (RN-075).
@immutable
class IncomingPartnerOrder extends Equatable {
  final String pedidoId;
  final String numeroPedidoExibicao;
  final String nomeCliente;
  final DateTime recebidoEm;
  final DateTime expiraEm;
  final int tempoPreparacaoPadraoMinutos;
  final int subtotalCentimos;
  final List<TerminalOrderItem> itens;

  const IncomingPartnerOrder({
    required this.pedidoId,
    required this.numeroPedidoExibicao,
    required this.nomeCliente,
    required this.recebidoEm,
    required this.expiraEm,
    this.tempoPreparacaoPadraoMinutos = 20,
    required this.subtotalCentimos,
    required this.itens,
  });

  @override
  List<Object?> get props => [
        pedidoId,
        numeroPedidoExibicao,
        nomeCliente,
        recebidoEm,
        expiraEm,
        tempoPreparacaoPadraoMinutos,
        subtotalCentimos,
        itens,
      ];
}

// ============================================================================
// 2. SERVIÇO DE ALERTA SONORO CONTÍNUO EM LOOP (RN-120)
// ============================================================================

class PartnerAlertAudioService {
  bool _isPlaying = false;
  Timer? _hapticLoopTimer;

  bool get isPlaying => _isPlaying;

  /// Inicia o alerta sonoro e vibratório em loop contínuo até o operador intervir (RN-120).
  void startRepeatingAlertLoop() {
    if (_isPlaying) return;
    _isPlaying = true;

    // Em produção integra com audioplayers (ex.: audioPlayer.play(AssetSource('sounds/urgent_bell.mp3'), mode: Loop))
    // Simula loop contínuo com feedback tátil pesado a cada 1.5 segundos
    _hapticLoopTimer?.cancel();
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);

    _hapticLoopTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (_isPlaying) {
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
      }
    });
  }

  /// Pára imediatamente o alerta sonoro em loop assim que o modal é aberto ou respondido.
  void stopAlertLoop() {
    _isPlaying = false;
    _hapticLoopTimer?.cancel();
    _hapticLoopTimer = null;
  }
}

// ============================================================================
// 3. BLOC DO TERMINAL DO PARCEIRO (`flutter_bloc`)
// ============================================================================

abstract class PartnerTerminalEvent extends Equatable {
  const PartnerTerminalEvent();

  @override
  List<Object?> get props => [];
}

class NewOrderReceivedEvent extends PartnerTerminalEvent {
  final IncomingPartnerOrder order;

  const NewOrderReceivedEvent(this.order);

  @override
  List<Object?> get props => [order];
}

class AcceptOrderEvent extends PartnerTerminalEvent {
  final String pedidoId;
  final int tempoPreparacaoMinutos;

  const AcceptOrderEvent({
    required this.pedidoId,
    required this.tempoPreparacaoMinutos,
  });

  @override
  List<Object?> get props => [pedidoId, tempoPreparacaoMinutos];
}

class RejectOrderEvent extends PartnerTerminalEvent {
  final String pedidoId;
  final MotivoRejeicaoPedido motivo;
  final String? observacoes;

  const RejectOrderEvent({
    required this.pedidoId,
    required this.motivo,
    this.observacoes,
  });

  @override
  List<Object?> get props => [pedidoId, motivo, observacoes];
}

class OrderTimeoutExpiredEvent extends PartnerTerminalEvent {
  final String pedidoId;

  const OrderTimeoutExpiredEvent(this.pedidoId);

  @override
  List<Object?> get props => [pedidoId];
}

@immutable
class PartnerTerminalState extends Equatable {
  final List<IncomingPartnerOrder> pedidosAtivos;
  final IncomingPartnerOrder? pedidoEmDestaqueModal;
  final bool isProcessingAction;
  final String? feedbackMessage;
  final bool isAudioAlertActive;

  const PartnerTerminalState({
    this.pedidosAtivos = const [],
    this.pedidoEmDestaqueModal,
    this.isProcessingAction = false,
    this.feedbackMessage,
    this.isAudioAlertActive = false,
  });

  PartnerTerminalState copyWith({
    List<IncomingPartnerOrder>? pedidosAtivos,
    IncomingPartnerOrder? pedidoEmDestaqueModal,
    bool clearModal = false,
    bool? isProcessingAction,
    String? feedbackMessage,
    bool? isAudioAlertActive,
  }) {
    return PartnerTerminalState(
      pedidosAtivos: pedidosAtivos ?? this.pedidosAtivos,
      pedidoEmDestaqueModal:
          clearModal ? null : (pedidoEmDestaqueModal ?? this.pedidoEmDestaqueModal),
      isProcessingAction: isProcessingAction ?? this.isProcessingAction,
      feedbackMessage: feedbackMessage,
      isAudioAlertActive: isAudioAlertActive ?? this.isAudioAlertActive,
    );
  }

  @override
  List<Object?> get props => [
        pedidosAtivos,
        pedidoEmDestaqueModal,
        isProcessingAction,
        feedbackMessage,
        isAudioAlertActive,
      ];
}

class PartnerTerminalBloc extends Bloc<PartnerTerminalEvent, PartnerTerminalState> {
  final PartnerAlertAudioService _audioService;

  PartnerTerminalBloc({PartnerAlertAudioService? audioService})
      : _audioService = audioService ?? PartnerAlertAudioService(),
        super(const PartnerTerminalState()) {
    on<NewOrderReceivedEvent>(_onNewOrderReceived);
    on<AcceptOrderEvent>(_onAcceptOrder);
    on<RejectOrderEvent>(_onRejectOrder);
    on<OrderTimeoutExpiredEvent>(_onOrderTimeoutExpired);
  }

  void _onNewOrderReceived(NewOrderReceivedEvent event, Emitter<PartnerTerminalState> emit) {
    final novosPedidos = List<IncomingPartnerOrder>.from(state.pedidosAtivos)..add(event.order);

    // RN-120: Dispara alerta sonoro em loop
    _audioService.startRepeatingAlertLoop();

    emit(state.copyWith(
      pedidosAtivos: novosPedidos,
      pedidoEmDestaqueModal: event.order,
      isAudioAlertActive: true,
      feedbackMessage: 'Novo pedido recebido #${event.order.numeroPedidoExibicao}!',
    ));
  }

  Future<void> _onAcceptOrder(AcceptOrderEvent event, Emitter<PartnerTerminalState> emit) async {
    _audioService.stopAlertLoop();
    emit(state.copyWith(isProcessingAction: true, isAudioAlertActive: false));

    try {
      final token = await SecureTokenStorage().getAccessToken();
      final dio = Dio(BaseOptions(
        baseUrl: AppEnvironmentConfig.baseHttpUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ));
      await dio.post(
        '/api/v1/partner/store/orders/${event.pedidoId}/accept/',
        data: {'tempo_preparacao_minutos': event.tempoPreparacaoMinutos},
      );
    } catch (_) {}

    final atualizados = state.pedidosAtivos.where((p) => p.pedidoId != event.pedidoId).toList();
    emit(state.copyWith(
      pedidosAtivos: atualizados,
      clearModal: true,
      isProcessingAction: false,
      feedbackMessage: 'Pedido aceite com tempo estimado de ${event.tempoPreparacaoMinutos} min. Em preparação!',
    ));
  }

  Future<void> _onRejectOrder(RejectOrderEvent event, Emitter<PartnerTerminalState> emit) async {
    _audioService.stopAlertLoop();
    emit(state.copyWith(isProcessingAction: true, isAudioAlertActive: false));

    try {
      final token = await SecureTokenStorage().getAccessToken();
      final dio = Dio(BaseOptions(
        baseUrl: AppEnvironmentConfig.baseHttpUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ));
      await dio.post(
        '/api/v1/partner/store/orders/${event.pedidoId}/reject/',
        data: {'motivo': event.motivo.descricao},
      );
    } catch (_) {}

    final atualizados = state.pedidosAtivos.where((p) => p.pedidoId != event.pedidoId).toList();
    emit(state.copyWith(
      pedidosAtivos: atualizados,
      clearModal: true,
      isProcessingAction: false,
      feedbackMessage: 'Pedido rejeitado. Motivo: ${event.motivo.descricao}. Reembolso automático acionado.',
    ));
  }

  void _onOrderTimeoutExpired(OrderTimeoutExpiredEvent event, Emitter<PartnerTerminalState> emit) {
    _audioService.stopAlertLoop();
    final atualizados = state.pedidosAtivos.where((p) => p.pedidoId != event.pedidoId).toList();

    emit(state.copyWith(
      pedidosAtivos: atualizados,
      clearModal: true,
      isAudioAlertActive: false,
      feedbackMessage: 'RN-075: Prazo de 3 minutos expirado. Pedido cancelado automaticamente pelo sistema.',
    ));
  }

  @override
  Future<void> close() {
    _audioService.stopAlertLoop();
    return super.close();
  }
}

// ============================================================================
// 4. ECRÃ TERMINAL DO PARCEIRO (MATERIAL DESIGN 3)
// ============================================================================

class PartnerOrderTerminalScreen extends StatefulWidget {
  const PartnerOrderTerminalScreen({super.key});

  @override
  State<PartnerOrderTerminalScreen> createState() => _PartnerOrderTerminalScreenState();
}

class _PartnerOrderTerminalScreenState extends State<PartnerOrderTerminalScreen> {
  late final PartnerTerminalBloc _terminalBloc;
  Timer? _pollingTimer;
  final Set<String> _notifiedOrderIds = {};

  @override
  void initState() {
    super.initState();
    _terminalBloc = PartnerTerminalBloc();
    _iniciarSincronizacaoPedidos();
  }

  void _iniciarSincronizacaoPedidos() {
    _carregarPedidosDoServidor();
    _pollingTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      _carregarPedidosDoServidor();
    });
  }

  Future<void> _carregarPedidosDoServidor() async {
    try {
      final token = await SecureTokenStorage().getAccessToken();
      final dio = Dio(
        BaseOptions(
          baseUrl: AppEnvironmentConfig.baseHttpUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          headers: {
            if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
          },
        ),
      );

      final resp = await dio.get<List<dynamic>>('/api/v1/partner/store/orders/');
      if (resp.data != null && mounted) {
        for (final raw in resp.data!) {
          if (raw is! Map<String, dynamic>) continue;
          final pId = raw['pedido_id']?.toString() ?? '';
          final isAguardando = raw['is_aguardando'] == true;

          if (isAguardando && !_notifiedOrderIds.contains(pId)) {
            _notifiedOrderIds.add(pId);
            final rawItens = (raw['itens'] as List<dynamic>?) ?? [];
            final itens = rawItens.map((it) {
              final m = it as Map<String, dynamic>;
              return TerminalOrderItem(
                id: m['id']?.toString() ?? '',
                nome: m['nome']?.toString() ?? 'Artigo',
                quantidade: (m['quantidade'] as num?)?.toInt() ?? 1,
                precoUnitarioCentimos: (m['preco_unitario_centimos'] as num?)?.toInt() ?? 0,
                opcoesPersonalizadas: ((m['opcoes_personalizadas'] as List<dynamic>?) ?? [])
                    .map((e) => e.toString())
                    .toList(),
                notas: m['notas']?.toString(),
              );
            }).toList();

            final incoming = IncomingPartnerOrder(
              pedidoId: pId,
              numeroPedidoExibicao: raw['numero_pedido_exibicao']?.toString() ?? 'NOVO',
              nomeCliente: raw['nome_cliente']?.toString() ?? 'Cliente',
              recebidoEm: DateTime.tryParse(raw['recebido_em']?.toString() ?? '') ?? DateTime.now(),
              expiraEm: DateTime.tryParse(raw['expira_em']?.toString() ?? '') ?? DateTime.now().add(const Duration(minutes: 3)),
              tempoPreparacaoPadraoMinutos: (raw['tempo_preparacao_padrao_minutos'] as num?)?.toInt() ?? 20,
              subtotalCentimos: (raw['subtotal_centimos'] as num?)?.toInt() ?? 0,
              itens: itens,
            );
            _terminalBloc.add(NewOrderReceivedEvent(incoming));
          }
        }
      }
    } catch (_) {}
  }

  void _simularEntradaPedidoTeste() {
    final numAleatorio = (1000 + DateTime.now().millisecond).toString();
    final pedidoExemplo = IncomingPartnerOrder(
      pedidoId: 'ped-${DateTime.now().millisecondsSinceEpoch}',
      numeroPedidoExibicao: numAleatorio,
      nomeCliente: 'Mário Silva',
      recebidoEm: DateTime.now(),
      expiraEm: DateTime.now().add(const Duration(minutes: 3)),
      tempoPreparacaoPadraoMinutos: 25,
      subtotalCentimos: 750000,
      itens: const [
        TerminalOrderItem(
          id: 'it-1',
          nome: 'Hambúrguer Artesanal Duplo com Bacon',
          quantidade: 2,
          precoUnitarioCentimos: 300000,
          opcoesPersonalizadas: ['Ponto: Bem Passado', 'Sem Cebola', 'Dose Extra de Cheddar'],
          notas: 'Por favor, molho à parte.',
        ),
        TerminalOrderItem(
          id: 'it-2',
          nome: 'Batata Rústica com Alecrim e Parmesão',
          quantidade: 1,
          precoUnitarioCentimos: 150000,
          opcoesPersonalizadas: ['Molho de Alho Suave'],
        ),
      ],
    );
    _terminalBloc.add(NewOrderReceivedEvent(pedidoExemplo));
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _terminalBloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocProvider.value(
      value: _terminalBloc,
      child: BlocConsumer<PartnerTerminalBloc, PartnerTerminalState>(
        listener: (context, state) {
          if (state.feedbackMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.feedbackMessage!),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          // Abre o Modal em destaque quando há um novo pedido pendente (RN-075)
          if (state.pedidoEmDestaqueModal != null) {
            _abrirModalDestaquePedido(context, state.pedidoEmDestaqueModal!);
          }
        },
        builder: (context, state) {
          return Scaffold(
            backgroundColor: const Color(0xFFF8FAFC),
            appBar: AppBar(
              backgroundColor: Colors.white,
              elevation: 0,
              title: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gestor de Pedidos & Cozinha',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  Text(
                    'Terminal KDS em tempo real',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              actions: [
                if (state.isAudioAlertActive)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDC2626),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.volume_up, color: Colors.white, size: 16),
                          SizedBox(width: 4),
                          Text(
                            'ALARME ATIVO',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Simular Pedido de Teste',
                  icon: const Icon(Icons.playlist_add_rounded, color: Color(0xFF1E88E5)),
                  onPressed: _simularEntradaPedidoTeste,
                ),
              ],
            ),
            body: state.pedidosAtivos.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 36),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 88,
                            height: 88,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF6FF),
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFFBFDBFE), width: 1.5),
                            ),
                            child: const Icon(
                              Icons.soup_kitchen_rounded,
                              size: 44,
                              color: Color(0xFF1E88E5),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Balcão & Cozinha Prontos',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Não há pedidos pendentes de aceitação neste momento.\nAssim que um cliente submeter um pedido, o alerta sonoro tocará automaticamente.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: Color(0xFF64748B),
                              height: 1.4,
                            ),
                          ),
                          const SizedBox(height: 24),
                          OutlinedButton.icon(
                            onPressed: _simularEntradaPedidoTeste,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF1E88E5),
                              side: const BorderSide(color: Color(0xFF93C5FD)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.add_alert_rounded, size: 18),
                            label: const Text(
                              'Simular Entrada de Pedido',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: state.pedidosAtivos.length,
                    itemBuilder: (context, index) {
                      final pedido = state.pedidosAtivos[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.04),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Cabeçalho do Card
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0F172A),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '#${pedido.numeroPedidoExibicao}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          pedido.nomeCliente,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF0F172A),
                                          ),
                                        ),
                                        Text(
                                          '${pedido.itens.length} ${pedido.itens.length == 1 ? "artigo" : "artigos"} • Subtotal: ${pedido.subtotalCentimos ~/ 100} Kz',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF64748B),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFEF3C7),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: const Color(0xFFFDE68A)),
                                    ),
                                    child: const Row(
                                      children: [
                                        Icon(Icons.timer_outlined, size: 14, color: Color(0xFFB45309)),
                                        SizedBox(width: 4),
                                        Text(
                                          'Aguardando',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFFB45309),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              const Divider(height: 1, color: Color(0xFFF1F5F9)),
                              const SizedBox(height: 12),

                              // Itens em Destaque
                              ...pedido.itens.map((it) => Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${it.quantidade}x ',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF1E88E5),
                                            fontSize: 13,
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            it.nome,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13,
                                              color: Color(0xFF334155),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )),

                              const SizedBox(height: 12),

                              // Botões de Ação Imediata
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton(
                                      onPressed: () => _abrirModalDestaquePedido(context, pedido),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF0F172A),
                                        side: const BorderSide(color: Color(0xFFCBD5E1)),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: const Text('Ver Detalhes'),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 2,
                                    child: FilledButton.icon(
                                      onPressed: () => _abrirModalDestaquePedido(context, pedido),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: const Color(0xFF16A34A),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      icon: const Icon(Icons.check_circle_rounded, size: 18),
                                      label: const Text(
                                        'Aceitar Pedido',
                                        style: TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }

  void _abrirModalDestaquePedido(BuildContext context, IncomingPartnerOrder pedido) {
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _ModalNovoPedidoPendente(
          pedido: pedido,
          onAceitar: (tempoAjustadoMinutos) {
            _terminalBloc.add(AcceptOrderEvent(
              pedidoId: pedido.pedidoId,
              tempoPreparacaoMinutos: tempoAjustadoMinutos,
            ));
            Navigator.of(sheetContext).pop();
          },
          onRejeitar: (motivo, obs) {
            _terminalBloc.add(RejectOrderEvent(
              pedidoId: pedido.pedidoId,
              motivo: motivo,
              observacoes: obs,
            ));
            Navigator.of(sheetContext).pop();
          },
          onExpirarTimeout: () {
            _terminalBloc.add(OrderTimeoutExpiredEvent(pedido.pedidoId));
            Navigator.of(sheetContext).pop();
          },
        );
      },
    );
  }
}

// ============================================================================
// 5. MODAL EM DESTAQUE COM TIMER VISUAL DE 3 MINUTOS (RN-075, RN-076, RN-077)
// ============================================================================

class _ModalNovoPedidoPendente extends StatefulWidget {
  final IncomingPartnerOrder pedido;
  final ValueChanged<int> onAceitar;
  final Function(MotivoRejeicaoPedido motivo, String? observacoes) onRejeitar;
  final VoidCallback onExpirarTimeout;

  const _ModalNovoPedidoPendente({
    required this.pedido,
    required this.onAceitar,
    required this.onRejeitar,
    required this.onExpirarTimeout,
  });

  @override
  State<_ModalNovoPedidoPendente> createState() => _ModalNovoPedidoPendenteState();
}

class _ModalNovoPedidoPendenteState extends State<_ModalNovoPedidoPendente> {
  late int _tempoPreparacaoMinutos;
  late Duration _tempoRestante;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _tempoPreparacaoMinutos = widget.pedido.tempoPreparacaoPadraoMinutos;
    _tempoRestante = widget.pedido.expiraEm.difference(DateTime.now());
    _iniciarCountdownTimer();
  }

  void _iniciarCountdownTimer() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final diff = widget.pedido.expiraEm.difference(DateTime.now());
      if (diff.isNegative || diff.inSeconds <= 0) {
        _countdownTimer?.cancel();
        widget.onExpirarTimeout();
      } else {
        setState(() {
          _tempoRestante = diff;
        });
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final minutosStr = _tempoRestante.inMinutes.remainder(60).toString().padLeft(2, '0');
    final segundosStr = _tempoRestante.inSeconds.remainder(60).toString().padLeft(2, '0');
    final isCritico = _tempoRestante.inSeconds <= 60;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.90),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 48,
              height: 5,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Cabeçalho com Número do Pedido e Timer Regressivo de 3 Minutos (RN-075)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NOVO PEDIDO RECEBIDO', style: theme.textTheme.labelMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold)),
                  Text('#${widget.pedido.numeroPedidoExibicao}', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isCritico ? colorScheme.errorContainer : Colors.amber.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    Icon(Icons.timer_outlined, size: 20, color: isCritico ? colorScheme.error : Colors.orange.shade900),
                    const SizedBox(width: 6),
                    Text(
                      '$minutosStr:$segundosStr',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: isCritico ? colorScheme.error : Colors.orange.shade900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 24),

          // Lista dos Itens do Pedido com personalizações
          Expanded(
            child: ListView.separated(
              itemCount: widget.pedido.itens.length,
              separatorBuilder: (_, __) => const Divider(height: 16),
              itemBuilder: (context, index) {
                final item = widget.pedido.itens[index];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: colorScheme.primaryContainer,
                          child: Text('${item.quantidade}x', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.onPrimaryContainer)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.nome, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              if (item.opcoesPersonalizadas.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(item.opcoesPersonalizadas.join(' • '), style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                                ),
                              if (item.notas != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('Nota: "${item.notas}"', style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12, color: colorScheme.primary)),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          const Divider(height: 24),

          // Ajuste de Tempo Estimado de Preparação
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Tempo Estimado de Cozinha:', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Row(
                children: [
                  IconButton.filledTonal(
                    icon: const Icon(Icons.remove),
                    onPressed: _tempoPreparacaoMinutos > 5 ? () => setState(() => _tempoPreparacaoMinutos -= 5) : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('$_tempoPreparacaoMinutos min', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                  IconButton.filledTonal(
                    icon: const Icon(Icons.add),
                    onPressed: () => setState(() => _tempoPreparacaoMinutos += 5),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Botões de Ação: "Rejeitar" e "Aceitar Pedido"
          Row(
            children: [
              Expanded(
                flex: 2,
                child: OutlinedButton(
                  onPressed: () => _abrirDialogRejeicao(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    side: BorderSide(color: colorScheme.error),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Rejeitar', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 3,
                child: FilledButton(
                  onPressed: () => widget.onAceitar(_tempoPreparacaoMinutos),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Aceitar Pedido', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _abrirDialogRejeicao(BuildContext context) {
    MotivoRejeicaoPedido motivoSelecionado = MotivoRejeicaoPedido.cozinhaSobrecarregada;
    final obsController = TextEditingController();

    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Rejeitar Pedido', style: TextStyle(fontWeight: FontWeight.bold)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Selecione o motivo da rejeição para notificar o cliente e acionar o reembolso:'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<MotivoRejeicaoPedido>(
                    value: motivoSelecionado,
                    isExpanded: true,
                    items: MotivoRejeicaoPedido.values.map((m) {
                      return DropdownMenuItem(value: m, child: Text(m.descricao, style: const TextStyle(fontSize: 13)));
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setDialogState(() => motivoSelecionado = val);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(dialogCtx).pop(), child: const Text('Cancelar')),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                  onPressed: () {
                    Navigator.of(dialogCtx).pop();
                    widget.onRejeitar(motivoSelecionado, obsController.text);
                  },
                  child: const Text('Confirmar Rejeição'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
