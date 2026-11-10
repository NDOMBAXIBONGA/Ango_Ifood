import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/partner_bloc.dart';
import '../models/partner_models.dart';

/// Ecrã de Configuração do Calendário Operacional Semanal da Loja (RN-012).
///
/// Arquitetura UX/UI Mobile-First:
/// - Cartões dedicados para cada um dos 7 dias da semana (Segunda a Domingo);
/// - Seletores de hora de abertura e fecho de toque amplo via `showTimePicker` (formato 24h);
/// - Identificação visual de Turnos Noturnos que atravessam a meia-noite;
/// - Ação rápida para replicar horários de um dia para toda a semana;
/// - Barra de ação inferior reativa quando há alterações pendentes.
class BusinessHoursConfigScreen extends StatefulWidget {
  const BusinessHoursConfigScreen({super.key});

  @override
  State<BusinessHoursConfigScreen> createState() => _BusinessHoursConfigScreenState();
}

class _BusinessHoursConfigScreenState extends State<BusinessHoursConfigScreen> {
  late List<BusinessHourSlot> _slots;
  bool _temAlteracoesPendentes = false;

  @override
  void initState() {
    super.initState();
    _slots = _gerarSlotsIniciais();
  }

  List<BusinessHourSlot> _gerarSlotsIniciais() {
    return List.generate(7, (dia) {
      return BusinessHourSlot(
        diaSemana: dia,
        horaAbertura: const TimeOfDay(hour: 8, minute: 0),
        horaFecho: const TimeOfDay(hour: 22, minute: 0),
        isAtivo: dia != 6, // Domingo fechado por omissão se não configurado
      );
    });
  }

  void _sincronizarComEstado(List<BusinessHourSlot> horariosCarregados) {
    if (horariosCarregados.isEmpty) return;

    final mapaExistentes = {for (final h in horariosCarregados) h.diaSemana: h};
    _slots = List.generate(7, (dia) {
      if (mapaExistentes.containsKey(dia)) {
        return mapaExistentes[dia]!;
      }
      return BusinessHourSlot(
        diaSemana: dia,
        horaAbertura: const TimeOfDay(hour: 8, minute: 0),
        horaFecho: const TimeOfDay(hour: 22, minute: 0),
        isAtivo: false,
      );
    });
  }

  Future<void> _selecionarHora({
    required BuildContext context,
    required int diaIndex,
    required bool isAbertura,
  }) async {
    final slotAtual = _slots[diaIndex];
    final horaInicial = isAbertura ? slotAtual.horaAbertura : slotAtual.horaFecho;

    final novaHora = await showTimePicker(
      context: context,
      initialTime: horaInicial,
      helpText: isAbertura
          ? 'Hora de Abertura - ${slotAtual.nomeDia}'
          : 'Hora de Fecho - ${slotAtual.nomeDia}',
      cancelText: 'Cancelar',
      confirmText: 'Confirmar',
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );

    if (novaHora != null) {
      setState(() {
        if (isAbertura) {
          _slots[diaIndex] = slotAtual.copyWith(horaAbertura: novaHora);
        } else {
          _slots[diaIndex] = slotAtual.copyWith(horaFecho: novaHora);
        }
        _temAlteracoesPendentes = true;
      });
    }
  }

  void _toggleDiaAtivo(int diaIndex, bool ativo) {
    setState(() {
      _slots[diaIndex] = _slots[diaIndex].copyWith(isAtivo: ativo);
      _temAlteracoesPendentes = true;
    });
  }

  void _copiarParaTodosOsDias(int diaOrigem) {
    final molde = _slots[diaOrigem];
    setState(() {
      _slots = List.generate(7, (dia) {
        return molde.copyWith(diaSemana: dia);
      });
      _temAlteracoesPendentes = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Horário de ${molde.nomeDia} copiado para todos os dias!'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _salvarHorarios() {
    // Validação de segurança: abertura != fecho
    for (final slot in _slots) {
      if (slot.isAtivo) {
        if (slot.horaAbertura == slot.horaFecho) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Erro em ${slot.nomeDia}: A hora de abertura não pode ser igual à hora de fecho.',
              ),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
      }
    }

    context.read<PartnerBloc>().add(SaveBusinessHoursRequested(_slots));
    setState(() {
      _temAlteracoesPendentes = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final diasAtivosCount = _slots.where((s) => s.isAtivo).length;

    return BlocConsumer<PartnerBloc, PartnerState>(
      listener: (context, state) {
        if (state.errorMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage!),
              backgroundColor: colorScheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
        } else if (state.successMessage != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.successMessage!),
              backgroundColor: const Color(0xFF16A34A),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      },
      builder: (context, state) {
        if (state.businessHours.isNotEmpty && !_temAlteracoesPendentes) {
          _sincronizarComEstado(state.businessHours);
        }

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            title: const Text(
              'Horários de Operação',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: Color(0xFF0F172A),
              ),
            ),
            actions: [
              if (state.isUpdatingHours)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_temAlteracoesPendentes)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TextButton.icon(
                    icon: const Icon(Icons.check_circle_rounded, size: 18, color: Color(0xFF1E88E5)),
                    label: const Text(
                      'Guardar',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1E88E5),
                      ),
                    ),
                    onPressed: _salvarHorarios,
                  ),
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              // Card Informativo & KPI de Cobertura Semanal
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.02),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.calendar_month_rounded,
                        color: Color(0xFF1E88E5),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$diasAtivosCount de 7 dias operacionais',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Pedidos fora destes turnos são bloqueados automaticamente.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Lista dos 7 Dias da Semana em Cartões Mobile-First
              ...List.generate(7, (index) {
                final slot = _slots[index];
                return _DayScheduleCard(
                  slot: slot,
                  onToggle: (ativo) => _toggleDiaAtivo(index, ativo),
                  onSelectAbertura: () => _selecionarHora(
                    context: context,
                    diaIndex: index,
                    isAbertura: true,
                  ),
                  onSelectFecho: () => _selecionarHora(
                    context: context,
                    diaIndex: index,
                    isAbertura: false,
                  ),
                  onCopyAll: () => _copiarParaTodosOsDias(index),
                );
              }),
            ],
          ),

          // Barra Fixa Inferior com Destaque de Salvamento Pendente
          bottomSheet: _temAlteracoesPendentes
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.08),
                        blurRadius: 16,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: SafeArea(
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline_rounded,
                          color: Color(0xFFEA580C),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Existem alterações pendentes.',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF334155),
                            ),
                          ),
                        ),
                        FilledButton(
                          onPressed: state.isUpdatingHours ? null : _salvarHorarios,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1E88E5),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: state.isUpdatingHours
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation(Colors.white),
                                  ),
                                )
                              : const Text(
                                  'Guardar Horários',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                        ),
                      ],
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }
}

