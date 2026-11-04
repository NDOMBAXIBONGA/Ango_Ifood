import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/auth_bloc.dart';
import '../../auth/auth_event.dart';
import '../../auth/auth_state.dart';
import '../../splash/screens/splash_screen.dart';

/// Ecrã de Perfil, Viatura e Documentos do Estafeta (`CourierProfileScreen`).
class CourierProfileScreen extends StatelessWidget {
  const CourierProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF121417),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Perfil do Estafeta',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, authState) {
          String driverName = 'Estafeta Condutor';
          String driverEmail = '';
          String driverPhone = '';

          if (authState is Authenticated) {
            driverName = authState.user.nome.isNotEmpty
                ? authState.user.nome
                : 'Estafeta Condutor';
            driverEmail = authState.user.email ?? '';
            driverPhone = authState.user.telemovel ?? '';
          }

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            children: [
              // Cabeçalho com Avatar e Score
              Center(
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 46,
                      backgroundColor: const Color(0xFF00E676).withOpacity(0.18),
                      child: const Icon(
                        Icons.two_wheeler_rounded,
                        size: 48,
                        color: Color(0xFF00E676),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      driverName,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (driverEmail.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        driverEmail,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                    if (driverPhone.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        driverPhone,
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E676).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF00E676).withOpacity(0.5)),
                      ),
                      child: const Text(
                        'Condutor Aprovado • 4.9 ★',
                        style: TextStyle(
                          color: Color(0xFF00E676),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // Seção da Viatura
              _buildSectionHeader('Dados da Viatura & Transporte'),
              _buildCourierInfoTile(
                icon: Icons.electric_moped_rounded,
                title: 'Tipo de Veículo',
                subtitle: 'Mota / Motociclo (Haojue 125)',
              ),
              _buildCourierInfoTile(
                icon: Icons.pin_outlined,
                title: 'Matrícula da Viatura',
                subtitle: 'LD-44-99-AF',
              ),
              _buildCourierInfoTile(
                icon: Icons.badge_outlined,
                title: 'Carta de Condução',
                subtitle: 'N.º 994821802LA04 (Válida)',
              ),

              const SizedBox(height: 24),

              // Seção de Preferências Operacionais
              _buildSectionHeader('Preferências de Navegação'),
              _buildCourierInfoTile(
                icon: Icons.map_outlined,
                title: 'Aplicação de GPS Padrão',
                subtitle: 'Google Maps / Waze integrado',
              ),
              _buildCourierInfoTile(
                icon: Icons.support_agent_rounded,
                title: 'Central de Apoio ao Estafeta',
                subtitle: 'Linha prioritária de incidentes em rota',
              ),

              const SizedBox(height: 24),

              // Botão de Logout Seguro
              Card(
                elevation: 0,
                color: Colors.red.shade900.withOpacity(0.25),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.red.shade400.withOpacity(0.3)),
                ),
                child: ListTile(
                  leading: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                  title: const Text(
                    'Terminar Sessão',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: const Text(
                    'Ficar offline e desconectar com segurança',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
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

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFF00E676),
          fontWeight: FontWeight.bold,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _buildCourierInfoTile({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Card(
      elevation: 0,
      color: const Color(0xFF1E2228),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Colors.white12),
      ),
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFF00E676)),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
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
            'Ao terminar a sessão, o seu radar ficará OFFLINE e não receberá pedidos.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
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

