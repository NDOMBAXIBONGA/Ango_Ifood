import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/partner_bloc.dart';
import '../models/partner_models.dart';

/// Ecrã de Configuração do Calendário Operacional Semanal da Loja (RN-012).
///
/// Interface com layout tabular para os 7 dias da semana (Segunda a Domingo):
/// - Seletores de hora de abertura e fecho via `showTimePicker`;
/// - Deteção de turnos noturnos que atravessam a meia-noite;
/// - Comutador de dia aberto/encerrado;
/// - Gravação via `PartnerBloc` com validações rigorosas.
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
              backgroundColor: const Color(0xFF2E7D32),
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
          appBar: AppBar(
            title: const Text('Horário de Funcionamento (RN-012)'),
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
              else
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Guardar Horários'),
                    onPressed: _salvarHorarios,
                  ),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Cartão Informativo das Regras
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colorScheme.primary.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'RN-012: Define os turnos semanais da tua loja. Pedidos efetuados fora deste '
                          'calendário são bloqueados automaticamente pelo motor de checkout. '
                          'Horários que ultrapassam a meia-noite (ex.: 18:00 às 02:00) são suportados.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Tabela Semanal de Horários
                Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: colorScheme.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.shadow.withOpacity(0.04),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // Cabeçalho da Tabela
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant.withOpacity(0.5),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                        ),
                        child: Row(
                          children: [
                            const Expanded(
                              flex: 3,
                              child: Text(
                                'Dia da Semana',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            const Expanded(
                              flex: 2,
                              child: Text(
                                'Abertura',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 16),
                            const Expanded(
                              flex: 2,
                              child: Text(
                                'Fecho',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 16),
                            const Expanded(
                              flex: 3,
                              child: Text(
                                'Estado / Ações',
                                textAlign: TextAlign.right,
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),

                      // Linhas dos 7 Dias da Semana
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _slots.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, index) {
                          final slot = _slots[index];
                          final isAtivo = slot.isAtivo;
                          final cruzaMeiaNoite = slot.cruzaMeiaNoite;

                          return Container(
                            color: isAtivo ? Colors.transparent : colorScheme.surfaceVariant.withOpacity(0.2),
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            child: Row(
                              children: [
                                // 1. Dia da Semana
                                Expanded(
                                  flex: 3,
                                  child: Row(
                                    children: [
                                      Switch.adaptive(
                                        value: isAtivo,
                                        activeColor: const Color(0xFF2E7D32),
                                        onChanged: (val) => _toggleDiaAtivo(index, val),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              slot.nomeDia,
                                              style: theme.textTheme.bodyMedium?.copyWith(
                                                fontWeight: FontWeight.bold,
                                                color: isAtivo
                                                    ? colorScheme.onSurface
                                                    : colorScheme.outline,
                                              ),
                                            ),
                                            if (cruzaMeiaNoite && isAtivo)
                                              Container(
                                                margin: const EdgeInsets.only(top: 2),
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 1,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFFFF3E0),
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border.all(
                                                    color: const Color(0xFFFFB74D),
                                                  ),
                                                ),
                                                child: const Text(
                                                  'Turno Noturno',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color: Color(0xFFE65100),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // 2. Hora de Abertura (Botão com TimePicker)
                                Expanded(
                                  flex: 2,
                                  child: _TimePickerButton(
                                    time: slot.horaAbertura,
                                    isEnabled: isAtivo,
                                    onTap: () => _selecionarHora(
                                      context: context,
                                      diaIndex: index,
                                      isAbertura: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),

                                // 3. Hora de Fecho (Botão com TimePicker)
                                Expanded(
                                  flex: 2,
                                  child: _TimePickerButton(
                                    time: slot.horaFecho,
                                    isEnabled: isAtivo,
                                    onTap: () => _selecionarHora(
                                      context: context,
                                      diaIndex: index,
                                      isAbertura: false,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),

                                // 4. Ações: Copiar para toda a semana
                                Expanded(
                                  flex: 3,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      Text(
                                        isAtivo ? 'Aberto' : 'Encerrado',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: isAtivo
                                              ? const Color(0xFF2E7D32)
                                              : colorScheme.outline,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        icon: const Icon(Icons.copy_all, size: 20),
                                        tooltip: 'Aplicar horário a todos os dias',
                                        onPressed: isAtivo
                                            ? () => _copiarParaTodosOsDias(index)
                                            : null,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Botão customizado que apresenta a hora formatada e abre o `showTimePicker`.
class _TimePickerButton extends StatelessWidget {
  final TimeOfDay time;
  final bool isEnabled;
  final VoidCallback onTap;

  const _TimePickerButton({
    required this.time,
    required this.isEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final horaFormatada =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    return InkWell(
      onTap: isEnabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isEnabled ? colorScheme.surface : colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isEnabled ? colorScheme.outlineVariant : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.access_time,
              size: 16,
              color: isEnabled ? colorScheme.primary : colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Text(
              horaFormatada,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: isEnabled ? colorScheme.onSurface : colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

