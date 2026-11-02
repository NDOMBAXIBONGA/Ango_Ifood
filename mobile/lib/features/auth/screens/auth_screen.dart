/// Ecrã de Autenticação: `AuthScreen` (`auth_screen.dart`)
/// Implementa a arquitetura de visualização condicional estrita via `BlocConsumer<AuthBloc, AuthState>`.
/// O método `builder` utiliza blocos de decisão puros e mutuamente exclusivos para eliminar
/// definitivamente qualquer sobreposição visual (UI Stack Overlap), descarregando completamente
/// da memória os widgets de estados anteriores.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../auth_bloc.dart';
import '../theme/role_theme.dart';
import 'otp_verification_screen.dart';

// ==============================================================================
// 1. ECRÃ PRINCIPAL DE AUTENTICAÇÃO (AuthScreen)
// ==============================================================================
class AuthScreen extends StatefulWidget {
  final PlatformRole selectedRole;

  const AuthScreen({
    super.key,
    this.selectedRole = PlatformRole.cliente,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  String _selectedCountryCode = '+244'; // Prefixo padrão oficial (Angola)
  bool _isPhoneValid = false;

  final List<Map<String, String>> _countryCodes = const [
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
      // ========================================================================
      // LISTENER: Processa exclusivamente efeitos secundários (Navegação/Snackbars)
      // ========================================================================
      listener: (context, state) {
        if (state is OtpSendSuccess) {
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
                  Expanded(
                    child: Text(
                      state.message,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
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
      // ========================================================================
      // BUILDER: Árvore de Decisões Condicionais Puras e Mutuamente Exclusivas
      // Elimina o uso de Stack para impedir sobreposição de ecrãs na memória
      // ========================================================================
      builder: (context, state) {
        // ----------------------------------------------------------------------
        // ESTADO 1: Carregamento Ativo (AuthLoading)
        // Retorna unicamente o spinner centralizado isolado na tela
        // ----------------------------------------------------------------------
        if (state is AuthLoading) {
          return _buildLoadingScreen(activeColor, state.loadingMessage);
        }

        // ----------------------------------------------------------------------
        // ESTADO 2: Falha de Conexão de Rede (AuthNetworkError / ConnectionFailure)
        // Limpa todos os inputs anteriores e retorna unicamente o widget de erro
        // ----------------------------------------------------------------------
        if (state is AuthNetworkFailure) {
          return _buildNetworkErrorScreen(context, activeColor, state.message);
        }

        // ----------------------------------------------------------------------
        // ESTADO 3: Estado Inicial ou Padrão (AuthInitial / Unauthenticated)
        // Retorna o formulário limpo adaptado ao mercado de Angola ("Qual é o seu telemóvel?")
        // ----------------------------------------------------------------------
        return _buildPhoneInputScreen(context, activeColor, theme);
      },
    );
  }

  // ============================================================================
  // WIDGET 1: Ecrã Exclusivo de Carregamento (Loading State)
  // ============================================================================
  Widget _buildLoadingScreen(Color activeColor, String? loadingMessage) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: _buildAppBar(context, activeColor, showBackButton: false),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 54.0,
                  height: 54.0,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    valueColor: AlwaysStoppedAnimation<Color>(activeColor),
                  ),
                ),
                const SizedBox(height: 28.0),
                Text(
                  loadingMessage ?? 'A processar o seu pedido...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17.0,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 8.0),
                const Text(
                  'Por favor, aguarde um momento enquanto comunicamos com o servidor.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Color(0xFF64748B),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================================
  // WIDGET 2: Ecrã Exclusivo de Falha de Conexão (Network Error State)
  // ============================================================================
  Widget _buildNetworkErrorScreen(
    BuildContext context,
    Color activeColor,
    String message,
  ) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: _buildAppBar(context, activeColor, showBackButton: true),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
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
                SizedBox(
                  width: double.infinity,
                  height: 52.0,
                  child: FilledButton.icon(
                    onPressed: () {
                      // Dispara o evento oficial de retentativa de conexão
                      context.read<AuthBloc>().add(const TentarReconexaoEvent());
                    },
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
      ),
    );
  }

  // ============================================================================
  // WIDGET 3: Ecrã Exclusivo do Formulário Limpo (Initial State)
  // ============================================================================
  Widget _buildPhoneInputScreen(
    BuildContext context,
    Color activeColor,
    ThemeData theme,
  ) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: _buildAppBar(context, activeColor, showBackButton: true),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12.0),

                // Logótipo e Ícone Central
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
                  'Enviaremos um código SMS de 6 dígitos para validar a sua identidade de forma rápida e segura (RN-001, RN-002).',
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
                          onChanged: (value) {
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

                // Botão "Continuar" para Validação de OTP (RN-001, RN-002)
                FilledButton(
                  onPressed: _isPhoneValid ? _submitPhoneNumber : null,
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
                  child: const Text(
                    'Continuar',
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
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    Color activeColor, {
    required bool showBackButton,
  }) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      leading: showBackButton
          ? IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A)),
              onPressed: () => Navigator.of(context).pop(),
            )
          : null,
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

/// Alias semântico para retrocompatibilidade com chamadas existentes no ecossistema
typedef PhoneInputScreen = AuthScreen;

