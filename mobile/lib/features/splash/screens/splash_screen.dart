import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../auth/screens/role_selection_onboarding_screen.dart';
import '../bloc/app_initialization_bloc.dart';

/// Ecrã de Splash Inicial Absoluto (`SplashScreen`).
/// Apresenta a identidade visual moderna e premium da plataforma Delivery Pro (Angola),
/// com animações fluidas, gradientes envolventes e feedback de ligação resiliente.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOutCubic),
    );

    _glowAnimation = Tween<double>(begin: 0.25, end: 0.45).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOutSine),
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
    // Configura os ícones da barra de estado em branco para contraste perfeito com o gradiente
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF7A040B),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    return Scaffold(
      body: BlocConsumer<AppInitializationBloc, AppInitializationState>(
        listener: (context, state) {
          if (state is AppInitializationSuccess) {
            // Transição suave para o ecrã de onboarding após handshake confirmado
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
              : 'A preparar a sua experiência...';

          return Container(
            width: double.infinity,
            height: double.infinity,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFEA1D2C), // Vermelho Oficial Vibrante
                  Color(0xFFD61322), // Vermelho Rubi Intermédio
                  Color(0xFF8F0B14), // Carmesim Profundo
                ],
                stops: [0.0, 0.45, 1.0],
              ),
            ),
            child: Stack(
              children: [
                // 1. Iluminação Ambiente Superior Direita (Efeito Brilho Quente)
                Positioned(
                  top: -80,
                  right: -80,
                  child: Container(
                    width: 280,
                    height: 280,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFFFF8A00).withOpacity(0.22),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // 2. Iluminação Ambiente Inferior Esquerda (Efeito Profundidade)
                Positioned(
                  bottom: -100,
                  left: -80,
                  child: Container(
                    width: 320,
                    height: 320,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Colors.black.withOpacity(0.35),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),

                // 3. Conteúdo Central e Responsivo
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 20.0),
                    child: Column(
                      children: [
                        const Spacer(flex: 3),

                        // Logótipo e Emblema Central em Camadas 3D com Pulso Suave
                        AnimatedBuilder(
                          animation: _pulseController,
                          builder: (context, child) {
                            return ScaleTransition(
                              scale: isFailure
                                  ? const AlwaysStoppedAnimation(1.0)
                                  : _scaleAnimation,
                              child: Container(
                                width: 114.0,
                                height: 114.0,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                  border: Border.all(
                                    color: Colors.white.withOpacity(0.35),
                                    width: 4.5,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.28),
                                      blurRadius: 36,
                                      offset: const Offset(0, 14),
                                    ),
                                    BoxShadow(
                                      color: Colors.white.withOpacity(_glowAnimation.value),
                                      blurRadius: 24,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Container(
                                    width: 88.0,
                                    height: 88.0,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Colors.white,
                                          Color(0xFFFFF1F2),
                                        ],
                                      ),
                                    ),
                                    child: Icon(
                                      isFailure
                                          ? Icons.wifi_off_rounded
                                          : Icons.delivery_dining_rounded,
                                      size: 54.0,
                                      color: isFailure
                                          ? const Color(0xFFDC2626)
                                          : const Color(0xFFEA1D2C),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 26.0),

                        // Nome Oficial da Plataforma
                        const Text(
                          'DELIVERY PRO',
                          style: TextStyle(
                            fontSize: 30.0,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.4,
                            color: Colors.white,
                            shadows: [
                              Shadow(
                                color: Colors.black38,
                                offset: Offset(0, 3),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10.0),

                        // Cápsula de Subtítulo com Bandeira e Acabamento Fosco
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 7.0),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.16),
                            borderRadius: BorderRadius.circular(24.0),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.28),
                              width: 1.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.12),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '🇦🇴',
                                style: TextStyle(fontSize: 14.0),
                              ),
                              SizedBox(width: 8.0),
                              Text(
                                'Plataforma de Entregas de Angola',
                                style: TextStyle(
                                  fontSize: 13.0,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16.0),

                        // Os 3 Pilares do Ecossistema (Comprar, Negócio, Entregar)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildPillarChip('Comprar', const Color(0xFF22C55E)),
                            _buildPillarDivider(),
                            _buildPillarChip('Vender', const Color(0xFF60A5FA)),
                            _buildPillarDivider(),
                            _buildPillarChip('Entregar', const Color(0xFFF97316)),
                          ],
                        ),

                        const Spacer(flex: 4),

                        // Área de Progresso Linear ou Caixa de Erro
                        if (!isFailure) ...[
                          // Barra de Progresso em Cápsula Sleek
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10.0),
                            child: SizedBox(
                              width: 170.0,
                              height: 4.5,
                              child: LinearProgressIndicator(
                                backgroundColor: Colors.white.withOpacity(0.22),
                                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14.0),

                          // Mensagem de Status Reativa
                          Text(
                            statusMessage,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: Colors.white.withOpacity(0.92),
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 16.0),

                          // Rodapé de Confiança e Versão
                          Text(
                            'Tecnologia 100% Angolana • v1.0.6',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Colors.white.withOpacity(0.60),
                              fontWeight: FontWeight.w500,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ] else ...[
                          // Card de Falha com Estilo Frosted Glass Moderno
                          Container(
                            padding: const EdgeInsets.all(20.0),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.18),
                              borderRadius: BorderRadius.circular(20.0),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.35),
                                width: 1.2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.2),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                const Text(
                                  'Falha de Ligação',
                                  style: TextStyle(
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 8.0),
                                Text(
                                  errorMessage ??
                                      'Não foi possível estabelecer ligação ao servidor. Verifique a sua ligação de rede.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13.0,
                                    color: Colors.white.withOpacity(0.9),
                                    height: 1.35,
                                  ),
                                ),
                                const SizedBox(height: 18.0),

                                // Botão de Tentar Novamente em Destaque Branco
                                SizedBox(
                                  width: double.infinity,
                                  height: 48.0,
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      context
                                          .read<AppInitializationBloc>()
                                          .add(const RetryAppConfig());
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor: const Color(0xFFEA1D2C),
                                      elevation: 2,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14.0),
                                      ),
                                    ),
                                    icon: const Icon(Icons.refresh_rounded, size: 20.0),
                                    label: const Text(
                                      'Tentar Novamente',
                                      style: TextStyle(
                                        fontSize: 15.0,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 12.0),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Constrói um indicador elegante para cada pilar do ecossistema
  static Widget _buildPillarChip(String label, Color dotColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6.0,
          height: 6.0,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: dotColor.withOpacity(0.6),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 5.0),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: Colors.white.withOpacity(0.85),
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }

  /// Divisor sutil entre os pilares
  static Widget _buildPillarDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10.0),
      child: Text(
        '•',
        style: TextStyle(
          fontSize: 12.0,
          color: Colors.white.withOpacity(0.4),
        ),
      ),
    );
  }
}
