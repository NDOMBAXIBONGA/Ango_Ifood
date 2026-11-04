import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/auth_bloc.dart';
import '../../auth/auth_event.dart';
import '../../auth/auth_state.dart';
import '../../splash/screens/splash_screen.dart';
import '../bloc/partner_bloc.dart';

/// Ecrã de Perfil da Loja, Métricas Financeiras e Definições do Parceiro (`PartnerStoreProfileScreen`).
class PartnerStoreProfileScreen extends StatelessWidget {
  const PartnerStoreProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Loja & Finanças'),
      ),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, authState) {
          String merchantName = 'Restaurante Parceiro';
          String merchantEmail = '';

          if (authState is Authenticated) {
            merchantName = authState.user.nome.isNotEmpty
                ? authState.user.nome
                : 'Restaurante Parceiro';
            merchantEmail = authState.user.email ?? '';
          }

          return BlocBuilder<PartnerBloc, PartnerState>(
            builder: (context, partnerState) {
              final store = partnerState is PartnerLoaded ? partnerState.store : null;

              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                children: [
                  // Cabeçalho da Loja
                  Center(
                    child: Column(
                      children: [
                        CircleAvatar(
                          radius: 46,
                          backgroundColor: colorScheme.primaryContainer,
                          child: Icon(
                            Icons.storefront_rounded,
                            size: 48,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          store?.nome ?? merchantName,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (merchantEmail.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            merchantEmail,
                            style: theme.textTheme.bodyMedium?.copyWith(
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
                            color: store?.isAberta == true
                                ? Colors.green.shade100
                                : Colors.amber.shade100,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            store?.isAberta == true ? 'Loja Aberta' : 'Loja Pausada / Fechada',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: store?.isAberta == true
                                  ? Colors.green.shade900
                                  : Colors.amber.shade900,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Resumo Financeiro de Vendas
                  _buildSectionHeader(context, 'Resumo Financeiro & Vendas'),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricCard(
                          context,
                          title: 'Vendas Hoje',
                          value: CurrencyFormatter.formatKwanza(12500000), // 125.000,00 Kz
                          icon: Icons.payments_rounded,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMetricCard(
                          context,
                          title: 'Pedidos Hoje',
                          value: '18 pedidos',
                          icon: Icons.receipt_long_rounded,
                          color: colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildSettingsTile(
                    context,
                    icon: Icons.account_balance_rounded,
                    title: 'Dados Bancários & Repasses',
                    subtitle: 'Conta e IBAN para liquidação automática semanal',
                    onTap: () => _showComingSoonSnackBar(context, 'Dados Bancários'),
                  ),
                  _buildSettingsTile(
                    context,
                    icon: Icons.percent_rounded,
                    title: 'Comissão da Plataforma',
                    subtitle: 'Taxa contratual de intermediação: 15%',
                    onTap: () => _showComingSoonSnackBar(context, 'Detalhes de Comissão'),
                  ),

                  const SizedBox(height: 24),

                  // Definições Operacionais da Loja
                  _buildSectionHeader(context, 'Definições do Estabelecimento'),
                  _buildSettingsTile(
                    context,
                    icon: Icons.timer_outlined,
                    title: 'Tempo Médio de Preparo',
                    subtitle: '${store?.tempoPreparoMinutos ?? 30} minutos',
                    onTap: () => _showComingSoonSnackBar(context, 'Ajuste de Tempo Base'),
                  ),
                  _buildSettingsTile(
                    context,
                    icon: Icons.delivery_dining_outlined,
                    title: 'Raio de Cobertura de Entregas',
                    subtitle: 'Definido pelas operações em 8.0 km',
                    onTap: () => _showComingSoonSnackBar(context, 'Raio de Entrega'),
                  ),
                  _buildSettingsTile(
                    context,
                    icon: Icons.help_outline_rounded,
                    title: 'Suporte & Ajuda ao Lojista',
                    subtitle: 'Linha direta para resolução de incidentes',
                    onTap: () => _showComingSoonSnackBar(context, 'Apoio ao Parceiro'),
                  ),

                  const SizedBox(height: 24),

                  // Botão de Logout Seguro
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
                        'Terminar Sessão do Portal',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colorScheme.error,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: const Text('Desconectar a conta do restaurante'),
                      onTap: () => _showLogoutConfirmDialog(context),
                    ),
                  ),

                  const SizedBox(height: 36),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  Widget _buildMetricCard(
    BuildContext context, {
    required String title,
    required String value,
    required IconData icon,
    required Color color,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
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
          content: Text('$feature estará disponível na próxima atualização do portal.'),
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
            'Tem a certeza que pretende terminar a sessão no Portal do Parceiro?',
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
                    builder: (_) => const SplashScreen(),
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
