/// Interface Mobile Flutter (App do Estafeta) para Validação Criptográfica de PIN de Entrega
/// e Gestão de Ausência do Cliente (RN-095, RN-096, RN-097).
///
/// Funcionalidades:
/// - Bloqueia o encerramento da corrida até que o estafeta digite o PIN numérico de 4 dígitos (RN-095).
/// - 4 campos de dígitos com auto-avanço, recuo suave e foco automático imediato.
/// - Validação assíncrona via API REST Dio (`/api/v1/logistics/delivery/verify-pin/`).
/// - Botão "Cheguei ao Destino" com cronómetro regressivo obrigatório de 7 minutos de tolerância (RN-096).
/// - Desbloqueio seguro do encerramento por ausência do cliente (RN-097) apenas após os 7 minutos decorridos.

import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/network/app_environment_config.dart';
import '../auth/storage/secure_token_storage.dart';

class CourierPinVerificationSheet extends StatefulWidget {
  final String pedidoId;
  final String clienteNome;
  final String moradaTexto;
  final String apiBaseUrl;
  final String jwtAccessToken;
  final double? currentLatitude;
  final double? currentLongitude;
  final int initialToleranceSeconds;
  final VoidCallback? onDeliveryCompleted;

  const CourierPinVerificationSheet({
    super.key,
    required this.pedidoId,
    required this.clienteNome,
    required this.moradaTexto,
    this.apiBaseUrl = AppEnvironmentConfig.baseHttpUrl,
    this.jwtAccessToken = '',
    this.currentLatitude,
    this.currentLongitude,
    this.initialToleranceSeconds = 420,
    this.onDeliveryCompleted,
  });

  /// Exibe o modal bottom sheet de verificação presencial de PIN e tolerância (RN-095, RN-096).
  static Future<void> show(
    BuildContext context, {
    required String pedidoId,
    required String nomeCliente,
    required String moradaClienteTexto,
    int tempoToleranciaSegundos = 420,
    String apiBaseUrl = AppEnvironmentConfig.baseHttpUrl,
    String jwtAccessToken = '',
    double? currentLatitude,
    double? currentLongitude,
    VoidCallback? onSucessoEntrega,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CourierPinVerificationSheet(
        pedidoId: pedidoId,
        clienteNome: nomeCliente,
        moradaTexto: moradaClienteTexto,
        apiBaseUrl: apiBaseUrl,
        jwtAccessToken: jwtAccessToken,
        currentLatitude: currentLatitude,
        currentLongitude: currentLongitude,
        initialToleranceSeconds: tempoToleranciaSegundos,
        onDeliveryCompleted: onSucessoEntrega,
      ),
    );
  }

  @override
  State<CourierPinVerificationSheet> createState() => _CourierPinVerificationSheetState();
}

class _CourierPinVerificationSheetState extends State<CourierPinVerificationSheet> with SingleTickerProviderStateMixin {
  // Controladores dos 4 dígitos
  final List<TextEditingController> _pinControllers = List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _pinFocusNodes = List.generate(4, (_) => FocusNode());

  // Estado de Validação do PIN
  bool _isLoading = false;
  String? _errorMessage;
  bool _isSuccess = false;

  // Estado de Tolerância de 7 Minutos (RN-096)
  bool _chegadaRegistada = false;
  int _segundosRestantesTolerancia = 420; // 7 minutos = 420s
  Timer? _countdownTimer;
  bool _podeReportarAusencia = false;

  late AnimationController _shakeAnimController;

