import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/screens/role_selection_onboarding_screen.dart';
import '../bloc/app_initialization_bloc.dart';

/// Ecrã de Splash Inicial Absoluto (`SplashScreen`).
/// Responsável por apresentar a identidade visual da plataforma,
/// coordenar o handshake com os servidores de produção no Render
/// e proteger a transição de telas contra falhas de rede assíncronas.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Dispara a inicialização e handshake do ecossistema
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppInitializationBloc>().add(const InitializeAppConfig());
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primaryColor = Color(0xFFEA1D2C);

    return Scaffold(
      backgroundColor: Colors.white,
      body: BlocConsumer<AppInitializationBloc, AppInitializationState>(
        listener: (context, state) {
          if (state is AppInitializationSuccess) {
            // Transição segura e fluida para o ecrã de onboarding após handshake confirmado
            Navigator.of(context).pushReplacement(
              PageRouteBuilder(
                pageBuilder: (_, animation, secondaryAnimation) =>
                    const RoleSelectionOnboardingScreen(),
                transitionsBuilder: (_, animation, __, child) =>
                    FadeTransition(opacity: animation, child: child),
                transitionDuration: const Duration(milliseconds: 400),
              ),
            );
          }
        },
        builder: (context, state) {
          final isFailure = state is AppInitializationFailure;
          final errorMessage = isFailure ? state.errorMessage : null;
          final statusMessage = state is AppInitializationInProgress
              ? state.statusMessage
              : 'A carregar aplicação...';

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(),

                  // Logótipo e Ícone Central com Pulso Suave
                  ScaleTransition(
                    scale: isFailure
                        ? const AlwaysStoppedAnimation(1.0)
                        : _scaleAnimation,
                    child: Container(
                      width: 104.0,
                      height: 104.0,
                      decoration: BoxDecoration(
                        color: isFailure
                            ? const Color(0xFFFEE2E2)
                            : primaryColor.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isFailure
                            ? Icons.cloud_off_rounded
                            : Icons.delivery_dining_rounded,
                        size: 54.0,
                        color: isFailure ? const Color(0xFFDC2626) : primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 28.0),

                  // Título da Plataforma
                  const Text(
                    'DELIVERY PRO',
                    style: TextStyle(
                      fontSize: 26.0,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 6.0),

                  // Subtítulo
                  Text(
                    'Plataforma de Entregas de Angola',
                    style: TextStyle(
                      fontSize: 14.0,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey.shade600,
                    ),
                  ),

                  const Spacer(),

                  // Área de Progresso ou Erro
                  if (!isFailure) ...[
                    const SizedBox(
                      width: 38.0,
                      height: 38.0,
                      child: CircularProgressIndicator(
                        strokeWidth: 3.2,
                        valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                      ),
                    ),
                    const SizedBox(height: 20.0),
                    Text(
                      statusMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else ...[
                    // Caixa de Erro Amigável
                    Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(16.0),
                        border: Border.all(color: const Color(0xFFFCA5A5)),
                      ),
                      child: Column(
                        children: [
                          const Text(
                            'Falha de Comunicação',
                            style: TextStyle(
                              fontSize: 16.0,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF991B1B),
                            ),
                          ),
                          const SizedBox(height: 6.0),
                          Text(
                            errorMessage ??
                                'Erro ao ligar ao servidor. Verifique a sua internet.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: Color(0xFF7F1D1D),
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24.0),

                    // Botão Intuitivo "Tentar Novamente"
                    SizedBox(
                      width: double.infinity,
                      height: 50.0,
                      child: FilledButton.icon(
                        onPressed: () {
                          context
                              .read<AppInitializationBloc>()
                              .add(const RetryAppConfig());
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14.0),
                          ),
                          elevation: 0,
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 20.0),
                        label: const Text(
                          'Tentar Novamente',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16.0),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

