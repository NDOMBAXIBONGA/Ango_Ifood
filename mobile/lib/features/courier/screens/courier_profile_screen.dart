import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../auth/auth_bloc.dart';
import '../../auth/auth_event.dart';
import '../../auth/auth_state.dart';
import '../../auth/theme/role_theme.dart';
import '../../catalog/customer_main_navigation_shell.dart';
import '../courier_flow_screens.dart';

/// Ecrã de Perfil, Viatura, Dados Bancários e Documentos do Estafeta (`CourierProfileScreen`).
///
/// Integrado em tempo real com `CourierBloc` (`GET / PATCH /api/v1/logistics/couriers/me/`).
class CourierProfileScreen extends StatelessWidget {
  const CourierProfileScreen({super.key});

  String _formatVehicleType(CourierVehicleType type) {
    switch (type) {
      case CourierVehicleType.mota:
        return 'Mota / Motociclo';
      case CourierVehicleType.carro:
        return 'Automóvel Ligeiro';
      case CourierVehicleType.bicicleta:
        return 'Bicicleta';
    }
  }

  String _vehicleCode(CourierVehicleType type) {
    switch (type) {
      case CourierVehicleType.mota:
        return 'MOTA';
      case CourierVehicleType.carro:
        return 'CARRO';
      case CourierVehicleType.bicicleta:
        return 'BICICLETA';
    }
  }