/// Cartão de Horário para um Dia Específico da Semana
class _DayScheduleCard extends StatelessWidget {
  final BusinessHourSlot slot;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSelectAbertura;
  final VoidCallback onSelectFecho;
  final VoidCallback onCopyAll;

  const _DayScheduleCard({
    required this.slot,
    required this.onToggle,
    required this.onSelectAbertura,
    required this.onSelectFecho,
    required this.onCopyAll,
  });

  @override
  Widget build(BuildContext context) {
    final isAtivo = slot.isAtivo;
    final cruzaMeiaNoite = slot.cruzaMeiaNoite;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isAtivo ? Colors.white : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isAtivo ? const Color(0xFFE2E8F0) : const Color(0xFFCBD5E1),
          width: isAtivo ? 1.2 : 1.0,
        ),
        boxShadow: isAtivo
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.02),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Linha Superior: Nome do Dia + Chip Status + Switch
            Row(
              children: [
                Text(
                  slot.nomeDia,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.bold,
                    color: isAtivo ? const Color(0xFF0F172A) : const Color(0xFF64748B),
                  ),
                ),
                const SizedBox(width: 8),

                // Chip Aberto / Encerrado
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isAtivo ? const Color(0xFFDCFCE7) : const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    isAtivo ? 'Aberto' : 'Encerrado',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isAtivo ? const Color(0xFF16A34A) : const Color(0xFF64748B),
                    ),
                  ),
                ),

                const Spacer(),

                // Menu de Ações (Copiar Horário)
                if (isAtivo)
                  PopupMenuButton<String>(
                    tooltip: 'Opções',
                    icon: const Icon(Icons.more_horiz, size: 20, color: Color(0xFF64748B)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    onSelected: (val) {
                      if (val == 'copy') onCopyAll();
                    },
                    itemBuilder: (ctx) => [
                      PopupMenuItem(
                        value: 'copy',
                        child: Row(
                          children: [
                            const Icon(Icons.copy_rounded, size: 18, color: Color(0xFF1E88E5)),
                            const SizedBox(width: 8),
                            Text('Replicar para a semana inteira'),
                          ],
                        ),
                      ),
                    ],
                  ),

                Switch.adaptive(
                  value: isAtivo,
                  activeColor: const Color(0xFF16A34A),
                  onChanged: onToggle,
                ),
              ],
            ),

            // Linha Inferior: Seletores de Hora (Apenas quando aberto)
            if (isAtivo) ...[
              const SizedBox(height: 12),
              const Divider(height: 1, color: Color(0xFFF1F5F9)),
              const SizedBox(height: 12),
              Row(
                children: [
                  // Botão Hora de Abertura
                  Expanded(
                    child: _TimeButton(
                      label: 'Abertura',
                      timeText: slot.aberturaFormatada,
                      icon: Icons.wb_sunny_outlined,
                      iconColor: const Color(0xFFEA580C),
                      onTap: onSelectAbertura,
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                  // Botão Hora de Fecho
                  Expanded(
                    child: _TimeButton(
                      label: 'Fecho',
                      timeText: slot.fechoFormatada,
                      icon: Icons.nightlight_round_outlined,
                      iconColor: const Color(0xFF6366F1),
                      onTap: onSelectFecho,
                    ),
                  ),
                ],
              ),

              // Alerta Turno Noturno
              if (cruzaMeiaNoite) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFED7AA)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.dark_mode_rounded, size: 14, color: Color(0xFFEA580C)),
                      SizedBox(width: 6),
                      Text(
                        'Turno Noturno: encerra na madrugada seguinte (+1 dia)',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFC2410C),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ] else ...[
              const SizedBox(height: 4),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Estabelecimento não recebe pedidos neste dia.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Botão de Seleção de Horário
class _TimeButton extends StatelessWidget {
  final String label;
  final String timeText;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;

  const _TimeButton({
    required this.label,
    required this.timeText,
    required this.icon,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFCBD5E1)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    Text(
                      timeText,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.access_time_rounded,
                size: 14,
                color: Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
