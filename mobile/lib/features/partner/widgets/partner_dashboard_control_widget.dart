import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/partner_bloc.dart';
import '../models/partner_models.dart';

/// Painel superior de controlo operacional rápido da loja (RN-013).
///
/// Apresenta o estado em tempo real da loja, um interruptor (Switch) para
/// alternar instantaneamente entre "Disponível" e "Pausa Temporária", e um timer
/// regressivo dinâmico com aviso visual de reabertura automática.
class PartnerDashboardControlWidget extends StatelessWidget {
  const PartnerDashboardControlWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocBuilder<PartnerBloc, PartnerState>(
      builder: (context, state) {
        final storeStatus = state.storeStatus;
        final isPausada = storeStatus?.isPausada ?? false;
        final tempoRestante = state.tempoRestantePausa ?? storeStatus?.tempoRestantePausa;

        final statusColor = isPausada ? const Color(0xFFE65100) : const Color(0xFF2E7D32);
        final statusBgColor = isPausada ? const Color(0xFFFFF3E0) : const Color(0xFFE8F5E9);
        final statusText = isPausada ? 'Pausa Temporária' : 'Loja Aberta & Disponível';
        final statusDesc = isPausada
            ? 'A receção de novos pedidos está pausada (RN-013).'
            : 'A loja está apta a receber pedidos de clientes.';

        return Container(
          width: double.infinity,
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isPausada ? const Color(0xFFFFB74D) : colorScheme.outlineVariant,
              width: isPausada ? 2.0 : 1.0,
            ),
            boxShadow: [
              BoxShadow(
                color: isPausada
                    ? const Color(0xFFE65100).withOpacity(0.08)
                    : colorScheme.shadow.withOpacity(0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Barra Principal: Nome da Loja, Estado e Switch
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Ícone de estado circular com pulso visual
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: statusBgColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPausada ? Icons.pause_circle_rounded : Icons.store_rounded,
                      color: statusColor,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Informação de Estado
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              storeStatus?.nome ?? 'A Minha Loja',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: statusBgColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: statusColor.withOpacity(0.5)),
                              ),
                              child: Text(
                                statusText,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: statusColor,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          statusDesc,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Controlo Switch: Aberta (ON) vs Pausa (OFF)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Switch.adaptive(
                        value: !isPausada,
                        activeColor: const Color(0xFF2E7D32),
                        inactiveThumbColor: const Color(0xFFE65100),
                        inactiveTrackColor: const Color(0xFFFFCC80),
                        onChanged: (novoValorAtivo) {
                          if (novoValorAtivo) {
                            // Reabrir a loja imediatamente
                            context.read<PartnerBloc>().add(
                                  const ToggleStorePauseRequested(isPausaTemporaria: false),
                                );
                          } else {
                            // Abrir diálogo de seleção de tempo de pausa (RN-013)
                            _exibirDialogoPausa(context);
                          }
                        },
                      ),
                      Text(
                        !isPausada ? 'Disponível' : 'Pausada',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: !isPausada ? const Color(0xFF2E7D32) : const Color(0xFFE65100),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              // Seletor e Timer de Contagem Regressiva (visível quando em Pausa)
              if (isPausada) ...[
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFB74D)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.timer_outlined,
                        color: Color(0xFFE65100),
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Reativação Automática Agendada (RN-013)',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: const Color(0xFFE65100),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              tempoRestante != null
                                  ? 'Tempo restante: ${_formatDuration(tempoRestante)}'
                                  : 'A reativar no término do prazo...',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFBF360C),
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          textStyle: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onPressed: () {
                          context.read<PartnerBloc>().add(
                                const ToggleStorePauseRequested(isPausaTemporaria: false),
                              );
                        },
                        child: const Text('Reabrir Agora'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _formatDuration(Duration d) {
    final horas = d.inHours;
    final minutos = d.inMinutes.remainder(60);
    final segundos = d.inSeconds.remainder(60);

    if (horas > 0) {
      return '${horas}h ${minutos.toString().padLeft(2, '0')}m ${segundos.toString().padLeft(2, '0')}s';
    }
    return '${minutos.toString().padLeft(2, '0')}m ${segundos.toString().padLeft(2, '0')}s';
  }

  /// Diálogo modal para configuração do tempo de pausa temporária (RN-013).
  static void _exibirDialogoPausa(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => _PauseDurationSelectionDialog(
        onConfirm: (minutos) {
          context.read<PartnerBloc>().add(
                ToggleStorePauseRequested(
                  isPausaTemporaria: true,
                  duracaoMinutos: minutos,
                ),
              );
        },
      ),
    );
  }
}

/// Diálogo com opções de 15 min, 30 min, 60 min ou Personalizado (RN-013).
class _PauseDurationSelectionDialog extends StatefulWidget {
  final ValueChanged<int> onConfirm;

  const _PauseDurationSelectionDialog({required this.onConfirm});

  @override
  State<_PauseDurationSelectionDialog> createState() => _PauseDurationSelectionDialogState();
}

class _PauseDurationSelectionDialogState extends State<_PauseDurationSelectionDialog> {
  int _opcaoSelecionada = 30; // 30 min por defeito
  bool _isPersonalizado = false;
  final TextEditingController _customController = TextEditingController(text: '45');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final opcoesPredefinidas = [15, 30, 60];

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.pause_circle_outline, color: Color(0xFFE65100), size: 28),
          const SizedBox(width: 12),
          const Text('Pausar Receção de Pedidos'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Indica a duração da pausa temporária. A loja será reativada automaticamente na plataforma após o término do prazo (RN-013):',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),

              // Botões de Rádio para durações pré-definidas
              ...opcoesPredefinidas.map((minutos) {
                return RadioListTile<int>(
                  value: minutos,
                  groupValue: _isPersonalizado ? null : _opcaoSelecionada,
                  contentPadding: EdgeInsets.zero,
                  title: Text('$minutos minutos'),
                  subtitle: Text(_getSubtitleForMinutes(minutos)),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _opcaoSelecionada = val;
                        _isPersonalizado = false;
                      });
                    }
                  },
                );
              }),

