/// Ecrã 1: `RoleSelectionOnboardingScreen`
/// Ecrã inicial de onboarding limpo e profissional em Material Design 3.
/// Apresenta mensagem de boas-vindas da plataforma e 3 cards visuais grandes e responsivos
/// para seleção de papel: "Quero Comprar" (Cliente), "Tenho um Negócio" (Parceiro) ou "Quero Entregar" (Estafeta).
/// Altera dinamicamente a cor de destaque da aplicação conforme a escolha do utilizador.

import 'package:flutter/material.dart';

import '../theme/role_theme.dart';
import 'auth_screen.dart';

class RoleSelectionOnboardingScreen extends StatefulWidget {
  const RoleSelectionOnboardingScreen({super.key});

  @override
  State<RoleSelectionOnboardingScreen> createState() =>
      _RoleSelectionOnboardingScreenState();
}

class _RoleSelectionOnboardingScreenState
    extends State<RoleSelectionOnboardingScreen>
    with SingleTickerProviderStateMixin {
  late PlatformRole _selectedRole;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _selectedRole = RoleThemeManager.instance.currentRole;
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onRoleSelected(PlatformRole role) {
    setState(() {
      _selectedRole = role;
    });
    RoleThemeManager.instance.setRole(role);
  }

  void _proceedToPhoneInput() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthScreen(selectedRole: _selectedRole),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = _selectedRole.primaryColor;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16.0),
                // Logótipo e Header Superior
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10.0),
                      decoration: BoxDecoration(
                        color: activeColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(16.0),
                      ),
                      child: Icon(
                        Icons.delivery_dining_rounded,
                        size: 32.0,
                        color: activeColor,
                      ),
                    ),
                    const SizedBox(width: 12.0),
                    Text(
                      'DELIVERY PRO',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24.0),

                // Mensagem de Boas-Vindas
                Text(
                  'Bem-vindo à Plataforma',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8.0),
                Text(
                  'Selecione como deseja utilizar a aplicação hoje para personalizar a sua experiência:',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF64748B),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24.0),

                // 3 Cards Responsivos de Seleção de Papel
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _buildRoleCard(
                        role: PlatformRole.cliente,
                        theme: theme,
                      ),
                      const SizedBox(height: 14.0),
                      _buildRoleCard(
                        role: PlatformRole.parceiro,
                        theme: theme,
                      ),
                      const SizedBox(height: 14.0),
                      _buildRoleCard(
                        role: PlatformRole.estafeta,
                        theme: theme,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16.0),

                // Botão de Confirmação com a cor primária dinâmica
                FilledButton(
                  onPressed: _proceedToPhoneInput,
                  style: FilledButton.styleFrom(
                    backgroundColor: activeColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18.0),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16.0),
                    ),
                    elevation: 2,
                    shadowColor: activeColor.withOpacity(0.4),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Continuar como ${_selectedRole.title}',
                        style: const TextStyle(
                          fontSize: 16.0,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(width: 8.0),
                      const Icon(Icons.arrow_forward_rounded, size: 20.0),
                    ],
                  ),
                ),
                const SizedBox(height: 8.0),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoleCard({
    required PlatformRole role,
    required ThemeData theme,
  }) {
    final isSelected = _selectedRole == role;
    final roleColor = role.primaryColor;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: isSelected ? roleColor.withOpacity(0.06) : Colors.white,
        borderRadius: BorderRadius.circular(20.0),
        border: Border.all(
          color: isSelected ? roleColor : const Color(0xFFE2E8F0),
          width: isSelected ? 2.2 : 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: isSelected
                ? roleColor.withOpacity(0.14)
                : const Color(0xFF0F172A).withOpacity(0.04),
            blurRadius: isSelected ? 16.0 : 8.0,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onRoleSelected(role),
          borderRadius: BorderRadius.circular(20.0),
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Row(
              children: [
                // Ícone do Papel com fundo destacado
                Container(
                  width: 58.0,
                  height: 58.0,
                  decoration: BoxDecoration(
                    color: isSelected ? roleColor : roleColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16.0),
                  ),
                  child: Icon(
                    role == PlatformRole.cliente
                        ? Icons.shopping_bag_outlined
                        : role == PlatformRole.parceiro
                            ? Icons.storefront_outlined
                            : Icons.delivery_dining_outlined,
                    size: 30.0,
                    color: isSelected ? Colors.white : roleColor,
                  ),
                ),
                const SizedBox(width: 16.0),

                // Textos do Papel
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            role.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF0F172A),
                              fontSize: 17.0,
                            ),
                          ),
                          if (isSelected) ...[
                            const SizedBox(width: 8.0),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8.0,
                                vertical: 2.0,
                              ),
                              decoration: BoxDecoration(
                                color: roleColor.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(20.0),
                              ),
                              child: Text(
                                'Selecionado',
                                style: TextStyle(
                                  fontSize: 10.0,
                                  fontWeight: FontWeight.w700,
                                  color: roleColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4.0),
                      Text(
                        role.subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 12.0),

                // Rádio Visual personalizado
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 24.0,
                  height: 24.0,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? roleColor : const Color(0xFFCBD5E1),
                      width: 2.0,
                    ),
                    color: isSelected ? roleColor : Colors.transparent,
                  ),
                  child: isSelected
                      ? const Icon(
                          Icons.check,
                          size: 16.0,
                          color: Colors.white,
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

