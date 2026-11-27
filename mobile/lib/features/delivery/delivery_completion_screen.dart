/// Ecrã de Encerramento e Prova de Entrega (`DeliveryCompletionScreen`)
/// para a aplicação móvel do Estafeta em Flutter.
///
/// Implementa rigorosamente:
/// - Regra RN-095: Validação criptográfica presencial com PIN aleatório de 4 dígitos;
/// - Regra RN-096: Tolerância de espera de 7 minutos (420s) com cronómetro regressivo visual e botão bloqueado;
/// - Regra RN-097: Encerramento de corrida por ausência culposa do cliente com garantia de remuneração do estafeta;
/// - Animação de erro (Shake) e feedback háptico em caso de PIN inválido;
/// - Gestão de Estado BLoC (`flutter_bloc`) e arquitetura Material Design 3.
library delivery_completion_screen;

import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/app_environment_config.dart';
import '../auth/storage/secure_token_storage.dart';

// ============================================================================
// 1. CAMADA DE DADOS E REPOSITÓRIO API DO ESTAFETA
// ============================================================================

class DeliveryRepository {
  final Dio _dio;

  DeliveryRepository({Dio? dio})
      : _dio = dio ??
            createSecureDioClient(
              tokenStorage: SecureTokenStorage(),
            );

