/// Ecrã de Terminal de Pedidos para a App do Parceiro / Restaurante (`PartnerOrderTerminalScreen`).
/// Implementa a Secção 6.7 e as Regras de Negócio:
/// - RN-070 / RN-075: Receção em tempo real de pedidos no estado `AGUARDA_PARCEIRO` com contagem
///   decrescente visual de 3 minutos (180s) e alerta sonoro repetitivo em loop (RN-120).
/// - RN-076: Rejeição obrigatória fundamentada por motivo pré-definido (Cozinha sobrecarregada,
///   falta de stock de ingredientes, encerramento do estabelecimento, etc.).
/// - RN-077: Aceitação do pedido com confirmação ou ajuste do tempo estimado de preparação em minutos.
/// - RN-120: Alertas sonoros contínuos de alta prioridade para pedidos pendentes no balcão da loja.

import 'dart:async';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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

    // Simula chamada de aceitação à API `/api/v1/orders/{id}/accept/` com tempo estimado (RN-077)
    await Future.delayed(const Duration(milliseconds: 600));

    final atualizados = state.pedidosAtivos.where((p) => p.pedidoId != event.pedidoId).toList();
    emit(state.copyWith(
      pedidosAtivos: atualizados,
      clearModal: true,
      isProcessingAction: false,
      feedbackMessage: 'Pedido aceite com tempo estimado de ${event.tempoPreparacaoMinutos} min (RN-077).',
    ));
  }

  Future<void> _onRejectOrder(RejectOrderEvent event, Emitter<PartnerTerminalState> emit) async {
    _audioService.stopAlertLoop();
    emit(state.copyWith(isProcessingAction: true, isAudioAlertActive: false));

    // Simula chamada de rejeição à API `/api/v1/orders/{id}/reject/` com motivo obrigatório (RN-076)
    await Future.delayed(const Duration(milliseconds: 600));

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

  @override
  void initState() {
    super.initState();
    _terminalBloc = PartnerTerminalBloc();
    // Simula a entrada de um pedido teste após 1 segundo
    _simularEntradaPedidoTeste();
  }

  void _simularEntradaPedidoTeste() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      final pedidoExemplo = IncomingPartnerOrder(
        pedidoId: 'ped-778899',
        numeroPedidoExibicao: '4092',
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
    });
  }

  @override
  void dispose() {
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
            backgroundColor: colorScheme.surfaceContainerLowest,
            appBar: AppBar(
              title: const Text('Terminal de Cozinha & Balcão', style: TextStyle(fontWeight: FontWeight.w800)),
              actions: [
                if (state.isAudioAlertActive)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Chip(
                      avatar: const Icon(Icons.volume_up, color: Colors.white, size: 18),
                      label: const Text('ALARME ATIVO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      backgroundColor: colorScheme.error,
                    ),
                  ),
              ],
            ),
            body: state.pedidosAtivos.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.dinner_dining_outlined, size: 80, color: colorScheme.outlineVariant),
                        const SizedBox(height: 16),
                        Text('Nenhum pedido pendente de aceitação', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text('Novos pedidos no estado AGUARDA_PARCEIRO soarão automaticamente.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 24),
                        FilledButton.tonal(
                          onPressed: _simularEntradaPedidoTeste,
                          child: const Text('Simular Chegada de Novo Pedido'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: state.pedidosAtivos.length,
                    itemBuilder: (context, index) {
                      final pedido = state.pedidosAtivos[index];
                      return Card(
                        child: ListTile(
                          title: Text('Pedido #${pedido.numeroPedidoExibicao} - ${pedido.nomeCliente}'),
                          subtitle: Text('${pedido.itens.length} itens • Subtotal: ${pedido.subtotalCentimos ~/ 100} Kz'),
                          trailing: FilledButton(
                            onPressed: () => _abrirModalDestaquePedido(context, pedido),
                            child: const Text('Ver Detalhes'),
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

          // Ajuste de Tempo Estimado de Preparação (RN-077)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Tempo Estimado de Cozinha (RN-077):', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
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

          // Botões de Ação: "Rejeitar" (RN-076) e "Aceitar Pedido" (RN-077)
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
                  child: const Text('Rejeitar (RN-076)', style: TextStyle(fontWeight: FontWeight.bold)),
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
                  child: const Text('Aceitar Pedido (RN-077)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
              title: const Text('Rejeitar Pedido (RN-076)', style: TextStyle(fontWeight: FontWeight.bold)),
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