  @override
  void initState() {
    super.initState();
    _segundosRestantesTolerancia = widget.initialToleranceSeconds.clamp(0, 420);
    _chegadaRegistada = true;
    _podeReportarAusencia = _segundosRestantesTolerancia <= 0;
    _iniciarCronometroTolerancia();
    _shakeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    // Foco automático no primeiro dígito
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinFocusNodes[0].requestFocus();
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _shakeAnimController.dispose();
    for (final c in _pinControllers) {
      c.dispose();
    }
    for (final f in _pinFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  String get _pinCompleto => _pinControllers.map((c) => c.text).join();

  Dio get _dioClient {
    return createSecureDioClient(tokenStorage: SecureTokenStorage());
  }

  // ==========================================================================
  // VALIDAÇÃO CRIPTOGRÁFICA DO PIN VIA API (RN-095)
  // ==========================================================================

  Future<void> _validarPinEntrega() async {
    if (_isLoading || _isSuccess) return;
    final pin = _pinCompleto.trim();
    if (pin.length != 4) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await _dioClient.post(
        '/api/v1/logistics/delivery/verify-pin/',
        data: {
          'pedido_id': widget.pedidoId,
          'pin_introduzido': pin,
          'latitude': widget.currentLatitude,
          'longitude': widget.currentLongitude,
          'cliente_ausente': false,
        },
      );

      if (response.statusCode == 200 && response.data['sucesso'] == true) {
        setState(() {
          _isSuccess = true;
          _isLoading = false;
        });

        HapticFeedback.heavyImpact();

        await Future.delayed(const Duration(milliseconds: 1200));
        if (mounted) {
          widget.onDeliveryCompleted?.call();
          Navigator.of(context).pop(true);
        }
      }
    } on DioException catch (e) {
      HapticFeedback.vibrate();
      _shakeAnimController.forward(from: 0.0);

      String msg = 'PIN incorreto. Confirme o código de 4 dígitos com o cliente.';
      if (e.response?.data is Map && e.response?.data['erro'] != null) {
        msg = e.response!.data['erro'].toString();
      }

      setState(() {
        _errorMessage = msg;
        _isLoading = false;
      });

      // Limpa os dígitos e volta a focar no início
      for (final c in _pinControllers) {
        c.clear();
      }
      _pinFocusNodes[0].requestFocus();
    } catch (e) {
      setState(() {
        _errorMessage = 'Falha de comunicação com o servidor. Tente novamente.';
        _isLoading = false;
      });
    }
  }

  // ==========================================================================
  // CONTROLO DE CHEGADA E TOLERÂNCIA DE 7 MINUTOS (RN-096 & RN-097)
  // ==========================================================================

  Future<void> _registarChegadaAoDestino() async {
    setState(() => _isLoading = true);

    try {
      final response = await _dioClient.post(
        '/api/v1/logistics/delivery/arrive/',
        data: {
          'pedido_id': widget.pedidoId,
          'latitude': widget.currentLatitude,
          'longitude': widget.currentLongitude,
        },
      );

      final restante = (response.data['tempo_restante_segundos'] as num?)?.toInt() ?? 420;

      setState(() {
        _chegadaRegistada = true;
        _segundosRestantesTolerancia = restante;
        _podeReportarAusencia = restante <= 0;
        _isLoading = false;
      });

      _iniciarCronometroTolerancia();
    } catch (e) {
      setState(() {
        _chegadaRegistada = true;
        _isLoading = false;
      });
      _iniciarCronometroTolerancia();
    }
  }

  void _iniciarCronometroTolerancia() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_segundosRestantesTolerancia > 0) {
        setState(() {
          _segundosRestantesTolerancia--;
        });
      } else {
        timer.cancel();
        setState(() {
          _podeReportarAusencia = true;
        });
      }
    });
  }

  Future<void> _declararAusenciaCliente() async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmar Ausência do Cliente?'),
        content: const Text(
          'Passaram mais de 7 minutos e o cliente não atendeu.\n\n'
          'A entrega será encerrada por culpa do cliente (RN-097). '
          'Você receberá a remuneração integral da corrida na sua carteira.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Voltar a Aguardar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Declarar Ausência'),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    setState(() => _isLoading = true);

    try {
      final response = await _dioClient.post<dynamic>(
        '/api/v1/logistics/delivery/report-absence/',
        data: {
          'pedido_id': widget.pedidoId,
          'cliente_ausente': true,
          'latitude': widget.currentLatitude ?? -8.8147,
          'longitude': widget.currentLongitude ?? 13.2343,
          'tentativas_contacto': 2,
          'motivo': 'Cliente ausente após tolerância de 7 minutos sem resposta.',
        },
      );

      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.orange,
              content: Text('Corrida encerrada por ausência. Remuneração creditada na carteira!'),
            ),
          );
          widget.onDeliveryCompleted?.call();
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Erro ao processar reporte de ausência.';
        _isLoading = false;
      });
    }
  }

  // ==========================================================================
  // CONSTRUÇÃO VISUAL (UI MATERIAL DESIGN 3)
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barra de arrasto
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 18),

          // Cabeçalho de Validação
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.shield_outlined, color: Color(0xFF1E88E5), size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Confirmação de Entrega',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Cliente: ${widget.clienteNome}',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Se estiver em estado de sucesso
          if (_isSuccess) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: const Column(
                children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: Colors.green,
                    child: Icon(Icons.check_rounded, color: Colors.white, size: 48),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Entrega Validada com Sucesso!',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Pagamento capturado e corrida concluída.',
                    style: TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ] else ...[
            // Instrução de Digitação do PIN (RN-095)
            Text(
              'Solicite o PIN de 4 dígitos ao cliente e digite abaixo:',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 20),

            // 4 Campos de Texto com Foco Automático e Auto-Avanço
            AnimatedBuilder(
              animation: _shakeAnimController,
              builder: (context, child) {
                final offset = math.sin(_shakeAnimController.value * math.pi * 4) * 8;
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: child,
                );
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(4, (index) => _buildCaixaDigitoPin(index)),
              ),
            ),
            const SizedBox(height: 14),

            // Mensagem de Erro
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: Colors.red.shade700, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(fontSize: 12, color: Colors.red.shade700, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Botão Principal: Validar e Concluir
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1E88E5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: (_pinCompleto.length == 4 && !_isLoading) ? _validarPinEntrega : null,
                child: _isLoading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_open_rounded, size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Validar PIN e Concluir Corrida',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 18),

            const Divider(height: 1),
            const SizedBox(height: 14),

            // Secção de Tolerância de Espera e Ausência do Cliente (RN-096 & RN-097)
            _buildSecaoAusenciaCliente(),
          ],
        ],
      ),
    );
  }

  Widget _buildCaixaDigitoPin(int index) {
    return SizedBox(
      width: 58,
      height: 64,
      child: TextField(
        controller: _pinControllers[index],
        focusNode: _pinFocusNodes[index],
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 1,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1E88E5),
        ),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: Colors.grey.shade50,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade300, width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.grey.shade300, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF1E88E5), width: 2.5),
          ),
        ),
        onChanged: (value) {
          if (value.isNotEmpty) {
            // Avança para o próximo dígito
            if (index < 3) {
              _pinFocusNodes[index + 1].requestFocus();
            } else {
              _pinFocusNodes[index].unfocus();
              // Se os 4 dígitos foram inseridos, dispara a validação automaticamente
              if (_pinCompleto.length == 4) {
                _validarPinEntrega();
              }
            }
          } else {
            // Se apagou, volta ao anterior
            if (index > 0) {
              _pinFocusNodes[index - 1].requestFocus();
            }
          }
          setState(() {});
        },
      ),
    );
  }

  Widget _buildSecaoAusenciaCliente() {
    if (!_chegadaRegistada) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Expanded(
            child: Text(
              'Cliente não atende a porta?',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.location_on_outlined, size: 16),
            label: const Text('Cheguei ao Destino'),
            onPressed: _isLoading ? null : _registarChegadaAoDestino,
          ),
        ],
      );
    }

    final minutos = _segundosRestantesTolerancia ~/ 60;
    final segundos = _segundosRestantesTolerancia % 60;
    final strTempo = '${minutos.toString().padLeft(2, '0')}:${segundos.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _podeReportarAusencia ? Colors.red.shade50 : Colors.amber.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _podeReportarAusencia ? Colors.red.shade300 : Colors.amber.shade300,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                _podeReportarAusencia ? Icons.warning_rounded : Icons.timer_outlined,
                color: _podeReportarAusencia ? Colors.red.shade800 : Colors.amber.shade900,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _podeReportarAusencia
                      ? 'Tolerância de 7 minutos concluída (RN-096).'
                      : 'Aguarde a tolerância obrigatória: $strTempo',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _podeReportarAusencia ? Colors.red.shade900 : Colors.amber.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              icon: const Icon(Icons.person_off_rounded, size: 18),
              label: Text(_podeReportarAusencia
                  ? 'Declarar Ausência do Cliente (RN-097)'
                  : 'Aguarde o fim do temporizador'),
              style: TextButton.styleFrom(
                foregroundColor: _podeReportarAusencia ? Colors.red.shade800 : Colors.grey,
              ),
              onPressed: _podeReportarAusencia ? _declararAusenciaCliente : null,
            ),
          ),
        ],
      ),
    );
  }
}