  /// POST /api/v1/logistics/delivery/verify-pin/ (RN-095)
  Future<Map<String, dynamic>> verifyPin({
    required String pedidoId,
    required String pinIntroduzido,
    double? latitude,
    double? longitude,
  }) async {
    final response = await _dio.post(
      '/api/v1/logistics/delivery/verify-pin/',
      data: {
        'pedido_id': pedidoId,
        'pin_introduzido': pinIntroduzido,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// POST /api/v1/logistics/delivery/report-absence/ (RN-096 / RN-097)
  Future<Map<String, dynamic>> reportAbsence({
    required String pedidoId,
    required double latitude,
    required double longitude,
    int tentativasContacto = 2,
    String? motivo,
  }) async {
    final response = await _dio.post(
      '/api/v1/logistics/delivery/report-absence/',
      data: {
        'pedido_id': pedidoId,
        'latitude': latitude,
        'longitude': longitude,
        'tentativas_contacto': tentativasContacto,
        if (motivo != null) 'motivo': motivo,
      },
    );
    return response.data as Map<String, dynamic>;
  }
}

// ============================================================================
// 2. CAMADA DE ESTADO BLoC: Events, States e DeliveryCompletionBloc
// ============================================================================

abstract class DeliveryCompletionEvent extends Equatable {
  const DeliveryCompletionEvent();
  @override
  List<Object?> get props => [];
}

class SubmitPinCodeEvent extends DeliveryCompletionEvent {
  final String pedidoId;
  final String pinCode;
  final double? latitude;
  final double? longitude;

  const SubmitPinCodeEvent({
    required this.pedidoId,
    required this.pinCode,
    this.latitude,
    this.longitude,
  });

  @override
  List<Object?> get props => [pedidoId, pinCode, latitude, longitude];
}

class ReportAbsenceEvent extends DeliveryCompletionEvent {
  final String pedidoId;
  final double latitude;
  final double longitude;
  final int tentativasContacto;
  final String motivo;

  const ReportAbsenceEvent({
    required this.pedidoId,
    required this.latitude,
    required this.longitude,
    this.tentativasContacto = 2,
    required this.motivo,
  });

  @override
  List<Object?> get props => [pedidoId, latitude, longitude, tentativasContacto, motivo];
}

abstract class DeliveryCompletionState extends Equatable {
  const DeliveryCompletionState();
  @override
  List<Object?> get props => [];
}

class DeliveryCompletionInitial extends DeliveryCompletionState {}

class DeliveryCompletionLoading extends DeliveryCompletionState {}

class DeliveryPinSuccessState extends DeliveryCompletionState {
  final String mensagem;
  final String pedidoId;

  const DeliveryPinSuccessState({
    required this.mensagem,
    required this.pedidoId,
  });

  @override
  List<Object?> get props => [mensagem, pedidoId];
}

class DeliveryPinInvalidState extends DeliveryCompletionState {
  final String mensagem;
  final int tentativasRestantes;

  const DeliveryPinInvalidState({
    required this.mensagem,
    required this.tentativasRestantes,
  });

  @override
  List<Object?> get props => [mensagem, tentativasRestantes];
}

class DeliveryAbsenceSuccessState extends DeliveryCompletionState {
  final String mensagem;
  final int remuneracaoEstafeta;

  const DeliveryAbsenceSuccessState({
    required this.mensagem,
    required this.remuneracaoEstafeta,
  });

  @override
  List<Object?> get props => [mensagem, remuneracaoEstafeta];
}

class DeliveryCompletionFailureState extends DeliveryCompletionState {
  final String erro;
  const DeliveryCompletionFailureState(this.erro);

  @override
  List<Object?> get props => [erro];
}

class DeliveryCompletionBloc extends Bloc<DeliveryCompletionEvent, DeliveryCompletionState> {
  final DeliveryRepository _repository;

  DeliveryCompletionBloc({DeliveryRepository? repository})
      : _repository = repository ?? DeliveryRepository(),
        super(DeliveryCompletionInitial()) {
    on<SubmitPinCodeEvent>(_onSubmitPin);
    on<ReportAbsenceEvent>(_onReportAbsence);
  }

  Future<void> _onSubmitPin(
    SubmitPinCodeEvent event,
    Emitter<DeliveryCompletionState> emit,
  ) async {
    emit(DeliveryCompletionLoading());
    try {
      final res = await _repository.verifyPin(
        pedidoId: event.pedidoId,
        pinIntroduzido: event.pinCode,
        latitude: event.latitude,
        longitude: event.longitude,
      );

      emit(DeliveryPinSuccessState(
        mensagem: res['mensagem'] ?? 'PIN validado com sucesso!',
        pedidoId: event.pedidoId,
      ));
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map && data['codigo'] == 'INVALID_PIN') {
        final restantes = data['tentativas_restantes'] ?? 3;
        emit(DeliveryPinInvalidState(
          mensagem: data['erro'] ?? 'PIN incorreto.',
          tentativasRestantes: restantes is int ? restantes : 3,
        ));
      } else {
        final erroMsg = data is Map ? (data['erro'] ?? 'Falha ao validar PIN.') : 'Erro de rede.';
        emit(DeliveryCompletionFailureState(erroMsg.toString()));
      }
    } catch (e) {
      emit(DeliveryCompletionFailureState('Erro inesperado: $e'));
    }
  }

  Future<void> _onReportAbsence(
    ReportAbsenceEvent event,
    Emitter<DeliveryCompletionState> emit,
  ) async {
    emit(DeliveryCompletionLoading());
    try {
      final res = await _repository.reportAbsence(
        pedidoId: event.pedidoId,
        latitude: event.latitude,
        longitude: event.longitude,
        tentativasContacto: event.tentativasContacto,
        motivo: event.motivo,
      );

      emit(DeliveryAbsenceSuccessState(
        mensagem: res['mensagem'] ?? 'Ausência confirmada e remunerada.',
        remuneracaoEstafeta: res['remuneracao_estafeta'] ?? 0,
      ));
    } on DioException catch (e) {
      final data = e.response?.data;
      final erroMsg = data is Map ? (data['erro'] ?? 'Falha ao reportar ausência.') : 'Erro de conexão.';
      emit(DeliveryCompletionFailureState(erroMsg.toString()));
    } catch (e) {
      emit(DeliveryCompletionFailureState('Erro inesperado: $e'));
    }
  }
}

// ============================================================================
// 3. INTERFACE UI: DeliveryCompletionScreen (Estafeta)
// ============================================================================

class DeliveryCompletionScreen extends StatefulWidget {
  final String pedidoId;
  final String nomeCliente;
  final String moradaCliente;
  final String telemovelCliente;
  final String itensResumo;
  final String notasCliente;
  final double localizacaoLat;
  final double localizacaoLng;

  const DeliveryCompletionScreen({
    super.key,
    required this.pedidoId,
    this.nomeCliente = 'Anselmo Fernandes',
    this.moradaCliente = 'Rua Rainha Ginga, Edifício Bengo, 3º Andar, Luanda',
    this.telemovelCliente = '+244923888777',
    this.itensResumo = '2x Mufete Completo + 1x Cuca Gelada',
    this.notasCliente = 'Tocar na campainha do 3º Andar. Deixar com o porteiro se não atender.',
    this.localizacaoLat = -8.8145,
    this.localizacaoLng = 13.2380,
  });

  @override
  State<DeliveryCompletionScreen> createState() => _DeliveryCompletionScreenState();
}

class _DeliveryCompletionScreenState extends State<DeliveryCompletionScreen>
    with SingleTickerProviderStateMixin {
  // 4 Caixas de PIN
  final List<TextEditingController> _pinControllers = List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _pinFocusNodes = List.generate(4, (_) => FocusNode());

  // Cronómetro de Tolerância de 7 Minutos (RN-096: 420 segundos)
  static const int _toleranciaTotalSegundos = 420;
  int _segundosRestantes = _toleranciaTotalSegundos;
  Timer? _countdownTimer;
  bool _toleranciaEsgotada = false;

  // Animação de Shake para PIN Inválido
  late final AnimationController _shakeAnimController;
  late final Animation<double> _shakeAnimation;
  bool _mostrarBordaErro = false;

  @override
  void initState() {
    super.initState();

    // Configura animação de shake
    _shakeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shakeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _shakeAnimController, curve: Curves.easeInOut),
    );

    _iniciarCronometroEspera();
  }

