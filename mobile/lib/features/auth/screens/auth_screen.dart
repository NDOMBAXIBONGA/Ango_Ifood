/// Ecrã de Autenticação: `AuthScreen` (`auth_screen.dart`)
/// Implementa a arquitetura de visualização condicional estrita via `BlocConsumer<AuthBloc, AuthState>`.
/// Utiliza o padrão Material Design 3 com autenticação por E-mail (com código OTP de 6 dígitos)
/// e autenticação social via Google Sign-In (`google_sign_in`).
///
/// O método `builder` utiliza blocos de decisão puros e mutuamente exclusivos para eliminar
/// definitivamente qualquer sobreposição visual (UI Stack Overlap), descarregando completamente
/// da memória os widgets de estados de erro e formulário.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/network/app_environment_config.dart';
import '../auth_bloc.dart';
import '../theme/role_theme.dart';
import '../utils/role_navigation.dart';
import 'email_otp_verification_screen.dart';
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
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isEmailValid = false;
  bool _isGoogleSigningIn = false;
  bool _usePasswordMode = false;
  bool _obscurePassword = true;

  // Expressão regular padrão RFC 5322 para validação de formato de e-mail
  static final RegExp _emailRegex = RegExp(
    r"^[a-zA-Z0-9.a-zA-Z0-9.!#$%&'*+-/=?^_`{|}~]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$",
  );

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_validateEmail);
  }

  @override
  void dispose() {
    _emailController.removeListener(_validateEmail);
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    super.dispose();
  }

  void _validateEmail() {
    final text = _emailController.text.trim();
    final isValid = _emailRegex.hasMatch(text);
    if (isValid != _isEmailValid) {
      setState(() {
        _isEmailValid = isValid;
      });
    }
  }

  void _submitPasswordLogin() {
    final email = _emailController.text.trim().toLowerCase();
    final password = _passwordController.text;
    if (email.isEmpty || !_emailRegex.hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor, insira um endereço de e-mail válido.'),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor, introduza a sua palavra-passe.'),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    context.read<AuthBloc>().add(
          LoginWithPasswordRequested(
            email: email,
            password: password,
          ),
        );
  }

  void _submitEmail() {
    if (_isEmailValid) {
      FocusScope.of(context).unfocus();
      final email = _emailController.text.trim().toLowerCase();
      context.read<AuthBloc>().add(
            SendEmailOtpEvent(email: email),
          );
    }
  }

  Future<void> _handleGoogleSignIn() async {
    if (_isGoogleSigningIn) return;

    setState(() {
      _isGoogleSigningIn = true;
    });

    try {
      final GoogleSignIn googleSignIn = GoogleSignIn(
        serverClientId: AppEnvironmentConfig.googleServerClientId.isNotEmpty
            ? AppEnvironmentConfig.googleServerClientId
            : null,
        scopes: <String>['email', 'profile', 'openid'],
      );

      final GoogleSignInAccount? account = await googleSignIn.signIn();
      if (account != null) {
        final GoogleSignInAuthentication auth = await account.authentication;
        final String? token = auth.idToken ?? auth.accessToken;
        if (mounted) {
          if (token != null && token.isNotEmpty) {
            context.read<AuthBloc>().add(
                  GoogleLoginSubmitted(token: token),
                );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Falha ao obter token de validação da conta Google.'),
                backgroundColor: Color(0xFFDC2626),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      }
    } catch (error) {
      if (mounted) {
        String errorMessage = 'Falha ao autenticar com a Google: $error';
        final errorStr = error.toString();
        if (errorStr.contains('10') || errorStr.contains('DEVELOPER_ERROR')) {
          errorMessage =
              'Erro de configuração Google (Código 10): Certifique-se de que a assinatura SHA-1 e o pacote com.delivery.app estão registados na consola Google Cloud.';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGoogleSigningIn = false;
        });
      }
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
          final isEmail = state.phone.contains('@');
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => isEmail
                  ? EmailOtpVerificationScreen(
                      email: state.phone,
                      selectedRole: widget.selectedRole,
                    )
                  : OtpVerificationScreen(
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
              content: Text(state.message),
              backgroundColor: const Color(0xFFDC2626),
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else if (state is Authenticated) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Bem-vindo, ${state.user.nome}!'),
              backgroundColor: const Color(0xFF16A34A),
              behavior: SnackBarBehavior.floating,
            ),
          );
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
        }
      },
      // ========================================================================
      // BUILDER: Renderização Condicional 100% Pura e Mutuamente Exclusiva
      // ========================================================================
      builder: (context, state) {
        // CASO 1: Erro de Rede ou Conectividade com a Cloud
        // Retorna exclusivamente a tela de erro, sem montar o formulário no DOM
        if (state is AuthNetworkError) {
          return _buildNetworkErrorScreen(
            context: context,
            message: state.message,
            onRetry: () {
              context.read<AuthBloc>().add(const TentarReconexaoEvent());
            },
          );
        }

        // CASO 2: Carregamento Assíncrono com Mensagem Dedicada
        if (state is AuthLoading || _isGoogleSigningIn) {
          final loadingMsg = state is AuthLoading
              ? (state.loadingMessage ?? 'A processar o pedido...')
              : 'A conectar com a Google...';
          return _buildLoadingScreen(context: context, message: loadingMsg, activeColor: activeColor);
        }

        // CASO 3: Estado Padrão (AuthInitial, Unauthenticated, etc.)
        // Renderiza exclusivamente o formulário de E-mail e Google Sign-In
        return _buildAuthFormScreen(
          context: context,
          theme: theme,
          activeColor: activeColor,
        );
      },
    );
  }

  // ============================================================================
  // WIDGET ISOLADO: Formulário de Autenticação por E-mail e Google Sign-In
  // ============================================================================
  Widget _buildAuthFormScreen({
    required BuildContext context,
    required ThemeData theme,
    required Color activeColor,
  }) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF0F172A), size: 20),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Chip(
              backgroundColor: activeColor.withOpacity(0.12),
              side: BorderSide(color: activeColor.withOpacity(0.3)),
              avatar: Icon(Icons.shield_outlined, size: 16, color: activeColor),
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
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          physics: const BouncingScrollPhysics(),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                        const SizedBox(height: 8),

                        // Seletor de Modo: Código OTP vs Entrar com Senha
                        Container(
                          padding: const EdgeInsets.all(4.0),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(14.0),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () => setState(() => _usePasswordMode = false),
                                  borderRadius: BorderRadius.circular(12.0),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 10.0),
                                    decoration: BoxDecoration(
                                      color: !_usePasswordMode ? Colors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12.0),
                                      boxShadow: !_usePasswordMode
                                          ? [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4, offset: const Offset(0, 2))]
                                          : null,
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.mark_email_read_outlined, size: 16.0, color: !_usePasswordMode ? activeColor : const Color(0xFF64748B)),
                                        const SizedBox(width: 6.0),
                                        Text(
                                          'Código OTP',
                                          style: TextStyle(
                                            fontSize: 13.0,
                                            fontWeight: FontWeight.w700,
                                            color: !_usePasswordMode ? activeColor : const Color(0xFF64748B),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: InkWell(
                                  onTap: () => setState(() => _usePasswordMode = true),
                                  borderRadius: BorderRadius.circular(12.0),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 10.0),
                                    decoration: BoxDecoration(
                                      color: _usePasswordMode ? Colors.white : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12.0),
                                      boxShadow: _usePasswordMode
                                          ? [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4, offset: const Offset(0, 2))]
                                          : null,
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.key_outlined, size: 16.0, color: _usePasswordMode ? activeColor : const Color(0xFF64748B)),
                                        const SizedBox(width: 6.0),
                                        Text(
                                          'Entrar com Senha',
                                          style: TextStyle(
                                            fontSize: 13.0,
                                            fontWeight: FontWeight.w700,
                                            color: _usePasswordMode ? activeColor : const Color(0xFF64748B),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20),

                        // Ícone de cabeçalho do perfil/papel
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 60,
                            height: 60,
                            decoration: BoxDecoration(
                              color: activeColor.withOpacity(0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _usePasswordMode ? Icons.lock_person_rounded : Icons.mail_lock_rounded,
                              size: 30,
                              color: activeColor,
                            ),
                          ),
                        ),

                        const SizedBox(height: 20),

                        // Título do Ecrã
                        Text(
                          _usePasswordMode ? 'Iniciar Sessão' : 'Qual é o seu e-mail?',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF0F172A),
                            letterSpacing: -0.5,
                          ),
                        ),

                        const SizedBox(height: 8),

                        // Subtítulo Explicativo
                        Text(
                          _usePasswordMode
                              ? 'Introduza o seu e-mail e palavra-passe para aceder diretamente à sua conta.'
                              : 'Enviaremos um código de 6 dígitos para o seu e-mail para validar a sua identidade de forma rápida e segura.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF64748B),
                            height: 1.45,
                            fontSize: 14,
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Rótulo do Campo
                        const Text(
                          'Endereço de E-mail',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF334155),
                          ),
                        ),

                        const SizedBox(height: 8),

                        // Campo de Entrada de E-mail
                        TextFormField(
                          controller: _emailController,
                          focusNode: _emailFocusNode,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: _usePasswordMode ? TextInputAction.next : TextInputAction.done,
                          autocorrect: false,
                          enableSuggestions: true,
                          onFieldSubmitted: (_) => _usePasswordMode ? null : _submitEmail(),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0F172A),
                          ),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.white,
                            hintText: 'exemplo@dominio.com',
                            hintStyle: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                            ),
                            prefixIcon: Icon(
                              Icons.email_outlined,
                              color: _isEmailValid ? activeColor : const Color(0xFF94A3B8),
                              size: 22,
                            ),
                            suffixIcon: _isEmailValid
                                ? const Icon(
                                    Icons.check_circle_rounded,
                                    color: Color(0xFF10B981),
                                    size: 22,
                                  )
                                : (_emailController.text.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear_rounded, color: Color(0xFF94A3B8), size: 18),
                                        onPressed: () {
                                          _emailController.clear();
                                          setState(() => _isEmailValid = false);
                                        },
                                      )
                                    : null),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                color: _isEmailValid ? activeColor.withOpacity(0.5) : const Color(0xFFE2E8F0),
                                width: 1.5,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide(
                                color: activeColor,
                                width: 2.0,
                              ),
                            ),
                          ),
                        ),

                        // Campo de Palavra-passe (Visível no modo de Senha)
                        if (_usePasswordMode) ...[
                          const SizedBox(height: 18),
                          const Text(
                            'Palavra-passe',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF334155),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submitPasswordLogin(),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF0F172A),
                            ),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: Colors.white,
                              hintText: '••••••••',
                              hintStyle: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                              ),
                              prefixIcon: Icon(
                                Icons.lock_outline_rounded,
                                color: const Color(0xFF94A3B8),
                                size: 22,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                  color: const Color(0xFF64748B),
                                  size: 20,
                                ),
                                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: const BorderSide(
                                  color: Color(0xFFE2E8F0),
                                  width: 1.5,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: activeColor,
                                  width: 2.0,
                                ),
                              ),
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),

                        // Botão Principal de Submissão
                        ElevatedButton(
                          onPressed: _usePasswordMode
                              ? _submitPasswordLogin
                              : (_isEmailValid ? _submitEmail : null),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: activeColor,
                            disabledBackgroundColor: const Color(0xFFE2E8F0),
                            foregroundColor: Colors.white,
                            disabledForegroundColor: const Color(0xFF94A3B8),
                            elevation: (_usePasswordMode || _isEmailValid) ? 2 : 0,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _usePasswordMode ? 'Iniciar Sessão' : 'Continuar com Código',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.3,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(_usePasswordMode ? Icons.login_rounded : Icons.arrow_forward_rounded, size: 18),
                            ],
                          ),
                        ),

                        const SizedBox(height: 28),

                        // Divisor Visual: "ou entrar com"
                        Row(
                          children: [
                            const Expanded(
                              child: Divider(
                                color: Color(0xFFE2E8F0),
                                thickness: 1,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16.0),
                              child: Text(
                                'ou entrar com',
                                style: TextStyle(
                                  color: const Color(0xFF64748B),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const Expanded(
                              child: Divider(
                                color: Color(0xFFE2E8F0),
                                thickness: 1,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 24),

                        // Botão Oficial Google Sign-In
                        OutlinedButton(
                          onPressed: _handleGoogleSignIn,
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: const Color(0xFF0F172A),
                            side: const BorderSide(color: Color(0xFFCBD5E1), width: 1.2),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 0,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const _GoogleLogo(),
                              const SizedBox(width: 12),
                              const Text(
                                'Continuar com o Google',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1E293B),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 32),

                        // Rodapé de Termos e Privacidade
                        Center(
                          child: Text(
                            'Ao continuar, confirma que aceita os Termos de Serviço\ne a Política de Privacidade da plataforma.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: const Color(0xFF94A3B8),
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

  // ============================================================================
  // WIDGET ISOLADO: Tela de Falha de Conexão / Erro de Rede
  // ============================================================================
  Widget _buildNetworkErrorScreen({
    required BuildContext context,
    required String message,
    required VoidCallback onRetry,
  }) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),

              // Ícone de Nuvem Desconectada com Fundo Suave
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEE2E2),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.cloud_off_rounded,
                      size: 48,
                      color: Color(0xFFDC2626),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Nome da Aplicação
              const Text(
                'DELIVERY PRO',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: Color(0xFF0F172A),
                ),
              ),

              const SizedBox(height: 4),

              const Text(
                'Plataforma de Entregas de Angola',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF64748B),
                ),
              ),

              const SizedBox(height: 32),

              // Card de Erro de Conexão
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFCA5A5).withOpacity(0.4),
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Falha de Comunicação',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF991B1B),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      message.isNotEmpty
                          ? message
                          : 'Erro ao ligar ao servidor. Verifique a sua ligação à internet.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: Color(0xFFB91C1C),
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // Botão Tentar Novamente
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 20),
                label: const Text(
                  'Tentar Novamente',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================================
  // WIDGET ISOLADO: Tela de Carregamento Assíncrono
  // ============================================================================
  Widget _buildLoadingScreen({
    required BuildContext context,
    required String message,
    required Color activeColor,
  }) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(activeColor),
                strokeWidth: 3.5,
              ),
              const SizedBox(height: 24),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF334155),
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
// 2. LOGÓTIPO OFICIAL DO GOOGLE (Vetor Nativo Multi-Cores)
// ==============================================================================
class _GoogleLogo extends StatelessWidget {
  static const double size = 22.0;

