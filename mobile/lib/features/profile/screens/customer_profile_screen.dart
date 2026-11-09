import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/auth_bloc.dart';
import '../../auth/auth_event.dart';
import '../../auth/auth_state.dart';
import '../../auth/screens/role_selection_onboarding_screen.dart';

/// Ecrã de Perfil do Cliente (`CustomerProfileScreen`).
/// Disponibiliza gestão de dados cadastrais, atalhos de moradas,
/// definições de segurança e encerramento de sessão (Logout).
class CustomerProfileScreen extends StatelessWidget {
  const CustomerProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('O Meu Perfil'),
      ),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, authState) {
          String userName = 'Cliente';
          String userEmail = '';
          String userPhone = '';

          if (authState is Authenticated) {
            userName = authState.user.nome.isNotEmpty
                ? authState.user.nome
                : 'Cliente';
            userEmail = authState.user.email;
            userPhone = authState.user.telemovel;
          }

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            children: [
              // Cabeçalho de Perfil com Avatar
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
                    const SizedBox(height: 14),
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
                    ],
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Perfil de Cliente',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // Bloco: A Minha Conta
              _buildSectionHeader(context, 'A Minha Conta'),
              _buildSettingsTile(
                context,
                icon: Icons.location_on_outlined,
                title: 'Moradas de Entrega',
                subtitle: 'Gerir endereços guardados para entregas',
                onTap: () => _showComingSoonSnackBar(context, 'Gestão de Moradas'),
              ),
              _buildSettingsTile(
                context,
                icon: Icons.payment_outlined,
                title: 'Meios de Pagamento',
                subtitle: 'Multicaixa Express, Cartões e Pagamento na Entrega',
                onTap: () => _showComingSoonSnackBar(context, 'Meios de Pagamento'),
              ),
              _buildSettingsTile(
                context,
                icon: Icons.notifications_none_rounded,
                title: 'Notificações',
                subtitle: 'Alertas de estado dos pedidos e promoções',
                onTap: () => _showComingSoonSnackBar(context, 'Notificações'),
              ),

              const SizedBox(height: 24),

              // Bloco: Segurança e Ajuda
              _buildSectionHeader(context, 'Segurança & Suporte'),
              _buildSettingsTile(
                context,
                icon: Icons.lock_outline_rounded,
                title: 'Segurança & Palavra-passe',
                subtitle: 'Alterar senha e autenticação em dois fatores',
                onTap: () => _showComingSoonSnackBar(context, 'Segurança da Conta'),
              ),
              _buildSettingsTile(
                context,
                icon: Icons.help_outline_rounded,
                title: 'Ajuda & Apoio ao Cliente',
                subtitle: 'Contactar a linha de apoio e resolução de dúvidas',
                onTap: () => _showComingSoonSnackBar(context, 'Apoio ao Cliente'),
              ),

              const SizedBox(height: 24),

              // Botão de Terminar Sessão
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
                  subtitle: const Text('Desconectar a sua conta com segurança'),
                  onTap: () => _showLogoutConfirmDialog(context),
                ),
              ),

              const SizedBox(height: 36),
            ],
          );
        },
      ),
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

  void _showComingSoonSnackBar(BuildContext context, String feature) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('$feature estará disponível na próxima atualização.'),
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
            'Tem a certeza que pretende terminar a sessão no Ango Ifood?',
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
                    builder: (_) => const RoleSelectionOnboardingScreen(),
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

