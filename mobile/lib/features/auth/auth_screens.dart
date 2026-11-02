/// Ecrãs de Interface de Utilizador (UI) em Material Design 3 para o Fluxo de Autenticação:
/// - Adaptável aos 3 atores (Cliente, Parceiro, Estafeta) através de [DeliveryActorTheme].
/// - `PhoneInputScreen`: Ecrã de introdução do telemóvel (E.164) com formatação e validação (RN-001).
/// - `OtpVerificationScreen`: Grid de 6 campos de dígito único, timer decrescente de 5 minutos e
///   botão "Reenviar Código" bloqueado enquanto o timer estiver ativo (RN-002).
/// - `RegistrationFormScreen`: Formulário de conclusão de registo (Nome, Email, Data de Nascimento com
///   DatePicker e validação imediata de idade >= 18 anos per RN-003, e consentimentos per RN-004).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'auth_bloc_architecture.dart';

// ============================================================================
// 0. TEMA ADAPTÁVEL POR ATOR (Cliente, Parceiro, Estafeta) - Material Design 3
// ============================================================================

enum DeliveryActorRole {
  cliente(
    title: 'Cliente',
    subtitle: 'Peça refeições, mercearia e farmácia em minutos.',
    seedColor: Color(0xFFFF5722), // Laranja vibrante
    icon: Icons.shopping_bag_outlined,
  ),
  parceiro(
    title: 'Parceiro / Loja',
    subtitle: 'Gira o seu menu, pedidos e faturação em tempo real.',
    seedColor: Color(0xFF0F766E), // Verde-azulado profissional (Teal)
    icon: Icons.storefront_outlined,
  ),
  estafeta(
    title: 'Estafeta',
    subtitle: 'Aceite corridas, navegue e acompanhe os seus ganhos.',
    seedColor: Color(0xFF1D4ED8), // Azul logístico de alto contraste
    icon: Icons.two_wheeler_outlined,
  );

  final String title;
  final String subtitle;
  final Color seedColor;
  final IconData icon;

  const DeliveryActorRole({
    required this.title,
    required this.subtitle,
    required this.seedColor,
    required this.icon,
  });
}

class DeliveryActorTheme {
  static ThemeData buildTheme(
    DeliveryActorRole role, {
    Brightness brightness = Brightness.light,
  }) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: role.seedColor,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest.withOpacity(0.35),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: colorScheme.error, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(54),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Formatador de input para número de telemóvel no padrão E.164 (RN-001).
class E164PhoneInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    final buffer = StringBuffer();

    for (int i = 0; i < raw.length; i++) {
      final char = raw[i];
      if (i == 0 && char == '+') {
        buffer.write(char);
      } else if (RegExp(r'\d').hasMatch(char)) {
        buffer.write(char);
      }
    }

    final formatted = buffer.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

// ============================================================================
// 1. ECRÃ 1: PhoneInputScreen (RN-001, RN-002)
// ============================================================================

class PhoneInputScreen extends StatefulWidget {
  final DeliveryActorRole actorRole;
  final ValueChanged<DeliveryActorRole>? onActorRoleChanged;

  const PhoneInputScreen({
    super.key,
    this.actorRole = DeliveryActorRole.cliente,
    this.onActorRoleChanged,
  });

  @override
  State<PhoneInputScreen> createState() => _PhoneInputScreenState();
}

class _PhoneInputScreenState extends State<PhoneInputScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController(text: '+244');
  bool _isPhoneValid = false;

  static final _e164Regex = RegExp(r'^\+?[1-9]\d{7,14}$');

  @override
  void initState() {
    super.initState();
    _phoneController.addListener(_onPhoneChanged);
  }

  void _onPhoneChanged() {
    final valid = _e164Regex.hasMatch(_phoneController.text.trim());
    if (valid != _isPhoneValid) {
      setState(() => _isPhoneValid = valid);
    }
  }

  @override
  void dispose() {
    _phoneController.removeListener(_onPhoneChanged);
    _phoneController.dispose();
    super.dispose();
  }

