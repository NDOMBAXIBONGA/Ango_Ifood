import 'package:flutter/material.dart';

import '../courier_flow_screens.dart';
import '../courier_pin_verification_sheet.dart';

/// Ecrã de Gestão Operacional de Corrida Ativa (`ActiveDeliveryFlowScreen`).
/// Acompanha o estafeta pelas 5 etapas essenciais:
/// 1. A caminho da loja (Navegação GPS);
/// 2. Chegada à loja parceira;
/// 3. Confirmação de recolha dos sacos (RN-093);
/// 4. A caminho do cliente;
/// 5. Validação presencial do PIN de 4 dígitos do cliente (RN-095).
class ActiveDeliveryFlowScreen extends StatefulWidget {
  final VoidCallback? onGoToRadar;

  const ActiveDeliveryFlowScreen({
    super.key,
    this.onGoToRadar,
  });

  @override
  State<ActiveDeliveryFlowScreen> createState() =>
      _ActiveDeliveryFlowScreenState();
}

enum DeliveryStep {
  aCaminhoLoja,
  naLoja,
  aCaminhoCliente,
  noCliente,
  concluido,
}

class _ActiveDeliveryFlowScreenState extends State<ActiveDeliveryFlowScreen> {
  DeliveryStep _currentStep = DeliveryStep.aCaminhoLoja;
  bool _hasActiveOrder = true;

  void _nextStep() {
    setState(() {
      switch (_currentStep) {
        case DeliveryStep.aCaminhoLoja:
          _currentStep = DeliveryStep.naLoja;
          break;
        case DeliveryStep.naLoja:
          _currentStep = DeliveryStep.aCaminhoCliente;
          break;
        case DeliveryStep.aCaminhoCliente:
          _currentStep = DeliveryStep.noCliente;
          _openPinVerification();
          break;
        case DeliveryStep.noCliente:
          _openPinVerification();
          break;
        case DeliveryStep.concluido:
          _hasActiveOrder = false;
          break;
      }
    });
  }

  void _openPinVerification() {
    CourierPinVerificationSheet.show(
      context,
      pedidoId: 'PED-74892-AO',
      nomeCliente: 'Cliente Delivery Pro',
      moradaClienteTexto: 'Rua Rainha Ginga, Ingombota, Luanda',
      tempoToleranciaSegundos: 420,
      onSucessoEntrega: () {
        setState(() {
          _currentStep = DeliveryStep.concluido;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = true;

    return Scaffold(
      backgroundColor: const Color(0xFF121417),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Corrida Ativa',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: !_hasActiveOrder
          ? _buildNoActiveOrderState(context)
          : _buildActiveDeliveryContent(context),
    );
  }

  Widget _buildNoActiveOrderState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF00E676).withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check_circle_outline_rounded,
                size: 72,
                color: Color(0xFF00E676),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Sem entregas em curso',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Fique Online no Radar para receber novas atribuições de pedidos nos restaurantes da sua zona.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: widget.onGoToRadar,
              icon: const Icon(Icons.radar_rounded),
              label: const Text('Ir para o Radar'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveDeliveryContent(BuildContext context) {
    String stepTitle = '';
    String actionLabel = '';
    IconData actionIcon = Icons.arrow_forward_rounded;

    switch (_currentStep) {
      case DeliveryStep.aCaminhoLoja:
        stepTitle = '1. A Caminho do Restaurante';
        actionLabel = 'Cheguei ao Restaurante';
        actionIcon = Icons.storefront_rounded;
        break;
      case DeliveryStep.naLoja:
        stepTitle = '2. No Restaurante (Recolha)';
        actionLabel = 'Confirmar Recolha do Pedido';
        actionIcon = Icons.shopping_bag_rounded;
        break;
      case DeliveryStep.aCaminhoCliente:
        stepTitle = '3. A Caminho do Cliente';
        actionLabel = 'Cheguei ao Destino';
        actionIcon = Icons.location_on_rounded;
        break;
      case DeliveryStep.noCliente:
        stepTitle = '4. Validação de Entrega (PIN)';
        actionLabel = 'Validar PIN de 4 Dígitos';
        actionIcon = Icons.pin_rounded;
        break;
      case DeliveryStep.concluido:
        stepTitle = '5. Entrega Concluída com Sucesso!';
        actionLabel = 'Finalizar e Voltar ao Radar';
        actionIcon = Icons.check_rounded;
        break;
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Card de Status da Corrida
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2228),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF00E676).withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Pedido #PED-74892',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E676).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Ganho: 2.500 Kz',
                      style: TextStyle(
                        color: Color(0xFF00E676),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                stepTitle,
                style: const TextStyle(
                  color: Color(0xFF00E676),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              const Divider(color: Colors.white10),
              const SizedBox(height: 8),
              _buildLocationRow(
                icon: Icons.store_mall_directory_rounded,
                iconColor: Colors.amber,
                label: 'Recolha:',
                address: 'Restaurante O Pescador • Ilha de Luanda',
              ),
              const SizedBox(height: 12),
              _buildLocationRow(
                icon: Icons.location_on_rounded,
                iconColor: Colors.redAccent,
                label: 'Entrega:',
                address: 'Rua Rainha Ginga, Ingombota, Luanda',
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // Botão de Avanço de Etapa
        FilledButton.icon(
          onPressed: _nextStep,
          icon: Icon(actionIcon),
          label: Text(actionLabel),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF00E676),
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),

        const SizedBox(height: 14),

        // Botão de Contato / Navegação Externa
        OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.navigation_rounded),
          label: const Text('Abrir Rota no Google Maps'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white24),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String address,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              Text(
                address,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
