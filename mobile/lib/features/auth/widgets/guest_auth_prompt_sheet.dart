import 'package:flutter/material.dart';

import '../screens/auth_screen.dart';
import '../theme/role_theme.dart';

/// Modal BottomSheet persuasivo e elegante exibido quando um visitante tenta finalizar compra.
/// Explica claramente a necessidade de criar conta/entrar para informar endereço e receber com PIN,
/// garantindo que o carrinho montado permaneça 100% intacto após a autenticação.
class GuestAuthPromptSheet extends StatelessWidget {
  final String? lojaNome;

  const GuestAuthPromptSheet({
    super.key,
    this.lojaNome,
  });

  /// Método estático utilitário para exibir o diálogo de forma padronizada.
  static Future<bool?> show(BuildContext context, {String? lojaNome}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GuestAuthPromptSheet(lojaNome: lojaNome),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28.0)),
      ),
      padding: EdgeInsets.fromLTRB(24.0, 16.0, 24.0, bottomPadding + 20.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pílula central indicadora de arrasto
          Center(
            child: Container(
              width: 44.0,
              height: 5.0,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10.0),
              ),
            ),
          ),
          const SizedBox(height: 20.0),

          // Ícone e Destaque Visual
          Row(
            children: [
              Container(
                width: 56.0,
                height: 56.0,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEA1D2C), Color(0xFFB91C1C)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18.0),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEA1D2C).withOpacity(0.3),
                      blurRadius: 12.0,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.shopping_bag_outlined,
                  color: Colors.white,
                  size: 28.0,
                ),
              ),
              const SizedBox(width: 16.0),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Falta apenas 1 passo!',
                      style: TextStyle(
                        fontSize: 20.0,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4.0),
                    Text(
                      lojaNome != null
                          ? 'Para concluir a encomenda no $lojaNome'
                          : 'Para concluir a sua encomenda deliciosa',
                      style: TextStyle(
                        fontSize: 13.0,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22.0),

          // Cartão Informativo de Benefícios da Conta
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(18.0),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              children: [
                _buildBenefitItem(
                  icon: Icons.location_on_outlined,
                  iconColor: const Color(0xFFEA1D2C),
                  title: 'O seu endereço de entrega',
                  description: 'Defina a rua e pontos de referência para entrega rápida em Angola.',
                ),
                const Divider(height: 20.0, color: Color(0xFFE2E8F0)),
                _buildBenefitItem(
                  icon: Icons.two_wheeler_rounded,
                  iconColor: const Color(0xFFF59E0B),
                  title: 'Rastreamento ao vivo no mapa',
                  description: 'Acompanhe a saída da cozinha e a rota do estafeta em tempo real.',
                ),
                const Divider(height: 20.0, color: Color(0xFFE2E8F0)),
                _buildBenefitItem(
                  icon: Icons.pin_outlined,
                  iconColor: const Color(0xFF10B981),
                  title: 'Código PIN de 4 dígitos na entrega',
                  description: 'Garantia total contra extravios (o estafeta só finaliza com o seu PIN).',
                ),
              ],
            ),
          ),
          const SizedBox(height: 16.0),

          // Aviso amigável de preservação do carrinho
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.check_circle_outline_rounded, size: 16.0, color: Colors.green.shade700),
              const SizedBox(width: 6.0),
              Text(
                'Os produtos do seu carrinho serão mantidos intactos!',
                style: TextStyle(
                  fontSize: 12.0,
                  fontWeight: FontWeight.w700,
                  color: Colors.green.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20.0),

          // Botão Principal: Entrar ou Criar Conta
          FilledButton(
            onPressed: () async {
              // Abre o ecrã de autenticação
              final authSuccess = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => const AuthScreen(
                    selectedRole: PlatformRole.cliente,
                  ),
                ),
              );

              if (context.mounted) {
                // Devolve para o ecrã de carrinho se a autenticação correu bem
                Navigator.of(context).pop(authSuccess == true);
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEA1D2C),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16.0),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16.0),
              ),
              elevation: 2,
              shadowColor: const Color(0xFFEA1D2C).withOpacity(0.4),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.phone_android_rounded, size: 20.0),
                SizedBox(width: 8.0),
                Text(
                  'Criar Conta ou Iniciar Sessão (+244)',
                  style: TextStyle(
                    fontSize: 15.0,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8.0),

          // Botão Secundário: Continuar a ver
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: Colors.grey.shade700,
              padding: const EdgeInsets.symmetric(vertical: 12.0),
            ),
            child: const Text(
              'Continuar a ver o cardápio',
              style: TextStyle(
                fontSize: 14.0,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBenefitItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8.0),
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12.0),
          ),
          child: Icon(icon, size: 20.0, color: iconColor),
        ),
        const SizedBox(width: 12.0),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14.0,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 2.0),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 12.0,
                  color: Color(0xFF64748B),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