  const _GoogleLogo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GoogleLogoPainter(),
      ),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final center = Offset(w / 2, h / 2);
    final radius = w / 2;

    // Pinturas para as 4 cores oficiais da Google
    final paintBlue = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.fill;

    final paintRed = Paint()
      ..color = const Color(0xFFEA4335)
      ..style = PaintingStyle.fill;

    final paintYellow = Paint()
      ..color = const Color(0xFFFBBC05)
      ..style = PaintingStyle.fill;

    final paintGreen = Paint()
      ..color = const Color(0xFF34A853)
      ..style = PaintingStyle.fill;

    // Barra horizontal do 'G' (Azul)
    final blueBar = Rect.fromLTRB(w * 0.45, h * 0.38, w, h * 0.62);
    canvas.drawRRect(RRect.fromRectAndRadius(blueBar, Radius.circular(w * 0.08)), paintBlue);

    // Arcos coloridos em volta
    final arcRect = Rect.fromCircle(center: center, radius: radius * 0.85);
    const strokeWidth = 3.6;

    final arcPaintRed = Paint()
      ..color = const Color(0xFFEA4335)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final arcPaintYellow = Paint()
      ..color = const Color(0xFFFBBC05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final arcPaintGreen = Paint()
      ..color = const Color(0xFF34A853)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final arcPaintBlue = Paint()
      ..color = const Color(0xFF4285F4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Arco Vermelho (Topo)
    canvas.drawArc(arcRect, -2.4, 1.6, false, arcPaintRed);
    // Arco Amarelo (Esquerda inferior)
    canvas.drawArc(arcRect, 2.3, 1.2, false, arcPaintYellow);
    // Arco Verde (Fundo)
    canvas.drawArc(arcRect, 0.7, 1.6, false, arcPaintGreen);
    // Arco Azul (Direita)
    canvas.drawArc(arcRect, -0.6, 1.3, false, arcPaintBlue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