  String? _validatePhone(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) {
      return 'RN-001: Introduza o seu número de telemóvel.';
    }
    if (!_e164Regex.hasMatch(trimmed)) {
      return 'RN-001: Formato inválido. Use o indicativo internacional (ex: +244923456789).';
    }
    return null;
  }

  void _submitPhone() {
    if (_formKey.currentState?.validate() ?? false) {
      FocusScope.of(context).unfocus();
      context.read<AuthBloc>().add(
            RequestOtpEvent(phone: _phoneController.text.trim()),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: BlocListener<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is OtpSendSuccess) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BlocProvider.value(
                  value: context.read<AuthBloc>(),
                  child: OtpVerificationScreen(
                    phone: state.phone,
                    actorRole: widget.actorRole,
                    initialDurationSeconds: 300,
                  ),
                ),
              ),
            );
          } else if (state is AuthError) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  backgroundColor: colorScheme.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
          }
        },
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _formKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Seletor opcional de Ator para demonstrar adaptação de tema Material 3
                      if (widget.onActorRoleChanged != null) ...[
                        SegmentedButton<DeliveryActorRole>(
                          segments: DeliveryActorRole.values
                              .map(
                                (role) => ButtonSegment<DeliveryActorRole>(
                                  value: role,
                                  label: Text(role.title),
                                  icon: Icon(role.icon, size: 18),
                                ),
                              )
                              .toList(),
                          selected: {widget.actorRole},
                          onSelectionChanged: (selection) {
                            widget.onActorRoleChanged?.call(selection.first);
                          },
                        ),
                        const SizedBox(height: 32),
                      ],

                      // Cabeçalho Identitário do Ator
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Icon(
                            widget.actorRole.icon,
                            size: 36,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Bem-vindo, ${widget.actorRole.title}',
                        style: textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.actorRole.subtitle,
                        style: textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),

                      // Campo de Telemóvel Formatado (RN-001)
                      TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        textInputAction: TextInputAction.done,
                        maxLength: 16,
                        inputFormatters: [
                          E164PhoneInputFormatter(),
                        ],
                        validator: _validatePhone,
                        onFieldSubmitted: (_) => _submitPhone(),
                        decoration: InputDecoration(
                          labelText: 'Número de Telemóvel',
                          hintText: '+244923456789 ou +351912345678',
                          counterText: '',
                          prefixIcon: const Icon(Icons.phone_iphone_rounded),
                          suffixIcon: _phoneController.text.isNotEmpty
                              ? Icon(
                                  _isPhoneValid
                                      ? Icons.check_circle_rounded
                                      : Icons.info_outline_rounded,
                                  color: _isPhoneValid
                                      ? colorScheme.primary
                                      : colorScheme.outline,
                                )
                              : null,
                          helperText:
                              'RN-001 / RN-002: Enviaremos um código único de 6 dígitos por SMS.',
                          helperMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 28),

                      // Botão de Envio Integrado com AuthBloc
                      BlocBuilder<AuthBloc, AuthState>(
                        builder: (context, state) {
                          final isLoading = state is AuthLoading;
                          return FilledButton.icon(
                            onPressed:
                                (isLoading || !_isPhoneValid) ? null : _submitPhone,
                            icon: isLoading
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: colorScheme.onPrimary,
                                    ),
                                  )
                                : const Icon(Icons.sms_outlined),
                            label: Text(
                              isLoading
                                  ? 'A enviar código OTP...'
                                  : 'Receber Código por SMS',
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 2. ECRÃ 2: OtpVerificationScreen (RN-002, RN-006)
// ============================================================================

class OtpVerificationScreen extends StatefulWidget {
  final String phone;
  final DeliveryActorRole actorRole;
  final int initialDurationSeconds;

  const OtpVerificationScreen({
    super.key,
    required this.phone,
    this.actorRole = DeliveryActorRole.cliente,
    this.initialDurationSeconds = 300, // 5 minutos (RN-002)
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  static const int _otpLength = 6;

  late final List<TextEditingController> _digitControllers;
  late final List<FocusNode> _focusNodes;

  Timer? _countdownTimer;
  late int _remainingSeconds;

  @override
  void initState() {
    super.initState();
    _digitControllers = List.generate(_otpLength, (_) => TextEditingController());
    _focusNodes = List.generate(_otpLength, (_) => FocusNode());
    _startCountdown(widget.initialDurationSeconds);
  }

  void _startCountdown(int durationSeconds) {
    _countdownTimer?.cancel();
    setState(() {
      _remainingSeconds = durationSeconds;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_remainingSeconds <= 1) {
        setState(() => _remainingSeconds = 0);
        timer.cancel();
      } else {
        setState(() => _remainingSeconds--);
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    for (final controller in _digitControllers) {
      controller.dispose();
    }
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  String get _currentPin =>
      _digitControllers.map((c) => c.text.trim()).join();

  bool get _isPinComplete =>
      _currentPin.length == _otpLength &&
      RegExp(r'^\d{6}$').hasMatch(_currentPin);

  String get _formattedTimer {
    final minutes = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _onDigitChanged(int index, String value) {
    // Suporte a colar (paste) o código completo de 6 dígitos
    if (value.length > 1) {
      final digitsOnly = value.replaceAll(RegExp(r'\D'), '');
      for (int i = 0; i < _otpLength && i < digitsOnly.length; i++) {
        _digitControllers[i].text = digitsOnly[i];
      }
      if (digitsOnly.length >= _otpLength) {
        _focusNodes.last.unfocus();
        _verifyPin();
      }
      setState(() {});
      return;
    }

    if (value.isNotEmpty && index < _otpLength - 1) {
      _focusNodes[index + 1].requestFocus();
    } else if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }

    setState(() {});

    if (_isPinComplete) {
      FocusScope.of(context).unfocus();
      _verifyPin();
    }
  }

  void _verifyPin() {
    if (!_isPinComplete) return;
    context.read<AuthBloc>().add(
          VerifyOtpEvent(
            phone: widget.phone,
            code: _currentPin,
          ),
        );
  }

  void _resendCode() {
    if (_remainingSeconds > 0) return;
    for (final c in _digitControllers) {
      c.clear();
    }
    _focusNodes.first.requestFocus();
    context.read<AuthBloc>().add(RequestOtpEvent(phone: widget.phone));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verificação de Segurança'),
        centerTitle: true,
      ),
      body: BlocListener<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is OtpSendSuccess) {
            _startCountdown(300);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  behavior: SnackBarBehavior.floating,
                ),
              );
          } else if (state is RegistrationRequired) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => BlocProvider.value(
                  value: context.read<AuthBloc>(),
                  child: RegistrationFormScreen(
                    accessToken: state.onboardingTokens.accessToken,
                    phone: widget.phone,
                    actorRole: widget.actorRole,
                  ),
                ),
              ),
            );
          } else if (state is AuthAuthenticated) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text('Bem-vindo de volta, ${state.user.nome}!'),
                  backgroundColor: colorScheme.primary,
                  behavior: SnackBarBehavior.floating,
                ),
              );
          } else if (state is AuthError) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  backgroundColor: colorScheme.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
          }
        },
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.lock_clock_outlined,
                      size: 48,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Introduza o código de 6 dígitos',
                      textAlign: TextAlign.center,
                      style: textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enviámos um SMS com o código de verificação para ${widget.phone}.',
                      textAlign: TextAlign.center,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Grid responsivo de 6 campos de dígito único (RN-002)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: List.generate(_otpLength, (index) {
                        return SizedBox(
                          width: 48,
                          height: 60,
                          child: TextField(
                            controller: _digitControllers[index],
                            focusNode: _focusNodes[index],
                            autofocus: index == 0,
                            textAlign: TextAlign.center,
                            keyboardType: TextInputType.number,
                            style: textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(6),
                            ],
                            decoration: InputDecoration(
                              contentPadding: EdgeInsets.zero,
                              counterText: '',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onChanged: (value) => _onDigitChanged(index, value),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 28),

                    // Timer visual de contagem decrescente de 5 minutos (RN-002)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: _remainingSeconds > 0
                            ? colorScheme.secondaryContainer.withOpacity(0.5)
                            : colorScheme.errorContainer.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.timer_outlined,
                            size: 20,
                            color: _remainingSeconds > 0
                                ? colorScheme.onSecondaryContainer
                                : colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _remainingSeconds > 0
                                ? 'O código expira em $_formattedTimer'
                                : 'Código OTP expirado (5 min). Solicite um novo.',
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: _remainingSeconds > 0
                                  ? colorScheme.onSecondaryContainer
                                  : colorScheme.onErrorContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Botão de confirmação do OTP
                    BlocBuilder<AuthBloc, AuthState>(
                      builder: (context, state) {
                        final isLoading = state is AuthLoading;
                        return FilledButton(
                          onPressed: (!isLoading &&
                                  _isPinComplete &&
                                  _remainingSeconds > 0)
                              ? _verifyPin
                              : null,
                          child: isLoading
                              ? SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: colorScheme.onPrimary,
                                  ),
                                )
                              : const Text('Confirmar Código'),
                        );
                      },
                    ),
                    const SizedBox(height: 16),

                    // Link "Reenviar Código" desativado até o timer de 5 minutos terminar (RN-002)
                    Center(
                      child: TextButton.icon(
                        onPressed: _remainingSeconds == 0 ? _resendCode : null,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(
                          _remainingSeconds == 0
                              ? 'Reenviar Código'
                              : 'Reenviar Código disponível em $_formattedTimer',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// 3. ECRÃ 3: RegistrationFormScreen (RN-003, RN-004)
// ============================================================================

class RegistrationFormScreen extends StatefulWidget {
  final String accessToken;
  final String phone;
  final DeliveryActorRole actorRole;

  const RegistrationFormScreen({
    super.key,
    required this.accessToken,
    required this.phone,
    this.actorRole = DeliveryActorRole.cliente,
  });

  @override
  State<RegistrationFormScreen> createState() => _RegistrationFormScreenState();
}

class _RegistrationFormScreenState extends State<RegistrationFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _birthDateController = TextEditingController();

  DateTime? _selectedBirthDate;
  String? _birthDateAgeError;

  bool _acceptedTerms = false;
  bool _acceptedPrivacy = false;
  bool _acceptedMarketing = false;
  bool _acceptedBackgroundLocation = false;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _birthDateController.dispose();
    super.dispose();
  }

  /// RN-003: Calcula a idade exata em anos completos.
  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  /// Abre o DatePicker e valida imediatamente se o utilizador tem >= 18 anos (RN-003).
  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedBirthDate ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(1920, 1, 1),
      lastDate: now,
      helpText: 'SELECIONE A SUA DATA DE NASCIMENTO (RN-003)',
      selectableDayPredicate: (DateTime day) {
        // Permite selecionar para exibir feedback visual imediato caso < 18 anos,
        // ou bloqueia datas futuras.
        return !day.isAfter(now);
      },
    );

    if (picked == null) return;

    final formatted =
        '${picked.day.toString().padLeft(2, '0')}/'
        '${picked.month.toString().padLeft(2, '0')}/'
        '${picked.year}';

    final age = _calculateAge(picked);

    setState(() {
      _selectedBirthDate = picked;
      _birthDateController.text = formatted;
      if (age < 18) {
        _birthDateAgeError =
            'RN-003: Idade inválida ($age anos). Tem de ter pelo menos 18 anos para criar conta.';
      } else {
        _birthDateAgeError = null;
      }
    });

    if (age < 18 && mounted) {
      final colorScheme = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_birthDateAgeError!),
            backgroundColor: colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  String? _validateName(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.length < 3 || !trimmed.contains(' ')) {
      return 'RN-003: Introduza o seu nome e apelido completos.';
    }
    return null;
  }

  String? _validateEmail(String? value) {
    final trimmed = (value ?? '').trim();
    final emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    if (trimmed.isEmpty || !emailRegex.hasMatch(trimmed)) {
      return 'RN-001 / RN-003: Introduza um endereço de e-mail válido.';
    }
    return null;
  }

  String? _validateBirthDate(String? _) {
    if (_selectedBirthDate == null) {
      return 'RN-003: A data de nascimento é obrigatória.';
    }
    if (_birthDateAgeError != null) {
      return _birthDateAgeError;
    }
    if (_calculateAge(_selectedBirthDate!) < 18) {
      return 'RN-003: O utilizador tem de ter pelo menos 18 anos.';
    }
    return null;
  }

  void _submitRegistration() {
    final isFormValid = _formKey.currentState?.validate() ?? false;
    if (!isFormValid || _selectedBirthDate == null || _birthDateAgeError != null) {
      return;
    }

    if (!_acceptedTerms || !_acceptedPrivacy) {
      final colorScheme = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text(
              'RN-004: Deve aceitar os Termos de Utilização e a Política de Privacidade.',
            ),
            backgroundColor: colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    FocusScope.of(context).unfocus();
    context.read<AuthBloc>().add(
          CompleteRegistrationEvent(
            accessToken: widget.accessToken,
            nome: _nameController.text.trim(),
            email: _emailController.text.trim(),
            dataNascimento: _selectedBirthDate!,
            termosUtilizacao: _acceptedTerms,
            politicaPrivacidade: _acceptedPrivacy,
            marketing: _acceptedMarketing,
            localizacaoSegundoPlano: _acceptedBackgroundLocation,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Completar Registo'),
        centerTitle: true,
      ),
      body: BlocListener<AuthBloc, AuthState>(
        listener: (context, state) {
          if (state is AuthAuthenticated) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text('Conta ativada com sucesso, ${state.user.nome}!'),
                  backgroundColor: colorScheme.primary,
                  behavior: SnackBarBehavior.floating,
                ),
              );
          } else if (state is AuthError) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  backgroundColor: colorScheme.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
          }
        },
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Form(
                  key: _formKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Dados Básicos da Conta',
                        style: textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Telemóvel verificado (${widget.phone}). Preencha os dados obrigatórios para concluir o registo.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Nome Completo (RN-003)
                      TextFormField(
                        controller: _nameController,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        validator: _validateName,
                        decoration: const InputDecoration(
                          labelText: 'Nome Completo *',
                          hintText: 'Ex: João Manuel Silva',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Email Único (RN-001, RN-003)
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        validator: _validateEmail,
                        decoration: const InputDecoration(
                          labelText: 'Endereço de E-mail *',
                          hintText: 'nome@exemplo.com',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Data de Nascimento com DatePicker e validação imediata >= 18 anos (RN-003)
                      TextFormField(
                        controller: _birthDateController,
                        readOnly: true,
                        onTap: _pickBirthDate,
                        validator: _validateBirthDate,
                        decoration: InputDecoration(
                          labelText: 'Data de Nascimento *',
                          hintText: 'DD/MM/AAAA (Mínimo 18 anos)',
                          prefixIcon: const Icon(Icons.cake_outlined),
                          suffixIcon: const Icon(Icons.calendar_month_outlined),
                          errorText: _birthDateAgeError,
                          errorMaxLines: 2,
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Consentimentos RGPD (RN-004)
                      Text(
                        'Privacidade e Consentimentos (RN-004)',
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        value: _acceptedTerms,
                        onChanged: (v) => setState(() => _acceptedTerms = v ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Aceito os Termos de Utilização *'),
                      ),
                      CheckboxListTile(
                        value: _acceptedPrivacy,
                        onChanged: (v) => setState(() => _acceptedPrivacy = v ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Aceito a Política de Privacidade *'),
                      ),
                      SwitchListTile(
                        value: _acceptedMarketing,
                        onChanged: (v) => setState(() => _acceptedMarketing = v),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Comunicações de Marketing (Opcional)'),
                        subtitle: const Text('Receber cupões, promoções e novidades.'),
                      ),
                      SwitchListTile(
                        value: _acceptedBackgroundLocation,
                        onChanged: (v) =>
                            setState(() => _acceptedBackgroundLocation = v),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Localização em Segundo Plano (Opcional)'),
                        subtitle: const Text(
                          'Permite acompanhamento preciso durante entregas em curso.',
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Botão de Submissão do Registo
                      BlocBuilder<AuthBloc, AuthState>(
                        builder: (context, state) {
                          final isLoading = state is AuthLoading;
                          final canSubmit = !isLoading &&
                              _birthDateAgeError == null &&
                              _selectedBirthDate != null &&
                              _acceptedTerms &&
                              _acceptedPrivacy;

                          return FilledButton.icon(
                            onPressed: canSubmit ? _submitRegistration : null,
                            icon: isLoading
                                ? SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: colorScheme.onPrimary,
                                    ),
                                  )
                                : const Icon(Icons.verified_user_outlined),
                            label: Text(
                              isLoading ? 'A ativar conta...' : 'Concluir Registo',
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