  void _iniciarCronometroEspera() {
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_segundosRestantes > 0) {
        setState(() {
          _segundosRestantes--;
        });
      } else {
        timer.cancel();
        setState(() {
          _toleranciaEsgotada = true;
        });
        HapticFeedback.vibrate();
      }
    });
  }

  void _executarShakeErro() {
    HapticFeedback.heavyImpact();
    setState(() {
      _mostrarBordaErro = true;
    });
    _shakeAnimController.forward(from: 0.0).then((_) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          setState(() {
            _mostrarBordaErro = false;
          });
        }
      });
    });
  }

  String _obterPinCompleto() {
    return _pinControllers.map((c) => c.text.trim()).join();
  }

  void _limparPin() {
    for (var c in _pinControllers) {
      c.clear();
    }
    _pinFocusNodes.first.requestFocus();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _shakeAnimController.dispose();
    for (var c in _pinControllers) {
      c.dispose();
    }
    for (var f in _pinFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  String _formatarTempoRestante(int totalSegundos) {
    final minutos = totalSegundos ~/ 60;
    final segundos = totalSegundos % 60;
    return '${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocProvider(
      create: (_) => DeliveryCompletionBloc(),
      child: BlocConsumer<DeliveryCompletionBloc, DeliveryCompletionState>(
        listener: (context, state) {
          if (state is DeliveryPinSuccessState) {
            _mostrarDialogoSucesso(
              context: context,
              titulo: 'Entrega Concluída com Sucesso!',
              mensagem: 'O PIN foi validado e a corrida foi encerrada.',
              isFalhaAusencia: false,
            );
          } else if (state is DeliveryAbsenceSuccessState) {
            _mostrarDialogoSucesso(
              context: context,
              titulo: 'Ausência Reportada (RN-097)',
              mensagem:
                  'A corrida foi encerrada por cliente ausente. O valor do frete foi creditado na sua carteira.',
              isFalhaAusencia: true,
            );
          } else if (state is DeliveryPinInvalidState) {
            _executarShakeErro();
            _limparPin();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: theme.colorScheme.error,
                content: Text(
                  '${state.mensagem} Restam ${state.tentativasRestantes} tentativas antes de bloqueio.',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            );
          } else if (state is DeliveryCompletionFailureState) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: theme.colorScheme.error,
                content: Text(state.erro),
              ),
            );
          }
        },
        builder: (context, state) {
          final isLoading = state is DeliveryCompletionLoading;

          return Scaffold(
            appBar: AppBar(
              title: const Text(
                'Confirmação de Entrega (RN-095)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              centerTitle: true,
              elevation: 0,
            ),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. Card de Dados do Cliente e Pedido
                    _buildCustomerCard(theme),

                    const SizedBox(height: 24),

                    // 2. Título de Instrução do PIN
                    const Text(
                      'Insere o PIN de Entrega',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Pede o código numérico de 4 dígitos ao cliente presencialmente:',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                    ),

                    const SizedBox(height: 20),

                    // 3. Campo Numérico de 4 Caixas Individuais com Shake Animation
                    _buildPinInputBoxes(theme),

                    const SizedBox(height: 28),

                    // 4. Botão Principal: Validar PIN de Segurança
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: isLoading
                          ? null
                          : () {
                              final pin = _obterPinCompleto();
                              if (pin.length != 4) {
                                _executarShakeErro();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Insira os 4 dígitos do PIN de entrega.')),
                                );
                                return;
                              }
                              context.read<DeliveryCompletionBloc>().add(
                                    SubmitPinCodeEvent(
                                      pedidoId: widget.pedidoId,
                                      pinCode: pin,
                                      latitude: widget.localizacaoLat,
                                      longitude: widget.localizacaoLng,
                                    ),
                                  );
                            },
                      icon: isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                            )
                          : const Icon(Icons.verified_user_rounded),
                      label: Text(
                        isLoading ? 'A Validar...' : 'Validar PIN de Segurança',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),

                    const SizedBox(height: 32),
                    const Divider(height: 1),
                    const SizedBox(height: 20),

                    // 5. Bloco de Ausência do Cliente (RN-096 e RN-097)
                    _buildAbsenceSection(context, theme, isLoading),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCustomerCard(ThemeData theme) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(Icons.person_rounded, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.nomeCliente,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        'Pedido #${widget.pedidoId.substring(0, 8)}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  icon: const Icon(Icons.phone_outlined),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('A ligar para ${widget.telemovelCliente}...')),
                    );
                  },
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.location_on_outlined, size: 20, color: Colors.redAccent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.moradaCliente,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.receipt_long_outlined, size: 20, color: Colors.black54),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.itensResumo,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
            if (widget.notasCliente.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.speaker_notes_outlined, size: 18, color: Colors.amber.shade900),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.notasCliente,
                        style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
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

  Widget _buildPinInputBoxes(ThemeData theme) {
    return AnimatedBuilder(
      animation: _shakeAnimation,
      builder: (context, child) {
        final offset = sin(_shakeAnimation.value * pi * 4) * 12;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: child,
        );
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(4, (index) {
          return Container(
            width: 62,
            height: 72,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _mostrarBordaErro
                    ? theme.colorScheme.error
                    : (_pinFocusNodes[index].hasFocus
                        ? theme.colorScheme.primary
                        : Colors.grey.shade300),
                width: _pinFocusNodes[index].hasFocus || _mostrarBordaErro ? 2.5 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: TextField(
              controller: _pinControllers[index],
              focusNode: _pinFocusNodes[index],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 1,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: _mostrarBordaErro ? theme.colorScheme.error : theme.colorScheme.onSurface,
              ),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
              ),
              onChanged: (val) {
                if (val.isNotEmpty && index < 3) {
                  _pinFocusNodes[index + 1].requestFocus();
                } else if (val.isEmpty && index > 0) {
                  _pinFocusNodes[index - 1].requestFocus();
                }
              },
            ),
          );
        }),
      ),
    );
  }

  Widget _buildAbsenceSection(BuildContext context, ThemeData theme, bool isLoading) {
    final progresso = 1.0 - (_segundosRestantes / _toleranciaTotalSegundos);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.hourglass_top_rounded,
                    size: 18, color: _toleranciaEsgotada ? Colors.green : Colors.orange),
                const SizedBox(width: 6),
                const Text(
                  'Tempo de Espera (RN-096):',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            Text(
              _toleranciaEsgotada ? '7 min concluídos' : _formatarTempoRestante(_segundosRestantes),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: _toleranciaEsgotada ? Colors.green : Colors.orange.shade800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progresso,
            minHeight: 8,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(
              _toleranciaEsgotada ? Colors.green : Colors.orange,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _toleranciaEsgotada
              ? 'Tolerância regulamentar cumprida. Já podes reportar ausência do cliente se ele não atender.'
              : 'O botão "Cliente Ausente" fica ativo após 7 minutos de espera no local.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            side: BorderSide(
              color: _toleranciaEsgotada ? Colors.orange.shade800 : Colors.grey.shade400,
              width: 1.5,
            ),
            foregroundColor: _toleranciaEsgotada ? Colors.orange.shade900 : Colors.grey.shade500,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          onPressed: (!_toleranciaEsgotada || isLoading)
              ? null
              : () => _confirmarReporteAusencia(context),
          icon: const Icon(Icons.person_off_rounded),
          label: Text(
            _toleranciaEsgotada
                ? 'Cliente Ausente (RN-096 / RN-097)'
                : 'Aguarde ${_formatarTempoRestante(_segundosRestantes)} para Cliente Ausente',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),
      ],
    );
  }

  void _confirmarReporteAusencia(BuildContext blocContext) {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Declarar Falha de Entrega?'),
        content: const Text(
          'Confirmas que aguardaste 7 minutos no local e tentaste contactar o cliente por chamada?\n\n'
          'Ao confirmar, a corrida será encerrada como FALHA DE ENTREGA por culpa do cliente (RN-097) '
          'e a remuneração integral do frete será creditada na tua carteira.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.orange.shade900),
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              blocContext.read<DeliveryCompletionBloc>().add(
                    ReportAbsenceEvent(
                      pedidoId: widget.pedidoId,
                      latitude: widget.localizacaoLat,
                      longitude: widget.localizacaoLng,
                      tentativasContacto: 2,
                      motivo: 'Cliente ausente e incontactável após 7 minutos no endereço.',
                    ),
                  );
            },
            child: const Text('Confirmar Ausência'),
          ),
        ],
      ),
    );
  }

  void _mostrarDialogoSucesso({
    required BuildContext context,
    required String titulo,
    required String mensagem,
    required bool isFalhaAusencia,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          isFalhaAusencia ? Icons.info_outline_rounded : Icons.check_circle_outline_rounded,
          color: isFalhaAusencia ? Colors.orange : Colors.green,
          size: 48,
        ),
        title: Text(titulo, textAlign: TextAlign.center),
        content: Text(mensagem, textAlign: TextAlign.center),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).maybePop();
            },
            child: const Text('Voltar ao Dashboard'),
          ),
        ],
      ),
    );
  }
}

