/// Ecrã 3: `OtpVerificationScreen`
/// Interface para introdução do código OTP de 6 dígitos com campos individuais e movimentação automática de foco.
/// Integra contador decrescente visual de 5 minutos alimentado por Stream (RN-002),
/// bloqueando o reenvio até ao fim do TTL e comunicando com o AuthBloc.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../auth_bloc.dart';
import '../theme/role_theme.dart';
import 'registration_form_screen.dart';

class OtpVerificationScreen extends StatefulWidget {
  final String phone;
  final DateTime expiraEm;
  final int validadeMinutos;
  final PlatformRole selectedRole;

  const OtpVerificationScreen({
    super.key,
    required this.phone,
    required this.expiraEm,
    required this.validadeMinutos,
    required this.selectedRole,
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  static const int _pinLength = 6;
  final List<TextEditingController> _controllers = [];
  final List<FocusNode> _focusNodes = [];

  late StreamController<int> _timerController;
  Timer? _countdownTimer;
  int _secondsRemaining = 300; // 5 minutos por padrão (RN-002)

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < _pinLength; i++) {
      _controllers.add(TextEditingController());
      _focusNodes.add(FocusNode());
    }

    _initCountdown();
  }

  void _initCountdown() {
    _timerController = StreamController<int>.broadcast();
    final now = DateTime.now();
    final difference = widget.expiraEm.difference(now).inSeconds;
    _secondsRemaining = difference > 0 ? difference : widget.validadeMinutos * 60;

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0) {
        _secondsRemaining--;
        if (!_timerController.isClosed) {
          _timerController.add(_secondsRemaining);
        }
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _timerController.close();
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  String get _currentOtpCode {
    return _controllers.map((c) => c.text).join();
  }

  void _onDigitChanged(int index, String value) {
    if (value.isNotEmpty) {
      // Avança para o próximo campo se existir
      if (index < _pinLength - 1) {
        _focusNodes[index + 1].requestFocus();
      } else {
        // Se preencheu o último dígito, fecha o teclado e submete automaticamente
        _focusNodes[index].unfocus();
        if (_currentOtpCode.length == _pinLength) {
          _submitOtp();
        }
      }
    }
    setState(() {});
  }

  void _onRawKeyEvent(RawKeyEvent event, int index) {
    if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_controllers[index].text.isEmpty && index > 0) {
        // Retrocede o foco ao apagar
        _focusNodes[index - 1].requestFocus();
        _controllers[index - 1].clear();
        setState(() {});
      }
    }
  }

  void _submitOtp() {
    final code = _currentOtpCode;
    if (code.length == _pinLength) {
      context.read<AuthBloc>().add(
            VerifyOtpSubmitted(phone: widget.phone, code: code),
          );
    }
  }

  void _resendOtp() {
    if (_secondsRemaining <= 0) {
      context.read<AuthBloc>().add(
            RequestOtpRequested(phone: widget.phone),
          );
      _secondsRemaining = widget.validadeMinutos * 60;
      _initCountdown();
      setState(() {});
    }
  }

  void _clearPinFields() {
    for (final controller in _controllers) {
      controller.clear();
    }
    if (_focusNodes.isNotEmpty) {
      _focusNodes.first.requestFocus();
    }
    setState(() {});
  }

  String _formatTimer(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = widget.selectedRole.primaryColor;
    final isPinComplete = _currentOtpCode.length == _pinLength;

    return BlocConsumer<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is Authenticated) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.verified_user_rounded, color: Colors.white),
                  const SizedBox(width: 12.0),
                  Expanded(child: Text('Bem-vindo, ${state.user.nome}!')),
                ],
              ),
              backgroundColor: const Color(0xFF10B981),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
            ),
          );

          // Navega para o destino correspondente ao papel (pop até a raiz)
          Navigator.of(context).popUntil((route) => route.isFirst);
        } else if (state is RegistrationRequired) {
          // Utilizador validou o telemóvel mas ainda não preencheu dados de perfil (RN-003)
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => RegistrationFormScreen(
                phone: state.phone,
                selectedRole: widget.selectedRole,
              ),
            ),
          );
        } else if (state is OtpVerificationFailure) {
          _clearPinFields();

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.white),
                  const SizedBox(width: 12.0),
                  Expanded(
                    child: Text(
                      state.tentativasRestantes != null
                          ? '${state.message} (Tentativas restantes: ${state.tentativasRestantes})'
                          : state.message,
                    ),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFFEF4444),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
            ),
          );
        }
      },
      builder: (context, state) {
        final isLoading = state is AuthLoading;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A)),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Ícone de Segurança / Shield
                  Center(
                    child: Container(
                      width: 80.0,
                      height: 80.0,
                      decoration: BoxDecoration(
                        color: activeColor.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.mark_email_read_outlined,
                        size: 40.0,
                        color: activeColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24.0),

                  // Título e Subtítulo
                  Text(
                    'Verificação de Código',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF0F172A),
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8.0),
                  RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF64748B),
                        height: 1.45,
                      ),
                      children: [
                        const TextSpan(text: 'Introduza o código de 6 dígitos enviado para o número\n'),
                        TextSpan(
                          text: widget.phone,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 36.0),

                  // Linha com 6 Campos Individuais (PinField)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(_pinLength, (index) {
                      return _buildPinDigitBox(index, activeColor);
                    }),
                  ),
                  const SizedBox(height: 32.0),

                  // Widget de Timer Regressivo de 5 Minutos (StreamBuilder)
                  StreamBuilder<int>(
                    stream: _timerController.stream,
                    initialData: _secondsRemaining,
                    builder: (context, snapshot) {
                      final seconds = snapshot.data ?? 0;
                      final isExpired = seconds <= 0;

                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 16.0),
                        decoration: BoxDecoration(
                          color: isExpired
                              ? const Color(0xFFFEF2F2)
                              : activeColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14.0),
                          border: Border.all(
                            color: isExpired
                                ? const Color(0xFFFCA5A5)
                                : activeColor.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              isExpired ? Icons.timer_off_outlined : Icons.timer_outlined,
                              size: 20.0,
                              color: isExpired ? const Color(0xFFDC2626) : activeColor,
                            ),
                            const SizedBox(width: 8.0),
                            Text(
                              isExpired
                                  ? 'O código OTP expirou (RN-002)'
                                  : 'Válido durante: ${_formatTimer(seconds)}',
                              style: TextStyle(
                                fontSize: 14.0,
                                fontWeight: FontWeight.w700,
                                color: isExpired ? const Color(0xFFDC2626) : activeColor,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 28.0),

                  // Botão de Validação Manual / Submissão
                  FilledButton(
                    onPressed: (isPinComplete && !isLoading) ? _submitOtp : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: activeColor,
                      disabledBackgroundColor: const Color(0xFFCBD5E1),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16.0),
                      ),
                      elevation: isPinComplete ? 3 : 0,
                      shadowColor: activeColor.withValues(alpha: 0.4),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            height: 24.0,
                            width: 24.0,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Confirmar Código',
                            style: TextStyle(
                              fontSize: 16.0,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.2,
                            ),
                          ),
                  ),
                  const SizedBox(height: 16.0),

                  // Botão Reenviar Código por SMS (Respeita RN-002)
                  StreamBuilder<int>(
                    stream: _timerController.stream,
                    initialData: _secondsRemaining,
                    builder: (context, snapshot) {
                      final seconds = snapshot.data ?? 0;
                      final canResend = seconds <= 0 && !isLoading;

                      return TextButton.icon(
                        onPressed: canResend ? _resendOtp : null,
                        icon: const Icon(Icons.refresh_rounded, size: 18.0),
                        label: Text(
                          canResend
                              ? 'Reenviar Código por SMS'
                              : 'Reenviar em ${_formatTimer(seconds)}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: canResend ? activeColor : const Color(0xFF94A3B8),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPinDigitBox(int index, Color activeColor) {
    final hasValue = _controllers[index].text.isNotEmpty;
    final isFocused = _focusNodes[index].hasFocus;

    return RawKeyboardListener(
      focusNode: FocusNode(),
      onKey: (event) => _onRawKeyEvent(event, index),
      child: Container(
        width: 48.0,
        height: 58.0,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14.0),
          border: Border.all(
            color: isFocused
                ? activeColor
                : (hasValue ? const Color(0xFF0F172A) : const Color(0xFFCBD5E1)),
            width: isFocused ? 2.2 : 1.2,
          ),
          boxShadow: [
            if (isFocused)
              BoxShadow(
                color: activeColor.withValues(alpha: 0.2),
                blurRadius: 10.0,
                offset: const Offset(0, 2),
              ),
          ],
        ),
        alignment: Alignment.center,
        child: TextFormField(
          controller: _controllers[index],
          focusNode: _focusNodes[index],
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22.0,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
          ),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(1),
          ],
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: (val) => _onDigitChanged(index, val),
        ),
      ),
    );
  }
}

