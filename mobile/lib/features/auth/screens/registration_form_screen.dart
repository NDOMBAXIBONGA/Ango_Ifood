/// Ecrã 4: `RegistrationFormScreen`
/// Formulário com validação em tempo real para Nome Completo, Email e Data de Nascimento (RN-003).
/// Integra o `showDatePicker` com verificação estrita de maioridade civil (>= 18 anos).
/// Caso o utilizador seja menor de idade, exibe banner impeditivo e desativa a submissão.
/// Reage com `BlocConsumer` ao `AuthBloc`.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../auth_bloc.dart';
import '../theme/role_theme.dart';

class RegistrationFormScreen extends StatefulWidget {
  final String phone;
  final String? email;
  final PlatformRole selectedRole;

  const RegistrationFormScreen({
    super.key,
    required this.phone,
    this.email,
    required this.selectedRole,
  });

  @override
  State<RegistrationFormScreen> createState() => _RegistrationFormScreenState();
}

class _RegistrationFormScreenState extends State<RegistrationFormScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _birthDateController = TextEditingController();

  DateTime? _selectedBirthDate;
  bool _isUnderage = false;
  String? _underageErrorMessage;

  bool _termsAccepted = true;
  bool _privacyAccepted = true;
  bool _marketingAccepted = false;

  @override
  void initState() {
    super.initState();
    if (widget.email != null && widget.email!.isNotEmpty) {
      _emailController.text = widget.email!;
    } else if (widget.phone.contains('@')) {
      _emailController.text = widget.phone;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _birthDateController.dispose();
    super.dispose();
  }

  int _calculateAge(DateTime birthDate) {
    final today = DateTime.now();
    int age = today.year - birthDate.year;
    if (today.month < birthDate.month ||
        (today.month == birthDate.month && today.day < birthDate.day)) {
      age--;
    }
    return age;
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final eighteenYearsAgo = DateTime(now.year - 18, now.month, now.day);
    final initialPickerDate = _selectedBirthDate ?? eighteenYearsAgo;

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialPickerDate,
      firstDate: DateTime(1920),
      lastDate: now,
      helpText: 'SELECIONE A SUA DATA DE NASCIMENTO',
      cancelText: 'CANCELAR',
      confirmText: 'CONFIRMAR',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: widget.selectedRole.colorScheme,
          ),
          child: child!,
        );
      },
    );

    if (pickedDate != null) {
      final age = _calculateAge(pickedDate);
      final isUnderage = age < 18;

      setState(() {
        _selectedBirthDate = pickedDate;
        _birthDateController.text =
            '${pickedDate.day.toString().padLeft(2, '0')}/${pickedDate.month.toString().padLeft(2, '0')}/${pickedDate.year}';
        _isUnderage = isUnderage;

        if (isUnderage) {
          _underageErrorMessage =
              'RN-003: Apenas indivíduos com idade igual ou superior a 18 anos civis '
              'podem criar conta na plataforma (idade calculada: $age anos).';
        } else {
          _underageErrorMessage = null;
        }
      });
    }
  }

  void _submitRegistration() {
    if (_isUnderage) {
      return;
    }

    if (!_termsAccepted || !_privacyAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'RN-004: É obrigatório aceitar os Termos de Utilização e a Política de Privacidade.',
          ),
          backgroundColor: const Color(0xFFEF4444),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
        ),
      );
      return;
    }

    if (_formKey.currentState?.validate() ?? false) {
      if (_selectedBirthDate == null) {
        setState(() {
          _underageErrorMessage = 'Por favor, selecione a data de nascimento.';
        });
        return;
      }

      FocusScope.of(context).unfocus();

      context.read<AuthBloc>().add(
            RegistrationFormSubmitted(
              phone: widget.phone,
              name: _nameController.text.trim(),
              email: _emailController.text.trim(),
              birthDate: _selectedBirthDate!,
              termsAccepted: _termsAccepted,
              privacyAccepted: _privacyAccepted,
              marketingAccepted: _marketingAccepted,
            ),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = widget.selectedRole.primaryColor;

    return BlocConsumer<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is Authenticated) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: Colors.white),
                  const SizedBox(width: 12.0),
                  Expanded(
                    child: Text('Registo concluído! Bem-vindo, ${state.user.nome}.'),
                  ),
                ],
              ),
              backgroundColor: const Color(0xFF10B981),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
            ),
          );

          // Redireciona para o fluxo principal pós-autenticação
          Navigator.of(context).popUntil((route) => route.isFirst);
        } else if (state is RegistrationFailure) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.white),
                  const SizedBox(width: 12.0),
                  Expanded(child: Text(state.message)),
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
        final canSubmit = !_isUnderage && _termsAccepted && _privacyAccepted && !isLoading;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            title: Text(
              'Finalizar Registo',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: const Color(0xFF0F172A),
              ),
            ),
            centerTitle: true,
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Badge de Telemóvel Validado
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(14.0),
                        border: Border.all(color: const Color(0xFFA7F3D0)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.verified_rounded, color: Color(0xFF10B981), size: 20.0),
                          const SizedBox(width: 10.0),
                          Expanded(
                            child: Text(
                              'Número validado com sucesso: ${widget.phone}',
                              style: const TextStyle(
                                fontSize: 13.0,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF065F46),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20.0),

                    // Título do Formulário
                    Text(
                      'Dados Básicos de Perfil',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF0F172A),
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4.0),
                    Text(
                      'Preencha as informações para ativar a sua conta (${widget.selectedRole.title}).',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 24.0),

                    // 1. Campo: Nome Completo
                    _buildInputFieldLabel('Nome Completo *'),
                    const SizedBox(height: 6.0),
                    TextFormField(
                      controller: _nameController,
                      enabled: !isLoading,
                      textCapitalization: TextCapitalization.words,
                      decoration: _buildInputDecoration(
                        hintText: 'Ex.: João Manuel Lourenço',
                        icon: Icons.person_outline_rounded,
                        activeColor: activeColor,
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Por favor, insira o seu nome completo.';
                        }
                        if (value.trim().length < 2) {
                          return 'O nome deve ter pelo menos 2 caracteres.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 18.0),

                    // 2. Campo: Email
                    _buildInputFieldLabel('Endereço de E-mail *'),
                    const SizedBox(height: 6.0),
                    TextFormField(
                      controller: _emailController,
                      enabled: !isLoading,
                      keyboardType: TextInputType.emailAddress,
                      decoration: _buildInputDecoration(
                        hintText: 'nome@exemplo.com',
                        icon: Icons.alternate_email_rounded,
                        activeColor: activeColor,
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Por favor, insira o seu endereço de e-mail.';
                        }
                        final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                        if (!emailRegex.hasMatch(value.trim())) {
                          return 'Insira um formato de e-mail válido.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 18.0),

                    // 3. Campo: Data de Nascimento (com showDatePicker)
                    _buildInputFieldLabel('Data de Nascimento (Maioridade >= 18 anos) *'),
                    const SizedBox(height: 6.0),
                    TextFormField(
                      controller: _birthDateController,
                      readOnly: true,
                      enabled: !isLoading,
                      onTap: isLoading ? null : _pickBirthDate,
                      decoration: _buildInputDecoration(
                        hintText: 'DD/MM/AAAA',
                        icon: Icons.cake_outlined,
                        activeColor: activeColor,
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.calendar_month_outlined),
                          onPressed: isLoading ? null : _pickBirthDate,
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'A data de nascimento é obrigatória.';
                        }
                        return null;
                      },
                    ),

                    // Banner Impeditivo de Menor de Idade (RN-003)
                    if (_isUnderage && _underageErrorMessage != null) ...[
                      const SizedBox(height: 12.0),
                      Container(
                        padding: const EdgeInsets.all(12.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(14.0),
                          border: Border.all(color: const Color(0xFFFCA5A5)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: Color(0xFFDC2626), size: 22.0),
                            const SizedBox(width: 10.0),
                            Expanded(
                              child: Text(
                                _underageErrorMessage!,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFB91C1C),
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 24.0),

                    // Consentimentos Legais (RN-004)
                    _buildConsentCheckbox(
                      title: 'Aceito os Termos e Condições Gerais de Utilização da plataforma (Obrigatório).',
                      value: _termsAccepted,
                      onChanged: isLoading
                          ? null
                          : (val) {
                              setState(() {
                                _termsAccepted = val ?? false;
                              });
                            },
                      activeColor: activeColor,
                    ),
                    _buildConsentCheckbox(
                      title: 'Declaro que li e concordo com a Política de Privacidade e Tratamento de Dados (Obrigatório).',
                      value: _privacyAccepted,
                      onChanged: isLoading
                          ? null
                          : (val) {
                              setState(() {
                                _privacyAccepted = val ?? false;
                              });
                            },
                      activeColor: activeColor,
                    ),
                    _buildConsentCheckbox(
                      title: 'Desejo receber notificações com promoções e cupões de desconto (Opcional).',
                      value: _marketingAccepted,
                      onChanged: isLoading
                          ? null
                          : (val) {
                              setState(() {
                                _marketingAccepted = val ?? false;
                              });
                            },
                      activeColor: activeColor,
                    ),

                    const SizedBox(height: 28.0),

                    // Botão Finalizar Registo
                    FilledButton(
                      onPressed: canSubmit ? _submitRegistration : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: activeColor,
                        disabledBackgroundColor: const Color(0xFFCBD5E1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 18.0),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16.0),
                        ),
                        elevation: canSubmit ? 3 : 0,
                        shadowColor: activeColor.withOpacity(0.4),
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
                              'Finalizar Registo e Ativar Conta',
                              style: TextStyle(
                                fontSize: 16.0,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                    ),
                    const SizedBox(height: 20.0),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputFieldLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        color: Color(0xFF334155),
      ),
    );
  }

  InputDecoration _buildInputDecoration({
    required String hintText,
    required IconData icon,
    required Color activeColor,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14.5),
      prefixIcon: Icon(icon, color: const Color(0xFF64748B), size: 22.0),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14.0),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0), width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14.0),
        borderSide: BorderSide(color: activeColor, width: 2.0),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14.0),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14.0),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 2.0),
      ),
    );
  }

  Widget _buildConsentCheckbox({
    required String title,
    required bool value,
    required ValueChanged<bool?>? onChanged,
    required Color activeColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        onTap: onChanged != null ? () => onChanged(!value) : null,
        borderRadius: BorderRadius.circular(8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24.0,
              height: 24.0,
              child: Checkbox(
                value: value,
                onChanged: onChanged,
                activeColor: activeColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6.0)),
              ),
            ),
            const SizedBox(width: 10.0),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF475569),
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

