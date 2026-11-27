import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_environment_config.dart';
import '../../auth/auth_bloc.dart';
import '../../auth/auth_event.dart';
import '../../auth/auth_state.dart';
import '../../auth/screens/auth_screen.dart';
import '../../catalog/customer_main_navigation_shell.dart';
import '../../auth/storage/secure_token_storage.dart';
import '../../auth/theme/role_theme.dart';
import '../../cart/cart.dart';
import '../../catalog/customer_catalog_screens.dart';

/// Ecrã de Perfil Completo do Cliente (`CustomerProfileScreen`).
/// Disponibiliza edição de dados pessoais, gestão de moradas PostGIS (RN-005),
/// configuração de meios de pagamento (RN-065), preferências de notificações (RN-004),
/// alteração de palavra-passe e Central de Ajuda & Disputas (RN-138 a RN-142).
class CustomerProfileScreen extends StatefulWidget {
  final int refreshTrigger;

  const CustomerProfileScreen({
    super.key,
    this.refreshTrigger = 0,
  });

  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  final SecureTokenStorage _tokenStorage = SecureTokenStorage();
  bool _hasToken = false;
  String _nome = 'Cliente';
  String _email = '';
  String _telemovel = '';
  bool _notifPedidos = true;
  bool _marketing = false;
  bool _gpsBackground = true;

  @override
  void initState() {
    super.initState();
    _loadProfileFromBackend();
  }

