import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/auth_bloc.dart';
import '../../auth/auth_event.dart';
import '../../auth/auth_state.dart';
import '../../auth/screens/role_selection_onboarding_screen.dart';
import '../bloc/partner_bloc.dart';
import '../models/partner_models.dart';

/// Ecrã de Perfil da Loja, Métricas Financeiras e Definições do Parceiro (`PartnerStoreProfileScreen`).
///
/// Arquitetura UX/UI:
/// - Cartão Hero com gradiente nobre de parceiro comercial e selo de verificação;
/// - Resumo financeiro com métricas operacionais em tempo real (Vendas em Kz, Pedidos, Ticket Médio);
/// - Painel de definições operacionais (Tempo de Preparo, Raio PostGIS, Repasses);
/// - Diálogo de desconexão e logout seguro com confirmação.
class PartnerStoreProfileScreen extends StatelessWidget {
  const PartnerStoreProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Perfil & Finanças da Loja',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: Color(0xFF0F172A),
          ),
        ),
      ),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, authState) {
          String merchantName = 'Restaurante Parceiro';
          String merchantEmail = '';

          if (authState is Authenticated) {
            merchantName = authState.user.nome.isNotEmpty
                ? authState.user.nome
                : 'Restaurante Parceiro';
            merchantEmail = authState.user.email;
          }

          return BlocBuilder<PartnerBloc, PartnerState>(
            builder: (context, partnerState) {
              final store = partnerState.storeStatus;
              final isAberta = store?.status == StoreOperationalStatus.disponivel;

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                children: [
                  // 1. Cartão Hero da Loja com Gradiente Azul Nobre
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFF1E88E5), // Azul Parceiro Vibrante
                          Color(0xFF1565C0), // Azul Cobalto Profundo
                          Color(0xFF0D47A1), // Azul Meia-Noite
                        ],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF1E88E5).withOpacity(0.3),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        // Avatar com Borda e Ícone
                        Stack(
                          children: [
                            Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                                border: Border.all(color: Colors.white.withOpacity(0.4), width: 3),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.15),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.storefront_rounded,
                                size: 42,
                                color: Color(0xFF1E88E5),
                              ),
                            ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.verified_rounded,
                                  size: 20,
                                  color: isAberta ? const Color(0xFF16A34A) : const Color(0xFFEA580C),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // Nome e Email do Parceiro
                        Text(
                          store?.nome ?? merchantName,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (merchantEmail.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            merchantEmail,
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withOpacity(0.85),
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),

                        // Chip de Estado Operacional em Tempo Real
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white.withOpacity(0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: isAberta ? const Color(0xFF4ADE80) : const Color(0xFFFDBA74),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                isAberta ? 'Loja Aberta e a Receber Pedidos' : 'Loja Pausada Temporariamente',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 2. Resumo Financeiro & Desempenho Hoje
                  _buildSectionHeader('Desempenho Comercial & Vendas'),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricCard(
                          title: 'Vendas Hoje',
                          value: '125.000 Kz',
                          subtitle: 'Faturação bruta',
                          icon: Icons.payments_rounded,
                          accentColor: const Color(0xFF16A34A),
                          bgColor: const Color(0xFFDCFCE7),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMetricCard(
                          title: 'Pedidos Hoje',
                          value: '18 concluídos',
                          subtitle: '100% no prazo',
                          icon: Icons.receipt_long_rounded,
                          accentColor: const Color(0xFF1E88E5),
                          bgColor: const Color(0xFFEFF6FF),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricCard(
                          title: 'Ticket Médio',
                          value: '6.944 Kz',
                          subtitle: 'Por pedido',
                          icon: Icons.trending_up_rounded,
                          accentColor: const Color(0xFF9333EA),
                          bgColor: const Color(0xFFF3E8FF),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMetricCard(
                          title: 'Comissão',
                          value: '15%',
                          subtitle: 'Taxa da plataforma',
                          icon: Icons.percent_rounded,
                          accentColor: const Color(0xFFEA580C),
                          bgColor: const Color(0xFFFFF7ED),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // 3. Definições do Estabelecimento
                  _buildSectionHeader('Definições do Estabelecimento'),
                  const SizedBox(height: 10),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        _buildSettingsRow(
                          icon: Icons.timer_outlined,
                          iconColor: const Color(0xFF1E88E5),
                          title: 'Tempo Médio de Preparo',
                          subtitle: '30 - 45 minutos (Configurável)',
                          onTap: () => _showComingSoonSnackBar(context, 'Ajuste de Tempo Base'),
                        ),
                        const Divider(height: 1, indent: 56, color: Color(0xFFF1F5F9)),
                        _buildSettingsRow(
                          icon: Icons.delivery_dining_outlined,
                          iconColor: const Color(0xFF16A34A),
                          title: 'Raio de Cobertura de Entregas',
                          subtitle: 'PostGIS delimitado a 8.0 km da loja',
                          onTap: () => _showComingSoonSnackBar(context, 'Raio de Entrega'),
                        ),
                        const Divider(height: 1, indent: 56, color: Color(0xFFF1F5F9)),
                        _buildSettingsRow(
                          icon: Icons.account_balance_rounded,
                          iconColor: const Color(0xFF9333EA),
                          title: 'Dados Bancários & Repasses',
                          subtitle: 'Conta e IBAN para liquidação automática',
                          onTap: () => _showComingSoonSnackBar(context, 'Dados Bancários'),
                        ),
                        const Divider(height: 1, indent: 56, color: Color(0xFFF1F5F9)),
                        _buildSettingsRow(
                          icon: Icons.support_agent_rounded,
                          iconColor: const Color(0xFFEA580C),
                          title: 'Apoio ao Lojista & Suporte',
                          subtitle: 'Canal prioritário para resolução de incidentes',
                          onTap: () => _showComingSoonSnackBar(context, 'Suporte ao Parceiro'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 4. Botão de Logout Seguro
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEE2E2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.logout_rounded,
                          color: Color(0xFFDC2626),
                          size: 20,
                        ),
                      ),
                      title: const Text(
                        'Terminar Sessão do Portal',
                        style: TextStyle(
                          color: Color(0xFFDC2626),
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      subtitle: const Text(
                        'Desconectar a conta com segurança',
                        style: TextStyle(fontSize: 12.5, color: Color(0xFF991B1B)),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Color(0xFFDC2626)),
                      onTap: () => _showLogoutConfirmDialog(context),
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: Color(0xFF334155),
        letterSpacing: 0.3,
      ),
    );
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required Color bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: accentColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF64748B),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: iconColor),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Color(0xFF0F172A),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFF64748B),
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        size: 20,
        color: Color(0xFF94A3B8),
      ),
      onTap: onTap,
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('Terminar Sessão?', style: TextStyle(fontWeight: FontWeight.bold)),
          content: const Text(
            'Tem a certeza que pretende terminar a sessão no Portal do Parceiro?',
            style: TextStyle(fontSize: 13.5, color: Color(0xFF475569)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
