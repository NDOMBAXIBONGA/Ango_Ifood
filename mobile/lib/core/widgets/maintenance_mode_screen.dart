import 'package:flutter/material.dart';
import '../services/app_config_service.dart';

/// Ecrã de Bloqueio Elegante e Amigável de Modo de Manutenção.
/// Ativado instantaneamente pelo Django Admin (Feature Flag: `modo_manutencao=True`).
/// Permite ao utilizador ler o comunicado oficial e clicar em "Verificar Novamente".
class MaintenanceModeScreen extends StatefulWidget {
  final String message;

  const MaintenanceModeScreen({
    super.key,
    required this.message,
  });

  @override
  State<MaintenanceModeScreen> createState() => _MaintenanceModeScreenState();
}

class _MaintenanceModeScreenState extends State<MaintenanceModeScreen> {
  bool _isChecking = false;

  Future<void> _checkStatus() async {
    setState(() => _isChecking = true);
    await AppConfigService.instance.syncWithRemote();
    if (mounted) {
      setState(() => _isChecking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = AppConfigService.instance.primaryColor;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.construction_rounded,
                      size: 52,
                      color: primaryColor,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Estamos em Manutenção',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.message.isNotEmpty
                        ? widget.message
                        : 'Estamos a efetuar melhorias na nossa infraestrutura para lhe proporcionar a melhor experiência de entregas. Voltamos já!',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isChecking ? null : _checkStatus,
                      icon: _isChecking
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.refresh_rounded),
                      label: Text(
                        _isChecking ? 'A verificar...' : 'Verificar Novamente',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryColor,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