  @override
  void didUpdateWidget(covariant CustomerProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTrigger != oldWidget.refreshTrigger) {
      _loadProfileFromBackend();
    }
  }

  Future<Dio?> _buildAuthDio() async {
    var token = await _tokenStorage.getAccessToken();
    if ((token == null || token.isEmpty) && mounted) {
      try {
        final authState = context.read<AuthBloc>().state;
        if (authState is Authenticated && authState.tokens.accessToken.isNotEmpty) {
          token = authState.tokens.accessToken;
          await _tokenStorage.saveTokens(
            accessToken: authState.tokens.accessToken,
            refreshToken: authState.tokens.refreshToken,
            userRole: authState.user.tipoUtilizador,
          );
        }
      } catch (_) {}
    }
    if (token == null || token.isEmpty) return null;
    return createSecureDioClient(tokenStorage: _tokenStorage);
  }

  Future<void> _loadProfileFromBackend() async {
    try {
      var token = await _tokenStorage.getAccessToken();
      if ((token == null || token.isEmpty) && mounted) {
        try {
          final authState = context.read<AuthBloc>().state;
          if (authState is Authenticated && authState.tokens.accessToken.isNotEmpty) {
            token = authState.tokens.accessToken;
            await _tokenStorage.saveTokens(
              accessToken: authState.tokens.accessToken,
              refreshToken: authState.tokens.refreshToken,
              userRole: authState.user.tipoUtilizador,
            );
          }
        } catch (_) {}
      }

      final hasTokenNow = token != null && token.isNotEmpty;
      if (mounted && _hasToken != hasTokenNow) {
        setState(() {
          _hasToken = hasTokenNow;
        });
      }

      if (!hasTokenNow) return;

      final dio = await _buildAuthDio();
      if (dio == null) return;
      final resp = await dio.get<Map<String, dynamic>>('/api/v1/auth/profile/');
      final data = resp.data;
      if (data == null || !mounted) return;

      final perfil = data['perfil'] as Map<String, dynamic>? ?? {};
      final consent = data['consentimentos'] as Map<String, dynamic>? ?? {};

      final fetchedName = (perfil['nome'] ?? '').toString().trim();
      final fetchedEmail = (perfil['email'] ?? '').toString().trim();
      final fetchedPhone = (perfil['telemovel'] ?? '').toString().trim();

      setState(() {
        _hasToken = true;
        if (fetchedName.isNotEmpty) {
          _nome = fetchedName;
        }
        if (fetchedEmail.isNotEmpty) {
          _email = fetchedEmail;
        }
        if (fetchedPhone.isNotEmpty) {
          _telemovel = fetchedPhone;
        }
        _marketing = (consent['marketing'] as bool?) ?? _marketing;
        _gpsBackground =
            (consent['localizacao_segundo_plano'] as bool?) ?? _gpsBackground;
      });

      if (mounted && perfil.isNotEmpty) {
        context.read<AuthBloc>().add(
              UpdateUserProfileEvent(
                user: UserProfile.fromJson(perfil),
              ),
            );
      }
    } catch (_) {}
  }

  Future<void> _promptLoginIfNeeded(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AuthScreen(
          selectedRole: PlatformRole.cliente,
        ),
      ),
    );
    if (mounted) {
      await _loadProfileFromBackend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocListener<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is Authenticated) {
          setState(() {
            _hasToken = true;
            if (state.user.nome.trim().isNotEmpty &&
                state.user.nome.trim() != 'Utilizador') {
              _nome = state.user.nome.trim();
            }
            if (state.user.email.trim().isNotEmpty) {
              _email = state.user.email.trim();
            }
            if (state.user.telemovel.trim().isNotEmpty) {
              _telemovel = state.user.telemovel.trim();
            }
          });
          _loadProfileFromBackend();
        } else if (state is Unauthenticated) {
          setState(() {
            _hasToken = false;
            _nome = 'Cliente';
            _email = '';
            _telemovel = '';
          });
        }
      },
      child: AnimatedBuilder(
        animation: CartService.instance,
        builder: (context, _) {
          final cart = CartService.instance;

          return BlocBuilder<AuthBloc, AuthState>(
            builder: (context, authState) {
              final bool isAuthenticated = (authState is Authenticated) ||
                  _hasToken ||
                  (SecureTokenStorage.cachedAccessToken?.isNotEmpty ?? false);

              String userName = _nome;
              String userEmail = _email;
              String userPhone = _telemovel;

              if (authState is Authenticated) {
                if ((userName == 'Cliente' || userName == 'Utilizador' || userName.isEmpty) &&
                    authState.user.nome.trim().isNotEmpty &&
                    authState.user.nome.trim() != 'Utilizador') {
                  userName = authState.user.nome.trim();
                }
                if (userEmail.isEmpty && authState.user.email.trim().isNotEmpty) {
                  userEmail = authState.user.email.trim();
                }
                if (userPhone.isEmpty && authState.user.telemovel.trim().isNotEmpty) {
                  userPhone = authState.user.telemovel.trim();
                }
              }

              return Scaffold(
                appBar: AppBar(
                  title: const Text('O Meu Perfil'),
                  actions: [
                    if (isAuthenticated)
                      IconButton(
                        tooltip: 'Editar Dados Pessoais',
                        onPressed: () => _openEditProfileSheet(
                          context,
                          initialName: userName,
                          initialEmail: userEmail,
                          initialPhone: userPhone,
                        ),
                        icon: const Icon(Icons.edit_outlined),
                      )
                    else
                      TextButton.icon(
                        onPressed: () => _promptLoginIfNeeded(context),
                        icon: const Icon(Icons.login_rounded, size: 18),
                        label: const Text('Entrar'),
                      ),
                  ],
                ),
                body: ListView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                  children: [
                    // Cabeçalho de Perfil com Avatar + Estado da Conta
                    Center(
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 46,
                            backgroundColor: colorScheme.primaryContainer,
                            child: Text(
                              userName.isNotEmpty
                                  ? userName.trim().substring(0, 1).toUpperCase()
                                  : 'C',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (isAuthenticated) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDCFCE7),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.verified_user_rounded,
                                    size: 14,
                                    color: Color(0xFF15803D),
                                  ),
                                  SizedBox(width: 5),
                                  Text(
                                    'Conta de Cliente Ativa',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF15803D),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          Text(
                            userName,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          if (userEmail.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              userEmail,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          if (userPhone.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              userPhone,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ] else if (isAuthenticated) ...[
                            const SizedBox(height: 4),
                            InkWell(
                              onTap: () => _openEditProfileSheet(
                                context,
                                initialName: userName,
                                initialEmail: userEmail,
                                initialPhone: userPhone,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                child: Text(
                                  'Toque para adicionar o seu nº de telemóvel (+244)',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 10),
                          if (!isAuthenticated) ...[
                            Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF2F2),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: const Color(0xFFFECACA)),
                              ),
                              child: Column(
                                children: [
                                  const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.person_outline, size: 20, color: Color(0xFFDC2626)),
                                      SizedBox(width: 8),
                                      Text(
                                        'A navegar como Visitante',
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF991B1B),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    'Crie uma conta para salvar endereços favoritos, repetir pedidos e gerir dados de pagamento.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 12, color: Color(0xFF7F1D1D)),
                                  ),
                                  const SizedBox(height: 12),
                                  FilledButton.icon(
                                    onPressed: () => _promptLoginIfNeeded(context),
                                    icon: const Icon(Icons.login_rounded, size: 16),
                                    label: const Text('Criar Conta / Iniciar Sessão'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFDC2626),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 6,
                                    children: [
                                      TextButton.icon(
                                        onPressed: () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) => const AuthScreen(
                                                selectedRole: PlatformRole.parceiro,
                                              ),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.storefront_outlined, size: 14),
                                        label: const Text('Portal do Parceiro', style: TextStyle(fontSize: 12)),
                                      ),
                                      TextButton.icon(
                                        onPressed: () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) => const AuthScreen(
                                                selectedRole: PlatformRole.estafeta,
                                              ),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.two_wheeler_outlined, size: 14),
                                        label: const Text('Central do Estafeta', style: TextStyle(fontSize: 12)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            OutlinedButton.icon(
                              onPressed: () => _openEditProfileSheet(
                                context,
                                initialName: userName,
                                initialEmail: userEmail,
                                initialPhone: userPhone,
                              ),
                              icon: const Icon(Icons.person_outline, size: 18),
                              label: const Text('Editar Dados Pessoais'),
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Bloco: A Minha Conta
                    _buildSectionHeader(context, 'A Minha Conta'),
                    if (isAuthenticated)
                      _buildSettingsTile(
                        context,
                        icon: Icons.badge_outlined,
                        title: 'Dados Pessoais da Conta',
                        subtitle:
                            '$userName${userEmail.isNotEmpty ? ' • $userEmail' : ''}${userPhone.isNotEmpty ? ' • $userPhone' : ''}',
                        onTap: () => _openEditProfileSheet(
                          context,
                          initialName: userName,
                          initialEmail: userEmail,
                          initialPhone: userPhone,
                        ),
                      ),
                    _buildSettingsTile(
                      context,
                      icon: Icons.location_on_outlined,
                      title: 'Moradas de Entrega',
                      subtitle: '${cart.moradaLabel} • ${cart.moradaTexto}',
                      onTap: () => showCustomerAddressSelectionSheet(context),
                    ),
                    _buildSettingsTile(
                      context,
                      icon: Icons.payment_outlined,
                      title: 'Meios de Pagamento',
                      subtitle: _paymentDisplayLabel(cart.preferredPaymentCode),
                      onTap: () => _openPaymentMethodsSheet(context),
                    ),
                    _buildSettingsTile(
                      context,
                      icon: Icons.notifications_none_rounded,
                      title: 'Notificações & Privacidade',
                      subtitle: _marketing
                          ? 'Alertas de pedidos e promoções ativos'
                          : 'Apenas alertas essenciais de estado do pedido',
                      onTap: () => _openNotificationsSheet(context),
                    ),

                    const SizedBox(height: 24),

                    // Bloco: Segurança e Ajuda
                    _buildSectionHeader(context, 'Segurança & Suporte'),
                    _buildSettingsTile(
                      context,
                      icon: Icons.lock_outline_rounded,
                      title: 'Segurança & Palavra-passe',
                      subtitle: 'Alterar ou definir palavra-passe de acesso',
                      onTap: () {
                        if (!isAuthenticated) {
                          _promptLoginIfNeeded(context);
                          return;
                        }
                        _openChangePasswordSheet(context);
                      },
                    ),
                    _buildSettingsTile(
                      context,
                      icon: Icons.support_agent_rounded,
                      title: 'Ajuda, Suporte & Disputas',
                      subtitle:
                          'Abrir reclamação de pedido, consultar tickets e FAQ',
                      onTap: () => _openSupportAndDisputesSheet(context),
                    ),

                    if (isAuthenticated) ...[
                      const SizedBox(height: 24),

                      // Botão de Terminar Sessão (apenas quando autenticado)
                      Card(
                        elevation: 0,
                        color: colorScheme.errorContainer.withOpacity(0.18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: colorScheme.error.withOpacity(0.3),
                          ),
                        ),
                        child: ListTile(
                          leading: Icon(
                            Icons.logout_rounded,
                            color: colorScheme.error,
                          ),
                          title: Text(
                            'Terminar Sessão',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colorScheme.error,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle:
                              const Text('Desconectar a sua conta com segurança'),
                          onTap: () => _showLogoutConfirmDialog(context),
                        ),
                      ),
                    ],

                    const SizedBox(height: 36),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  String _paymentDisplayLabel(String code) {
    switch (code) {
      case 'CARTAO':
        return 'Cartão Bancário (Multicaixa / Visa)';
      case 'NUMERARIO':
        return 'Dinheiro na Entrega (Numerário)';
      default:
        return 'Multicaixa Express (${CartService.instance.preferredMcxPhone})';
    }
  }

  // ===========================================================================
  // 1. MODAL: EDITAR DADOS PESSOAIS (`PATCH /api/v1/auth/profile/`)
  // ===========================================================================

  Future<void> _openEditProfileSheet(
    BuildContext context, {
    String? initialName,
    String? initialEmail,
    String? initialPhone,
  }) async {
    final nameCtrl = TextEditingController(text: initialName ?? _nome);
    final emailCtrl = TextEditingController(text: initialEmail ?? _email);
    final phoneCtrl = TextEditingController(text: initialPhone ?? _telemovel);
    bool isSaving = false;
    String? errorMsg;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                8,
                24,
                MediaQuery.of(context).viewInsets.bottom + 28,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Editar Dados Pessoais',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 16),
                  if (errorMsg != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        errorMsg!,
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nome Completo',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Telemóvel (+244)',
                      hintText: '+244923000000',
                      prefixIcon: Icon(Icons.phone_android_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Endereço de E-mail',
                      prefixIcon: Icon(Icons.email_outlined),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: isSaving
                        ? null
                        : () async {
                            final novoNome = nameCtrl.text.trim();
                            if (novoNome.length < 2) {
                              setModalState(() =>
                                  errorMsg = 'Informe um nome válido.');
                              return;
                            }
                            setModalState(() {
                              isSaving = true;
                              errorMsg = null;
                            });
                            try {
                              final dio = await _buildAuthDio();
                              if (dio != null) {
                                final resp = await dio.patch<Map<String, dynamic>>(
                                  '/api/v1/auth/profile/',
                                  data: {
                                    'nome': novoNome,
                                    'telemovel': phoneCtrl.text.trim(),
                                    'email': emailCtrl.text.trim(),
                                  },
                                );
                                final updatedPerfil = resp.data?['perfil'];
                                if (mounted && updatedPerfil is Map<String, dynamic>) {
                                  this.context.read<AuthBloc>().add(
                                        UpdateUserProfileEvent(
                                          user: UserProfile.fromJson(updatedPerfil),
                                        ),
                                      );
                                }
                              }
                              if (mounted) {
                                setState(() {
                                  _nome = novoNome;
                                  _telemovel = phoneCtrl.text.trim();
                                  _email = emailCtrl.text.trim();
                                });
                              }
                              if (sheetCtx.mounted) {
                                Navigator.of(sheetCtx).pop();
                              }
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                        'Dados pessoais atualizados com sucesso!'),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            } on DioException catch (e) {
                              final msg = (e.response?.data is Map)
                                  ? (e.response?.data['detalhe'] ??
                                      'Erro ao guardar alterações.')
                                  : 'Erro ao guardar alterações.';
                              setModalState(() {
                                isSaving = false;
                                errorMsg = '$msg';
                              });
                            }
                          },
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                        isSaving ? 'A guardar...' : 'Guardar Alterações'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // 2. MODAL: MEIOS DE PAGAMENTO PREFERIDOS (RN-065)
  // ===========================================================================

  Future<void> _openPaymentMethodsSheet(BuildContext context) async {
    final cart = CartService.instance;
    String selectedCode = cart.preferredPaymentCode;
    final phoneCtrl = TextEditingController(text: cart.preferredMcxPhone);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                8,
                24,
                MediaQuery.of(context).viewInsets.bottom + 28,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Meios de Pagamento',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Escolha o seu método de pagamento predefinido para o Checkout.',
                  ),
                  const SizedBox(height: 16),
                  RadioListTile<String>(
                    value: 'CARTEIRA_DIGITAL',
                    groupValue: selectedCode,
                    onChanged: (v) =>
                        setModalState(() => selectedCode = v ?? selectedCode),
                    title: const Text(
                      'Multicaixa Express / Carteira Digital',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text(
                      'Autorização instantânea no telemóvel em Kwanzas (Kz)',
                    ),
                    secondary: const Icon(Icons.account_balance_wallet_rounded),
                  ),
                  if (selectedCode == 'CARTEIRA_DIGITAL') ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: TextField(
                        controller: phoneCtrl,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Telemóvel Multicaixa Express',
                          prefixIcon: Icon(Icons.phone_iphone_rounded),
                        ),
                      ),
                    ),
                  ],
                  RadioListTile<String>(
                    value: 'CARTAO',
                    groupValue: selectedCode,
                    onChanged: (v) =>
                        setModalState(() => selectedCode = v ?? selectedCode),
                    title: const Text(
                      'Cartão Bancário (TPA / Multicaixa / Visa)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text('Pagamento seguro por cartão'),
                    secondary: const Icon(Icons.credit_card_rounded),
                  ),
                  RadioListTile<String>(
                    value: 'NUMERARIO',
                    groupValue: selectedCode,
                    onChanged: (v) =>
                        setModalState(() => selectedCode = v ?? selectedCode),
                    title: const Text(
                      'Dinheiro na Entrega (Numerário)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: const Text(
                      'Pague diretamente ao estafeta no ato da entrega',
                    ),
                    secondary: const Icon(Icons.payments_rounded),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () {
                      cart.updatePreferredPayment(
                        paymentCode: selectedCode,
                        mcxPhone: phoneCtrl.text.trim(),
                      );
                      Navigator.of(sheetCtx).pop();
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Preferência de pagamento guardada com sucesso!'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Guardar Meio de Pagamento'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // 3. MODAL: NOTIFICAÇÕES & PRIVACIDADE (RN-004)
  // ===========================================================================

  Future<void> _openNotificationsSheet(BuildContext context) async {
    bool tempPedidos = _notifPedidos;
    bool tempMarketing = _marketing;
    bool tempGps = _gpsBackground;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Notificações & Privacidade',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: tempPedidos,
                    onChanged: (v) => setModalState(() => tempPedidos = v),
                    title: const Text('Estado dos Pedidos em Tempo Real'),
                    subtitle: const Text(
                      'Avisos de preparação, saída do estafeta e chegada à porta',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: tempMarketing,
                    onChanged: (v) => setModalState(() => tempMarketing = v),
                    title: const Text('Cupões, Ofertas & Promoções'),
                    subtitle: const Text(
                      'Receber descontos exclusivos de restaurantes parceiros',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: tempGps,
                    onChanged: (v) => setModalState(() => tempGps = v),
                    title: const Text('Localização Precisa de Entrega'),
                    subtitle: const Text(
                      'Facilitar o encontro com o estafeta na sua morada',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () async {
                      setState(() {
                        _notifPedidos = tempPedidos;
                        _marketing = tempMarketing;
                        _gpsBackground = tempGps;
                      });
                      Navigator.of(sheetCtx).pop();
                      try {
                        final dio = await _buildAuthDio();
                        if (dio != null) {
                          await dio.patch<void>(
                            '/api/v1/auth/profile/',
                            data: {
                              'marketing': tempMarketing,
                              'localizacao_segundo_plano': tempGps,
                            },
                          );
                        }
                      } catch (_) {}
                      if (mounted) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(
                            content:
                                Text('Preferências de notificações guardadas!'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                    child: const Text('Guardar Preferências'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // 4. MODAL: SEGURANÇA & PALAVRA-PASSE (`POST /api/v1/auth/change-password/`)
  // ===========================================================================

  Future<void> _openChangePasswordSheet(BuildContext context) async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    bool isSaving = false;
    String? errorMsg;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                8,
                24,
                MediaQuery.of(context).viewInsets.bottom + 28,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Segurança & Palavra-passe',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Atualize a sua palavra-passe para acesso direto por e-mail/telemóvel.',
                  ),
                  const SizedBox(height: 16),
                  if (errorMsg != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        errorMsg!,
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                  TextField(
                    controller: currentCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Palavra-passe Atual (se já tiver uma)',
                      prefixIcon: Icon(Icons.lock_clock_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: newCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Nova Palavra-passe (mín. 6 caracteres) *',
                      prefixIcon: Icon(Icons.lock_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: confirmCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Confirmar Nova Palavra-passe *',
                      prefixIcon: Icon(Icons.verified_user_outlined),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: isSaving
                        ? null
                        : () async {
                            final nova = newCtrl.text;
                            final conf = confirmCtrl.text;
                            if (nova.length < 6) {
                              setModalState(() => errorMsg =
                                  'A nova palavra-passe deve ter pelo menos 6 caracteres.');
                              return;
                            }
                            if (nova != conf) {
                              setModalState(() => errorMsg =
                                  'A confirmação não coincide com a nova palavra-passe.');
                              return;
                            }
                            setModalState(() {
                              isSaving = true;
                              errorMsg = null;
                            });
                            try {
                              final dio = await _buildAuthDio();
                              if (dio != null) {
                                await dio.post<void>(
                                  '/api/v1/auth/change-password/',
                                  data: {
                                    'senha_atual': currentCtrl.text,
                                    'nova_senha': nova,
                                    'confirmar_senha': conf,
                                  },
                                );
                              }
                              if (sheetCtx.mounted) {
                                Navigator.of(sheetCtx).pop();
                              }
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                        'Palavra-passe atualizada com sucesso!'),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                            } on DioException catch (e) {
                              final msg = (e.response?.data is Map)
                                  ? (e.response?.data['detalhe'] ??
                                      'Não foi possível atualizar a palavra-passe.')
                                  : 'Não foi possível atualizar a palavra-passe.';
                              setModalState(() {
                                isSaving = false;
                                errorMsg = '$msg';
                              });
                            }
                          },
                    icon: const Icon(Icons.key_rounded),
                    label: Text(
                        isSaving ? 'A atualizar...' : 'Atualizar Palavra-passe'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ===========================================================================
  // 5. MODAL: CENTRAL DE AJUDA, SUPORTE & DISPUTAS (`RN-138` a `RN-142`)
  // ===========================================================================

  Future<void> _openSupportAndDisputesSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => const _CustomerSupportAndDisputesSheet(),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  Widget _buildSettingsTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.4)),
      ),
      child: ListTile(
        leading: Icon(icon, color: colorScheme.primary),
        title: Text(
          title,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: colorScheme.onSurfaceVariant,
        ),
        onTap: onTap,
      ),
    );
  }

  void _showLogoutConfirmDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Terminar Sessão?'),
          content: const Text(
            'Tem a certeza que pretende terminar a sessão no Delivery Pro?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                context.read<AuthBloc>().add(const LogoutRequested());
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute<void>(
                    builder: (_) => const CustomerMainNavigationShell(),
                  ),
                  (route) => false,
                );
              },
              child: const Text('Terminar Sessão'),
            ),
          ],
        );
      },
    );
  }
}

class _CustomerSupportAndDisputesSheet extends StatefulWidget {
  const _CustomerSupportAndDisputesSheet();

  @override
  State<_CustomerSupportAndDisputesSheet> createState() =>
      _CustomerSupportAndDisputesSheetState();
}

class _CustomerSupportAndDisputesSheetState
    extends State<_CustomerSupportAndDisputesSheet> {
  bool _isLoading = true;
  bool _showCreateTicket = false;
  bool _isSubmitting = false;
  String? _errorMsg;
  List<Map<String, dynamic>> _tickets = [];
  List<Map<String, dynamic>> _recentOrders = [];
  String? _selectedOrderId;
  String _selectedIncidentType = 'DISPUTA_COMERCIAL';
  final _motivoController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSupportData();
  }

  @override
  void dispose() {
    _motivoController.dispose();
    super.dispose();
  }

  Future<Dio?> _buildAuthDio() async {
    var token = await SecureTokenStorage().getAccessToken();
    if ((token == null || token.isEmpty) && mounted) {
      try {
        final authState = context.read<AuthBloc>().state;
        if (authState is Authenticated && authState.tokens.accessToken.isNotEmpty) {
          token = authState.tokens.accessToken;
          await SecureTokenStorage().saveTokens(
            accessToken: authState.tokens.accessToken,
            refreshToken: authState.tokens.refreshToken,
            userRole: authState.user.tipoUtilizador,
          );
        }
      } catch (_) {}
    }
    if (token == null || token.isEmpty) return null;
    return createSecureDioClient(tokenStorage: SecureTokenStorage());
  }

  Future<void> _loadSupportData() async {
    setState(() => _isLoading = true);
    try {
      final dio = await _buildAuthDio();
      if (dio == null) {
        setState(() => _isLoading = false);
        return;
      }
      final results = await Future.wait([
        dio.get<dynamic>('/api/v1/support/disputes/'),
        dio.get<dynamic>('/api/v1/orders/'),
      ]);

      List<dynamic> rawTickets = const [];
      if (results[0].data is List) {
        rawTickets = results[0].data as List<dynamic>;
      } else if (results[0].data is Map &&
          (results[0].data as Map)['results'] is List) {
        rawTickets = (results[0].data as Map)['results'] as List<dynamic>;
      }

      List<dynamic> rawOrders = const [];
      if (results[1].data is List) {
        rawOrders = results[1].data as List<dynamic>;
      } else if (results[1].data is Map &&
          (results[1].data as Map)['results'] is List) {
        rawOrders = (results[1].data as Map)['results'] as List<dynamic>;
      }

      final parsedOrders =
          rawOrders.whereType<Map<String, dynamic>>().toList();
      if (mounted) {
        setState(() {
          _tickets = rawTickets.whereType<Map<String, dynamic>>().toList();
          _recentOrders = parsedOrders;
          if (_selectedOrderId == null && parsedOrders.isNotEmpty) {
            _selectedOrderId = parsedOrders.first['id']?.toString();
          }
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _submitTicket() async {
    if (_selectedOrderId == null || _selectedOrderId!.isEmpty) {
      setState(() =>
          _errorMsg = 'Selecione o pedido associado à reclamação.');
      return;
    }
    if (_motivoController.text.trim().length < 10) {
      setState(() => _errorMsg =
          'Descreva o problema com pelo menos 10 caracteres.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMsg = null;
    });

    try {
      final dio = await _buildAuthDio();
      if (dio != null) {
        await dio.post<dynamic>(
          '/api/v1/support/disputes/',
          data: {
            'pedido_id': _selectedOrderId,
            'tipo_incidente': _selectedIncidentType,
            'prioridade': 'ALTA',
            'motivo': _motivoController.text.trim(),
          },
        );
      }
      _motivoController.clear();
      setState(() {
        _isSubmitting = false;
        _showCreateTicket = false;
      });
      await _loadSupportData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Ticket de suporte aberto com sucesso! A nossa equipa irá analisar.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } on DioException catch (e) {
      setState(() {
        _isSubmitting = false;
        _errorMsg = e.response?.data?.toString() ??
            'Não foi possível abrir o ticket neste momento.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: double.infinity,
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _showCreateTicket
                          ? 'Abrir Ticket de Disputa'
                          : 'Central de Ajuda & Disputas',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(_showCreateTicket ? Icons.arrow_back : Icons.close),
                    onPressed: () {
                      if (_showCreateTicket) {
                        setState(() => _showCreateTicket = false);
                      } else {
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                ],
              ),
              if (!_showCreateTicket) ...[
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(42),
                  ),
                  onPressed: () => setState(() => _showCreateTicket = true),
                  icon: const Icon(Icons.report_problem_outlined, size: 20),
                  label: const Text('Reportar Problema / Disputa'),
                ),
              ],
              const SizedBox(height: 12),
            if (_errorMsg != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _errorMsg!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
            if (_showCreateTicket) ...[
              if (_recentOrders.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Ainda não possui pedidos realizados para associar a uma disputa.',
                  ),
                )
              else ...[
                DropdownButtonFormField<String>(
                  value: _selectedOrderId,
                  decoration: const InputDecoration(
                    labelText: 'Selecione o Pedido *',
                    prefixIcon: Icon(Icons.receipt_long_outlined),
                  ),
                  items: _recentOrders.map((o) {
                    final id = (o['id'] ?? '').toString();
                    final shortId =
                        id.length >= 8 ? id.substring(0, 8).toUpperCase() : id;
                    final loja =
                        (o['loja_nome'] ?? 'Restaurante').toString();
                    return DropdownMenuItem<String>(
                      value: id,
                      child: Text('$loja (#$shortId)'),
                    );
                  }).toList(),
                  onChanged: (v) => setState(() => _selectedOrderId = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _selectedIncidentType,
                  decoration: const InputDecoration(
                    labelText: 'Tipo de Incidente',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'DISPUTA_COMERCIAL',
                      child: Text('Item em Falta / Pedido Incorreto'),
                    ),
                    DropdownMenuItem(
                      value: 'ATRASO_CRITICO',
                      child: Text('Atraso Crítico na Entrega'),
                    ),
                    DropdownMenuItem(
                      value: 'ACIDENTE_VIACAO',
                      child: Text('Incidente na Entrega / Estafeta'),
                    ),
                  ],
                  onChanged: (v) => setState(
                      () => _selectedIncidentType = v ?? _selectedIncidentType),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _motivoController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Descrição Detalhada do Problema *',
                    hintText:
                        'Explique o que aconteceu com o seu pedido (mín. 10 caracteres)...',
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _isSubmitting ? null : _submitTicket,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(_isSubmitting
                      ? 'A enviar reclamação...'
                      : 'Submeter Ticket de Suporte'),
                ),
              ],
            ] else ...[
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                if (_tickets.isNotEmpty) ...[
                  Text(
                    'Os Meus Tickets de Suporte (${_tickets.length})',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._tickets.map((t) {
                    final estado = (t['estado'] ?? 'ABERTO').toString();
                    final motivo = (t['motivo'] ?? '').toString();
                    final compensacao =
                        (t['compensacao_valor_formatado_kz'] ?? '').toString();
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: colorScheme.outlineVariant),
                      ),
                      child: ListTile(
                        leading: Icon(
                          Icons.confirmation_number_outlined,
                          color: colorScheme.primary,
                        ),
                        title: Text(
                          motivo,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          'Estado: $estado${compensacao.isNotEmpty ? ' • Compensação: $compensacao' : ''}',
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
                Text(
                  'Perguntas Frequentes (FAQ)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const ExpansionTile(
                  leading: Icon(Icons.pin_outlined),
                  title: Text('O que é o PIN de Entrega de 4 dígitos?'),
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        'Para sua segurança, cada pedido gera um código PIN único de 4 dígitos. '
                        'Informe este PIN ao estafeta apenas no momento em que receber o pedido em mãos.',
                      ),
                    ),
                  ],
                ),
                const ExpansionTile(
                  leading: Icon(Icons.timer_outlined),
                  title: Text('Como funciona a validade de 15 minutos no Checkout?'),
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        'Pela regra RN-043, a cotação de taxas e preços fica congelada durante 15 minutos. '
                        'Se o tempo expirar, basta tocar em Atualizar para recalcular.',
                      ),
                    ),
                  ],
                ),
                const ExpansionTile(
                  leading: Icon(Icons.cancel_outlined),
                  title: Text('Posso cancelar um pedido após confirmar?'),
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        'Sim! Enquanto o pedido ainda não tiver entrado em preparação na cozinha da loja, '
                        'pode cancelá-lo diretamente no separador "Pedidos". Após iniciar o preparo, '
                        'utilize o botão "Reportar Problema" acima.',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    ),
  );
}
}

