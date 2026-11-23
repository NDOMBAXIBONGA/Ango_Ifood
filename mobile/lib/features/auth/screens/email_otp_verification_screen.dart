/// Ecrã de Validação de Código OTP por E-mail: `EmailOtpVerificationScreen`
/// Interface para introdução dos 6 dígitos com avanço e recuo automático de foco,
/// cronómetro regressivo visual de 5 minutos, bloqueio de reenvio durante a contagem
/// e transição para o formulário de registo após sucesso (`OtpVerifiedSuccess`).

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../auth_bloc.dart';
import '../theme/role_theme.dart';
import '../utils/role_navigation.dart';
import 'auth_screen.dart';
import 'registration_form_screen.dart';

class EmailOtpVerificationScreen extends StatefulWidget {
  final String email;
  final PlatformRole selectedRole;
  final String? otpHint;

  const EmailOtpVerificationScreen({
    super.key,
    required this.email,
    this.selectedRole = PlatformRole.cliente,
    this.otpHint,
  });

  @override
  State<EmailOtpVerificationScreen> createState() => _EmailOtpVerificationScreenState();
}

class _EmailOtpVerificationScreenState extends State<EmailOtpVerificationScreen> {
  static const int _pinLength = 6;
  static const int _initialCountdownSeconds = 900; // 15 minutos de validade do código OTP
  static const int _resendCooldownSeconds = 45; // 45 segundos de intervalo para reenvio

  final List<TextEditingController> _controllers = [];
  final List<FocusNode> _focusNodes = [];