  String _formatNavPreference(String code) {
    switch (code.toUpperCase()) {
      case 'GOOGLE_MAPS':
        return 'Google Maps (Navegação Externa)';
      case 'WAZE':
        return 'Waze GPS (Trânsito em Tempo Real)';
      default:
        return 'Mapa Integrado (OpenStreetMap + Google Maps)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFF121417),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Perfil & Viatura do Estafeta',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Atualizar Perfil',
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00E676)),
            onPressed: () {
              context.read<CourierBloc>().add(const LoadCourierDashboardEvent('current'));
            },
          ),
        ],
      ),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, authState) {
          String fallbackName = 'Estafeta Condutor';
          String fallbackEmail = '';
          String fallbackPhone = '';

          if (authState is Authenticated) {
            fallbackName = authState.user.nome.isNotEmpty
                ? authState.user.nome
                : 'Estafeta Condutor';
            fallbackEmail = authState.user.email;
            fallbackPhone = authState.user.telemovel;
          }

          return BlocBuilder<CourierBloc, CourierState>(
            builder: (context, courierState) {
              final profile = courierState.profile;
              final driverName = (profile != null && profile.nome.isNotEmpty)
                  ? profile.nome
                  : fallbackName;
              final driverEmail = (profile != null && profile.email.isNotEmpty)
                  ? profile.email
                  : fallbackEmail;
              final driverPhone = (profile != null && profile.telemovel.isNotEmpty)
                  ? profile.telemovel
                  : fallbackPhone;
              final score = profile?.scoreReputacao ?? 5.0;
              final isVerified = profile?.isApprovedByAdmin ?? true;
              final vehicleLabel = profile != null
                  ? '${_formatVehicleType(profile.vehicleType)} (${profile.marcaModeloVeiculo})'
                  : 'Mota / Motociclo (Haojue 125)';
              final plateLabel = profile?.matriculaVeiculo ?? 'LD-44-99-AF';
              final licenseLabel = profile?.cartaConducaoNumero ?? 'N.º 994821802LA04';
              final bancoLabel = profile?.bancoNome ?? 'Banco Angolano de Investimentos (BAI)';
              final ibanLabel = profile?.iban ?? 'AO06 0040 0000 1234 5678 9012 3';
              final nifLabel = (profile != null && profile.nif.isNotEmpty)
                  ? profile.nif
                  : 'Não definido (Toque para configurar)';
              final navPrefLabel = _formatNavPreference(profile?.navegadorPadrao ?? 'INTERNO');

              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                children: [
                  // Cabeçalho com Avatar, Dados Pessoais e Score
                  Center(
                    child: Column(
                      children: [
                        Stack(
                          alignment: Alignment.bottomRight,
                          children: [
                            CircleAvatar(
                              radius: 46,
                              backgroundColor: const Color(0xFF00E676).withOpacity(0.18),
                              child: Icon(
                                profile?.vehicleType == CourierVehicleType.carro
                                    ? Icons.directions_car_filled_rounded
                                    : profile?.vehicleType == CourierVehicleType.bicicleta
                                        ? Icons.pedal_bike_rounded
                                        : Icons.two_wheeler_rounded,
                                size: 48,
                                color: const Color(0xFF00E676),
                              ),
                            ),
                            InkWell(
                              onTap: () => _showEditPersonalDataModal(
                                context,
                                currentName: driverName,
                                currentNif: profile?.nif ?? '',
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(
                                  color: Color(0xFF00E676),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.edit_rounded,
                                  size: 16,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                          ],
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
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E676).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFF00E676).withOpacity(0.5),
                            ),
                          ),
                          child: Text(
                            '${isVerified ? "Condutor Aprovado" : "Em Validação"} • ${score.toStringAsFixed(1)} ★',
                            style: const TextStyle(
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

                  // Secção 1: Dados da Viatura & Documentação
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionHeader('Dados da Viatura & Documentos'),
                      TextButton.icon(
                        onPressed: () => _showEditVehicleModal(context, profile),
                        icon: const Icon(Icons.edit_outlined, size: 15, color: Color(0xFF00E676)),
                        label: const Text(
                          'Editar Viatura',
                          style: TextStyle(color: Color(0xFF00E676), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  _buildCourierInfoTile(
                    icon: Icons.electric_moped_rounded,
                    title: 'Tipo & Modelo do Veículo',
                    subtitle: vehicleLabel,
                    onTap: () => _showEditVehicleModal(context, profile),
                  ),
                  _buildCourierInfoTile(
                    icon: Icons.pin_outlined,
                    title: 'Matrícula da Viatura',
                    subtitle: plateLabel,
                    onTap: () => _showEditVehicleModal(context, profile),
                  ),
                  _buildCourierInfoTile(
                    icon: Icons.badge_outlined,
                    title: 'Carta de Condução / Licença',
                    subtitle: '$licenseLabel (${isVerified ? "Validada" : "Em Análise"})',
                    onTap: () => _showEditVehicleModal(context, profile),
                  ),

                  const SizedBox(height: 24),

                  // Secção 2: Dados Bancários & Fiscais (Repasses RN-146)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionHeader('Dados Bancários & Fiscais (Repasses)'),
                      TextButton.icon(
                        onPressed: () => _showEditBankModal(context, profile),
                        icon: const Icon(Icons.account_balance_outlined, size: 15, color: Color(0xFF00E676)),
                        label: const Text(
                          'Editar Conta',
                          style: TextStyle(color: Color(0xFF00E676), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  _buildCourierInfoTile(
                    icon: Icons.account_balance_rounded,
                    title: 'Instituição Bancária',
                    subtitle: bancoLabel,
                    onTap: () => _showEditBankModal(context, profile),
                  ),
                  _buildCourierInfoTile(
                    icon: Icons.credit_card_rounded,
                    title: 'IBAN para Transferência / Levantamento',
                    subtitle: ibanLabel,
                    onTap: () => _showEditBankModal(context, profile),
                  ),
                  _buildCourierInfoTile(
                    icon: Icons.receipt_long_rounded,
                    title: 'NIF (Número de Identificação Fiscal)',
                    subtitle: nifLabel,
                    onTap: () => _showEditBankModal(context, profile),
                  ),

                  const SizedBox(height: 24),

                  // Secção 3: Preferências Operacionais & Suporte
                  _buildSectionHeader('Preferências de Navegação & Apoio'),
                  _buildCourierInfoTile(
                    icon: Icons.map_outlined,
                    title: 'Aplicação de GPS Padrão',
                    subtitle: navPrefLabel,
                    onTap: () => _showNavPreferenceSheet(
                      context,
                      currentNav: profile?.navegadorPadrao ?? 'INTERNO',
                    ),
                  ),
                  _buildCourierInfoTile(
                    icon: Icons.support_agent_rounded,
                    title: 'Central de Apoio ao Estafeta (24/7)',
                    subtitle: 'Linha prioritária de incidentes e assistência em rota',
                    onTap: () => _showSupportDialog(context),
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
    VoidCallback? onTap,
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
        onTap: onTap,
        leading: Icon(icon, color: const Color(0xFF00E676)),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        trailing: onTap != null
            ? const Icon(Icons.chevron_right_rounded, color: Colors.white38)
            : null,
      ),
    );
  }

  void _showEditPersonalDataModal(
    BuildContext context, {
    required String currentName,
    required String currentNif,
  }) {
    final nameCtrl = TextEditingController(text: currentName);
    final nifCtrl = TextEditingController(text: currentNif);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E2228),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 24,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Editar Dados Pessoais',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _buildDarkTextField(
                controller: nameCtrl,
                label: 'Nome Completo do Estafeta',
                icon: Icons.person_outline_rounded,
              ),
              const SizedBox(height: 12),
              _buildDarkTextField(
                controller: nifCtrl,
                label: 'NIF (Número de Identificação Fiscal)',
                icon: Icons.badge_outlined,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    context.read<CourierBloc>().add(
                          UpdateCourierProfileEvent({
                            'nome': nameCtrl.text.trim(),
                            'nif': nifCtrl.text.trim(),
                          }),
                        );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Dados pessoais atualizados com sucesso!'),
                        backgroundColor: Color(0xFF00C853),
                      ),
                    );
                  },
                  icon: const Icon(Icons.check_rounded),
                  label: const Text(
                    'Guardar Alterações',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showEditVehicleModal(BuildContext context, CourierProfileModel? profile) {
    String selectedType = _vehicleCode(profile?.vehicleType ?? CourierVehicleType.mota);
    final modelCtrl = TextEditingController(
      text: profile?.marcaModeloVeiculo ?? 'Mota Haojue 125',
    );
    final plateCtrl = TextEditingController(
      text: profile?.matriculaVeiculo ?? 'LD-44-99-AF',
    );
    final licenseCtrl = TextEditingController(
      text: profile?.cartaConducaoNumero ?? 'N.º 994821802LA04',
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E2228),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 24,
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Dados da Viatura & Carta de Condução',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Tipo de Veículo',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildVehicleChip(
                        label: 'Mota',
                        code: 'MOTA',
                        selectedCode: selectedType,
                        icon: Icons.two_wheeler_rounded,
                        onSelected: (v) => setModalState(() => selectedType = v),
                      ),
                      const SizedBox(width: 8),
                      _buildVehicleChip(
                        label: 'Carro',
                        code: 'CARRO',
                        selectedCode: selectedType,
                        icon: Icons.directions_car_rounded,
                        onSelected: (v) => setModalState(() => selectedType = v),
                      ),
                      const SizedBox(width: 8),
                      _buildVehicleChip(
                        label: 'Bicicleta',
                        code: 'BICICLETA',
                        selectedCode: selectedType,
                        icon: Icons.pedal_bike_rounded,
                        onSelected: (v) => setModalState(() => selectedType = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildDarkTextField(
                    controller: modelCtrl,
                    label: 'Marca e Modelo (Ex: Haojue 125 / Suzuki Alto)',
                    icon: Icons.electric_moped_rounded,
                  ),
                  const SizedBox(height: 12),
                  _buildDarkTextField(
                    controller: plateCtrl,
                    label: 'Matrícula da Viatura (Ex: LD-44-99-AF)',
                    icon: Icons.pin_outlined,
                  ),
                  const SizedBox(height: 12),
                  _buildDarkTextField(
                    controller: licenseCtrl,
                    label: 'N.º da Carta de Condução',
                    icon: Icons.badge_outlined,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF00E676),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () {
                        Navigator.of(sheetCtx).pop();
                        context.read<CourierBloc>().add(
                              UpdateCourierProfileEvent({
                                'tipo_veiculo': selectedType,
                                'marca_modelo_veiculo': modelCtrl.text.trim(),
                                'matricula_veiculo': plateCtrl.text.trim().toUpperCase(),
                                'carta_conducao': licenseCtrl.text.trim(),
                              }),
                            );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Dados da viatura atualizados com sucesso!'),
                            backgroundColor: Color(0xFF00C853),
                          ),
                        );
                      },
                      icon: const Icon(Icons.save_rounded),
                      label: const Text(
                        'Guardar Viatura & Documentos',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showEditBankModal(BuildContext context, CourierProfileModel? profile) {
    final bancoCtrl = TextEditingController(
      text: profile?.bancoNome ?? 'Banco Angolano de Investimentos (BAI)',
    );
    final ibanCtrl = TextEditingController(
      text: profile?.iban ?? 'AO06 0040 0000 1234 5678 9012 3',
    );
    final contaCtrl = TextEditingController(
      text: profile?.numeroConta ?? '',
    );
    final nifCtrl = TextEditingController(
      text: profile?.nif ?? '',
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E2228),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 24,
            bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Conta Bancária para Repasses (RN-146)',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                'Configure o banco e IBAN onde receberá os seus levantamentos antecipados e repasses semanais.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 16),
              _buildDarkTextField(
                controller: bancoCtrl,
                label: 'Nome do Banco (Ex: BAI, BFA, BIC, Atlântico)',
                icon: Icons.account_balance_rounded,
              ),
              const SizedBox(height: 12),
              _buildDarkTextField(
                controller: ibanCtrl,
                label: 'IBAN (Ex: AO06 0040 ...)',
                icon: Icons.credit_card_rounded,
              ),
              const SizedBox(height: 12),
              _buildDarkTextField(
                controller: contaCtrl,
                label: 'Número de Conta / Multicaixa Express',
                icon: Icons.numbers_rounded,
              ),
              const SizedBox(height: 12),
              _buildDarkTextField(
                controller: nifCtrl,
                label: 'NIF do Titular da Conta',
                icon: Icons.receipt_long_rounded,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () {
                    Navigator.of(sheetCtx).pop();
                    context.read<CourierBloc>().add(
                          UpdateCourierProfileEvent({
                            'banco_nome': bancoCtrl.text.trim(),
                            'iban': ibanCtrl.text.trim(),
                            'numero_conta': contaCtrl.text.trim(),
                            'nif': nifCtrl.text.trim(),
                          }),
                        );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Dados bancários guardados com segurança!'),
                        backgroundColor: Color(0xFF00C853),
                      ),
                    );
                  },
                  icon: const Icon(Icons.verified_user_rounded),
                  label: const Text(
                    'Guardar Dados Bancários',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showNavPreferenceSheet(BuildContext context, {required String currentNav}) {
    final options = [
      ('INTERNO', 'Mapa Integrado + Google Maps', Icons.map_rounded),
      ('GOOGLE_MAPS', 'Google Maps Externo', Icons.navigation_rounded),
      ('WAZE', 'Waze GPS', Icons.traffic_rounded),
    ];

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E2228),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Escolher Aplicação de GPS Padrão',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              for (final opt in options)
                ListTile(
                  leading: Icon(opt.$3, color: const Color(0xFF00E676)),
                  title: Text(opt.$2, style: const TextStyle(color: Colors.white)),
                  trailing: currentNav.toUpperCase() == opt.$1
                      ? const Icon(Icons.check_circle_rounded, color: Color(0xFF00E676))
                      : null,
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    context.read<CourierBloc>().add(
                          UpdateCourierProfileEvent({'navegador_padrao': opt.$1}),
                        );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Navegador padrão alterado para ${opt.$2}'),
                        backgroundColor: const Color(0xFF00C853),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  void _showSupportDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E2228),
          title: const Row(
            children: [
              Icon(Icons.support_agent_rounded, color: Color(0xFF00E676)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Central de Apoio ao Estafeta',
                  style: TextStyle(color: Colors.white, fontSize: 17),
                ),
              ),
            ],
          ),
          content: const Text(
            'Precisa de assistência imediata em rota, apoio com validação documental ou esclarecimento sobre repasses?\n\nLinha Direta Operacional: +244 923 000 000',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Fechar'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                Navigator.of(dialogCtx).pop();
                final uri = Uri.parse('tel:+244923000000');
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri);
                }
              },
              icon: const Icon(Icons.phone_in_talk_rounded, size: 18),
              label: const Text('Ligar para Central'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildVehicleChip({
    required String label,
    required String code,
    required String selectedCode,
    required IconData icon,
    required ValueChanged<String> onSelected,
  }) {
    final isSelected = selectedCode == code;
    return Expanded(
      child: InkWell(
        onTap: () => onSelected(code),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF00E676).withOpacity(0.2)
                : const Color(0xFF121417),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? const Color(0xFF00E676) : Colors.white24,
            ),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? const Color(0xFF00E676) : Colors.white60,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF00E676) : Colors.white70,
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDarkTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white60, fontSize: 13),
        prefixIcon: Icon(icon, color: const Color(0xFF00E676), size: 20),
        filled: true,
        fillColor: const Color(0xFF121417),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white24),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF00E676)),
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
                RoleThemeManager.instance.setRole(PlatformRole.cliente);
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute<void>(
                    builder: (_) => const CustomerMainNavigationShell(),
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