              // Opção personalizada
              RadioListTile<bool>(
                value: true,
                groupValue: _isPersonalizado,
                contentPadding: EdgeInsets.zero,
                title: const Text('Tempo Personalizado'),
                subtitle: const Text('Configura manualmente entre 5 e 480 minutos.'),
                onChanged: (val) {
                  setState(() {
                    _isPersonalizado = true;
                  });
                },
              ),

              if (_isPersonalizado) ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: _customController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Duração em minutos',
                    suffixText: 'minutos',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.timer),
                  ),
                  validator: (valor) {
                    if (valor == null || valor.isEmpty) {
                      return 'Por favor insira um valor.';
                    }
                    final n = int.tryParse(valor);
                    if (n == null || n < 5 || n > 480) {
                      return 'Valor deve situar-se entre 5 e 480 minutos.';
                    }
                    return null;
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE65100),
            foregroundColor: Colors.white,
          ),
          onPressed: () {
            if (_isPersonalizado) {
              if (_formKey.currentState?.validate() ?? false) {
                final customMinutes = int.parse(_customController.text);
                widget.onConfirm(customMinutes);
                Navigator.of(context).pop();
              }
            } else {
              widget.onConfirm(_opcaoSelecionada);
              Navigator.of(context).pop();
            }
          },
          child: const Text('Confirmar Pausa'),
        ),
      ],
    );
  }

  String _getSubtitleForMinutes(int m) {
    switch (m) {
      case 15:
        return 'Alívio rápido de cozinha ou troca de turno.';
      case 30:
        return 'Pausa recomendada para reabastecimento.';
      case 60:
        return 'Pausa prolongada para reposição de stock.';
      default:
        return '';
    }
  }
}