  Timer? _timer;
  int _secondsRemaining = _initialCountdownSeconds;
  int _resendCooldown = _resendCooldownSeconds;
  bool _isVerifying = false;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < _pinLength; i++) {
      _controllers.add(TextEditingController());
      _focusNodes.add(FocusNode());
    }
    _startCountdown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (int i = 0; i < _pinLength; i++) {
      _controllers[i].dispose();
      _focusNodes[i].dispose();
    }
    super.dispose();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() {
      _secondsRemaining = _initialCountdownSeconds;
      _resendCooldown = _resendCooldownSeconds;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        if (_secondsRemaining > 0) {
          _secondsRemaining--;
        }
        if (_resendCooldown > 0) {
          _resendCooldown--;
        }
        if (_secondsRemaining == 0 && _resendCooldown == 0) {
          timer.cancel();
        }
      });
    });
  }

  String get _formattedTime {
    final minutes = (_secondsRemaining ~/ 60).toString().padLeft(2, '0');
    final seconds = (_secondsRemaining % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String get _fullOtpCode {
    return _controllers.map((c) => c.text.trim()).join();
  }

  void _onDigitChanged(int index, String value) {
    if (value.isNotEmpty) {
      // Se o utilizador colar múltiplos dígitos de uma vez
      if (value.length > 1) {
        final digits = value.replaceAll(RegExp(r'\D'), '');
        for (int i = 0; i < digits.length && (index + i) < _pinLength; i++) {
          _controllers[index + i].text = digits[i];
        }
        final nextIndex = (index + digits.length).clamp(0, _pinLength - 1);
        _focusNodes[nextIndex].requestFocus();
      } else {
        // Avanço inteligente para o próximo campo
        if (index < _pinLength - 1) {
          _focusNodes[index + 1].requestFocus();
        } else {
          _focusNodes[index].unfocus();
        }
      }
    } else {
      // Backspace: move o foco para o campo anterior
      if (index > 0) {
        _focusNodes[index - 1].requestFocus();
      }
    }

    _checkAndSubmitOtp();
  }

  void _checkAndSubmitOtp() {
    final otp = _fullOtpCode;
    if (otp.length == _pinLength && !_isVerifying) {
      setState(() => _isVerifying = true);
      FocusScope.of(context).unfocus();
      context.read<AuthBloc>().add(
            VerifyEmailOtpSubmitted(
              email: widget.email,
              otp: otp,
            ),
          );
    }
  }

  void _resendOtp() {
    if (_resendCooldown == 0) {
      for (final controller in _controllers) {
        controller.clear();
      }
      _focusNodes[0].requestFocus();
      _startCountdown();

      context.read<AuthBloc>().add(
            SendEmailOtpEvent(email: widget.email),
          );

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Novo código enviado para o seu e-mail.'),
          backgroundColor: Color(0xFF16A34A),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _navigateToChangeEmail() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AuthScreen(selectedRole: widget.selectedRole),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = widget.selectedRole.primaryColor;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A), size: 20),
          onPressed: _navigateToChangeEmail,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Chip(
              backgroundColor: activeColor.withOpacity(0.12),
              side: BorderSide(color: activeColor.withOpacity(0.3)),
              avatar: Icon(Icons.email_rounded, size: 16, color: activeColor),
              label: Text(
                widget.selectedRole.displayName,
                style: TextStyle(
                  color: activeColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
      body: BlocConsumer<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthLoading) {
            setState(() => _isVerifying = true);
          } else {
            setState(() => _isVerifying = false);
          }

          if (state is Authenticated) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(
                builder: (ctx) => getAuthorizedHomeScreen(
                  user: state.user,
                  requestedRole: widget.selectedRole,
                  context: ctx,
                ),
              ),
              (route) => false,
            );
          } else if (state is OtpVerifiedSuccess) {
            // Navega diretamente para o formulário de finalização de registo
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => RegistrationFormScreen(
                  phone: widget.email,
                  email: widget.email,
                  selectedRole: widget.selectedRole,
                ),
              ),
            );
          } else if (state is OtpVerificationFailure) {
            setState(() => _isVerifying = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: const Color(0xFFDC2626),
                behavior: SnackBarBehavior.floating,
              ),
            );
            // Limpa os campos para facilitar a nova digitação
            for (final controller in _controllers) {
              controller.clear();
            }
            if (_focusNodes.isNotEmpty) {
              _focusNodes[0].requestFocus();
            }
          } else if (state is AuthNetworkFailure) {
            setState(() => _isVerifying = false);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.message),
                backgroundColor: const Color(0xFFDC2626),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        },
        builder: (context, state) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                          const SizedBox(height: 12),

                          // Ícone ilustrativo com fundo suave
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: activeColor.withOpacity(0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.mark_email_read_rounded,
                                size: 32,
                                color: activeColor,
                              ),
                            ),
                          ),

                          const SizedBox(height: 24),

                          // Título do Ecrã
                          Text(
                            'Introduza o código',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF0F172A),
                              letterSpacing: -0.5,
                            ),
                          ),

                          const SizedBox(height: 8),

                          // Subtítulo Dinâmico com E-mail
                          RichText(
                            text: TextSpan(
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFF64748B),
                                height: 1.45,
                                fontSize: 14,
                              ),
                              children: [
                                const TextSpan(text: 'Enviámos um e-mail com o código de 6 dígitos para: '),
                                TextSpan(
                                  text: widget.email,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 8),

                          // Botão discreto para alterar o e-mail
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _navigateToChangeEmail,
                              icon: const Icon(Icons.edit_outlined, size: 15),
                              label: const Text(
                                'Alterar e-mail',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                foregroundColor: activeColor,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),

                          const SizedBox(height: 32),

                          // Linha horizontal de 6 inputs para os dígitos do PIN
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: List.generate(_pinLength, (index) {
                              return _buildPinDigitField(index: index, activeColor: activeColor);
                            }),
                          ),

                          const SizedBox(height: 32),

                          // Contador Visual Regressivo (05:00)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.timer_outlined,
                                size: 18,
                                color: _secondsRemaining > 0 ? const Color(0xFF64748B) : const Color(0xFFDC2626),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _formattedTime,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: _secondsRemaining > 0 ? const Color(0xFF0F172A) : const Color(0xFFDC2626),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 12),

                          // Botão de Reenvio Interativo
                          Center(
                            child: TextButton(
                              onPressed: _resendCooldown == 0 ? _resendOtp : null,
                              style: TextButton.styleFrom(
                                foregroundColor: activeColor,
                                disabledForegroundColor: const Color(0xFF94A3B8),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              ),
                              child: Text(
                                _resendCooldown == 0
                                    ? 'Reenviar e-mail com o código'
                                    : 'Reenviar e-mail (${_resendCooldown}s)',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: _resendCooldown == 0 ? activeColor : const Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 32),

                          // Botão Validar Código Manual
                          ElevatedButton(
                            onPressed: _fullOtpCode.length == _pinLength && !_isVerifying
                                ? _checkAndSubmitOtp
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: activeColor,
                              disabledBackgroundColor: const Color(0xFFE2E8F0),
                              foregroundColor: Colors.white,
                              disabledForegroundColor: const Color(0xFF94A3B8),
                              elevation: _fullOtpCode.length == _pinLength ? 2 : 0,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: _isVerifying
                                ? SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                                    ),
                                  )
                                : const Text(
                                    'Validar Código',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),

                          const SizedBox(height: 20),

                          // Caixa de Orientação e Ajuda de Entrega de E-mail (Spam / Promoções)
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8FAFC),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFE2E8F0)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.mark_email_unread_outlined, size: 20, color: Color(0xFF64748B)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: RichText(
                                    text: TextSpan(
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: const Color(0xFF475569),
                                        height: 1.45,
                                        fontSize: 12,
                                      ),
                                      children: const [
                                        TextSpan(
                                          text: 'Não encontrou o e-mail? ',
                                          style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                                        ),
                                        TextSpan(
                                          text: 'Verifique a pasta de ',
                                        ),
                                        TextSpan(
                                          text: 'Spam / Lixo Eletrónico',
                                          style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFDC2626)),
                                        ),
                                        TextSpan(
                                          text: ' ou o separador ',
                                        ),
                                        TextSpan(
                                          text: 'Promoções',
                                          style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                                        ),
                                        TextSpan(
                                          text: ' da sua aplicação de correio.',
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  );
                },
      ),
    );
  }

  // ============================================================================
  // COMPONENTE: Caixa Individual de Dígito com Foco Inteligente
  // ============================================================================
  Widget _buildPinDigitField({
    required int index,
    required Color activeColor,
  }) {
    return SizedBox(
      width: 48,
      height: 56,
      child: TextFormField(
        controller: _controllers[index],
        focusNode: _focusNodes[index],
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        maxLength: 1,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: Color(0xFF0F172A),
        ),
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: _controllers[index].text.isNotEmpty ? activeColor.withOpacity(0.5) : const Color(0xFFE2E8F0),
              width: 1.5,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: activeColor,
              width: 2.0,
            ),
          ),
        ),
        onChanged: (value) => _onDigitChanged(index, value),
      ),
    );
  }
}

