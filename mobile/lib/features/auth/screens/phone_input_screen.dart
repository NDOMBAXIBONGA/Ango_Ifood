/// Ecrã 2: `PhoneInputScreen`
/// Exibe a interface de introdução de número de telemóvel com alternância de estados
/// mutuamente exclusiva via BlocConsumer<AuthBloc, AuthState>, impedindo qualquer
/// sobreposição visual de ecrãs (UI Stack Overlap) em caso de falhas de rede.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../auth_bloc.dart';
import '../theme/role_theme.dart';
import 'otp_verification_screen.dart';

// ==============================================================================
// 1. COMPONENTE ISOLADO DE ERRO DE CONEXÃO (ConnectionErrorWidget)
// ==============================================================================
/// Componente responsivo isolado com SafeArea e SingleChildScrollView.
/// Garante que, ao ocorrer falha de rede, os campos de formulário e textos anteriores
/// sejam completamente descarregados da árvore de widgets, eliminando qualquer sobreposição.
class ConnectionErrorWidget extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final Color activeColor;

  const ConnectionErrorWidget({
    super.key,
    required this.message,
    required this.onRetry,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Ícone de Alerta de Conexão com Fundo Suave
              Container(
                width: 96.0,
                height: 96.0,
                decoration: const BoxDecoration(
                  color: Color(0xFFFEF2F2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.cloud_off_rounded,
                  size: 48.0,
                  color: Color(0xFFDC2626),
                ),
              ),
              const SizedBox(height: 24.0),

              // Título Principal de Falha
              const Text(
                'Falha Temporária de Conexão',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22.0,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 12.0),

              // Mensagem Descritiva
              Text(
                message.isNotEmpty
                    ? message
                    : 'Não foi possível contactar os servidores cloud da plataforma. Verifique a sua ligação com a internet e tente novamente.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14.0,
                  color: Color(0xFF64748B),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 36.0),

              // Botão Tentar Novamente
              SizedBox(
                width: double.infinity,
                height: 52.0,
                child: FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 20.0),
                  label: const Text(
                    'Tentar Novamente',
                    style: TextStyle(
                      fontSize: 15.0,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: activeColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16.0),
                    ),
                    elevation: 2,
                    shadowColor: activeColor.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==============================================================================
// 2. ECRÃ PRINCIPAL DE AUTENTICAÇÃO (PhoneInputScreen)
// ==============================================================================
class PhoneInputScreen extends StatefulWidget {
  final PlatformRole selectedRole;

  const PhoneInputScreen({
    super.key,
    required this.selectedRole,
  });

  @override
  State<PhoneInputScreen> createState() => _PhoneInputScreenState();
}

class _PhoneInputScreenState extends State<PhoneInputScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  String _selectedCountryCode = '+244'; // Prefixo padrão (Angola)
  bool _isPhoneValid = false;

  final List<Map<String, String>> _countryCodes = [
    {'code': '+244', 'country': 'Angola', 'flag': '🇦🇴'},
    {'code': '+351', 'country': 'Portugal', 'flag': '🇵🇹'},
    {'code': '+238', 'country': 'Cabo Verde', 'flag': '🇨🇻'},
    {'code': '+258', 'country': 'Moçambique', 'flag': '🇲🇿'},
    {'code': '+55', 'country': 'Brasil', 'flag': '🇧🇷'},
  ];

  @override
  void initState() {
    super.initState();
    _phoneController.addListener(_validateInput);
  }

  @override
  void dispose() {
    _phoneController.removeListener(_validateInput);
    _phoneController.dispose();
    super.dispose();
  }

  void _validateInput() {
    final digits = _phoneController.text.replaceAll(RegExp(r'\D'), '');
    final isValid = digits.length >= 9 && digits.length <= 12;
    if (isValid != _isPhoneValid) {
      setState(() {
        _isPhoneValid = isValid;
      });
    }
  }

  String get _fullPhoneNumber {
    final cleanDigits = _phoneController.text.replaceAll(RegExp(r'\D'), '');
    return '$_selectedCountryCode$cleanDigits';
  }

  void _submitPhoneNumber() {
    if (_formKey.currentState?.validate() ?? false) {
      FocusScope.of(context).unfocus();
      context.read<AuthBloc>().add(
            RequestOtpRequested(phone: _fullPhoneNumber),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = widget.selectedRole.primaryColor;

    return BlocConsumer<AuthBloc, AuthState>(
      // O listener processa exclusivamente efeitos secundários (Navegação / Notificações)
      listener: (context, state) {
        if (state is OtpSendSuccess) {
          // Substituição de rota limpa sem acumular ecrãs na pilha do Navigator
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => OtpVerificationScreen(
                phone: state.phone,
                expiraEm: state.expiraEm,
                validadeMinutos: state.validadeMinutos,
                selectedRole: widget.selectedRole,
              ),
            ),
          );
        } else if (state is OtpVerificationFailure) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: Colors.white),
                  const SizedBox(width: 12.0),
                  Expanded(child: Text(state.message)),
                ],
              ),
              backgroundColor: const Color(0xFFEF4444),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12.0),
              ),
            ),
          );
        }
      },
      // O builder processa uma árvore de decisões condicional pura e mutuamente exclusiva
      builder: (context, state) {
        // Cenário 1: Falha de conexão ou timeout de rede com o servidor Render
        // Retorna unicamente o ConnectionErrorWidget, descarregando completamente o formulário
        if (state is AuthNetworkFailure) {
          return Scaffold(
            backgroundColor: const Color(0xFFF8FAFC),
            appBar: _buildAppBar(context, activeColor),
            body: ConnectionErrorWidget(
              message: state.message,
              activeColor: activeColor,
              onRetry: () {
                context.read<AuthBloc>().add(const RetryAuthRequested());
              },
            ),
          );
        }

        final isLoading = state is AuthLoading;

        // Cenário 2: Estado Inicial, Não Autenticado ou Carregamento
        // Renderiza unicamente a interface de introdução do número com formulário protegido
        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: _buildAppBar(context, activeColor),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12.0),

                    // Logótipo da Aplicação com a cor do papel ativo
                    Center(
                      child: Container(
                        width: 88.0,
                        height: 88.0,
                        decoration: BoxDecoration(
                          color: activeColor.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: activeColor.withValues(alpha: 0.2),
                              blurRadius: 20.0,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.phone_android_rounded,
                          size: 44.0,
                          color: activeColor,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28.0),

                    // Cabeçalho de Introdução
                    Text(
                      'Qual é o seu telemóvel?',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF0F172A),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8.0),
                    Text(
                      'Enviaremos um código SMS de 6 dígitos para validar a sua identidade de forma rápida e segura.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF64748B),
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 36.0),

                    // Campo com Máscara e Seletor de Código de País
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18.0),
                        border: Border.all(
                          color: _isPhoneValid ? activeColor : const Color(0xFFE2E8F0),
                          width: _isPhoneValid ? 2.0 : 1.2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0F172A).withValues(alpha: 0.04),
                            blurRadius: 10.0,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 4.0),
                      child: Row(
                        children: [
                          // Dropdown de Prefixo Internacional
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedCountryCode,
                              borderRadius: BorderRadius.circular(16.0),
                              icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF64748B)),
                              items: _countryCodes.map((item) {
                                return DropdownMenuItem<String>(
                                  value: item['code'],
                                  child: Row(
                                    children: [
                                      Text(item['flag'] ?? '', style: const TextStyle(fontSize: 18.0)),
                                      const SizedBox(width: 6.0),
                                      Text(
                                        item['code'] ?? '',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15.0,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: isLoading
                                  ? null
                                  : (value) {
                                      if (value != null) {
                                        setState(() {
                                          _selectedCountryCode = value;
                                        });
                                      }
                                    },
                            ),
                          ),
                          Container(
                            height: 32.0,
                            width: 1.2,
                            color: const Color(0xFFE2E8F0),
                            margin: const EdgeInsets.symmetric(horizontal: 8.0),
                          ),

                          // Campo de Texto de Inserção Numérica
                          Expanded(
                            child: TextFormField(
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              enabled: !isLoading,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(11),
                              ],
                              style: const TextStyle(
                                fontSize: 17.0,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                                letterSpacing: 0.5,
                              ),
                              decoration: const InputDecoration(
                                hintText: '923 000 000',
                                hintStyle: TextStyle(
                                  color: Color(0xFF94A3B8),
                                  fontWeight: FontWeight.w500,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'Por favor, insira o número de telemóvel.';
                                }
                                final digits = value.replaceAll(RegExp(r'\D'), '');
                                if (digits.length < 9) {
                                  return 'O número deve ter pelo menos 9 dígitos.';
                                }
                                return null;
                              },
                            ),
                          ),

                          if (_isPhoneValid)
                            Icon(Icons.check_circle_rounded, color: activeColor, size: 22.0),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28.0),

                    // Botão de Submissão com Estado de Carregamento
                    FilledButton(
                      onPressed: (_isPhoneValid && !isLoading) ? _submitPhoneNumber : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: activeColor,
                        disabledBackgroundColor: const Color(0xFFCBD5E1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 18.0),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16.0),
                        ),
                        elevation: _isPhoneValid ? 3 : 0,
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
                              'Enviar Código por SMS',
                              style: TextStyle(
                                fontSize: 16.0,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                    ),
                    const SizedBox(height: 20.0),

                    // Termos e Aviso Legal
                    Text(
                      'Ao continuar, declara que aceita receber mensagens SMS de autenticação e concorda com os nossos Termos de Serviço e Política de Privacidade.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF94A3B8),
                        fontSize: 11.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, Color activeColor) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A)),
        onPressed: () => Navigator.of(context).pop(),
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 16.0),
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
          decoration: BoxDecoration(
            color: activeColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20.0),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.selectedRole.icon, size: 16.0, color: activeColor),
              const SizedBox(width: 6.0),
              Text(
                widget.selectedRole.title,
                style: TextStyle(
                  fontSize: 12.0,
                  fontWeight: FontWeight.w700,
                  color: activeColor,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
