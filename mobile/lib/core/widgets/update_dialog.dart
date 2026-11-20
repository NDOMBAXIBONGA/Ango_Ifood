import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_update_info.dart';
import '../services/session_recovery_service.dart';

/// Diálogo interativo e modular de atualização OTA com suporte multiplataforma:
/// - Android: download in-app com barra de progresso (0% a 100%) e abertura do instalador nativo.
/// - iOS: redirecionamento para o site externo / Safari para baixar o ficheiro .ipa.
/// - Suporte a Kill Switch (bloqueia o botão 'Voltar' e oculta opção de ignorar se for obrigatório).
/// - Salva o ecrã ativo antes de atualizar para retoma transparente no regresso.
class UpdateDialog extends StatefulWidget {
  final AppUpdateInfo updateInfo;
  final String currentRouteName;
  final Map<String, dynamic>? currentRouteArgs;

  const UpdateDialog({
    super.key,
    required this.updateInfo,
    this.currentRouteName = '/',
    this.currentRouteArgs,
  });

  /// Método estático utilitário para exibir o diálogo de forma segura
  static Future<void> show(
    BuildContext context, {
    required AppUpdateInfo updateInfo,
    String currentRouteName = '/',
    Map<String, dynamic>? currentRouteArgs,
  }) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: !updateInfo.forcarAtualizacao,
      builder: (_) => UpdateDialog(
        updateInfo: updateInfo,
        currentRouteName: currentRouteName,
        currentRouteArgs: currentRouteArgs,
      ),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String _progressText = '0%';
  String _bytesInfo = '';
  String? _errorMessage;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 45),
      receiveTimeout: const Duration(seconds: 120),
    ),
  );

  CancelToken? _cancelToken;

  @override
  void dispose() {
    _cancelToken?.cancel('Diálogo fechado');
    super.dispose();
  }

  /// Fluxo de Atualização no Android: Download in-app via Dio e instalação via OpenFilex
  Future<void> _startAndroidUpdate() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _progress = 0.0;
      _progressText = '0%';
      _bytesInfo = 'A iniciar transferência...';
    });

    _cancelToken = CancelToken();

    try {
      // 1. Salva a sessão ativa antes de disparar o instalador
      await SessionRecoveryService.instance.saveCurrentRouteBeforeUpdate(
        routeName: widget.currentRouteName,
        arguments: widget.currentRouteArgs,
      );

      // 2. Determina a pasta de destino para o APK baixado
      Directory? dir = await getExternalStorageDirectory();
      dir ??= await getApplicationDocumentsDirectory();

      final fileName = 'delivery_update_${widget.updateInfo.versaoCodigo}.apk';
      final savePath = '${dir.path}/$fileName';

      // 3. Executa o download com callback de progresso
      await _dio.download(
        widget.updateInfo.actionUrl,
        savePath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            final percent = received / total;
            final recMb = (received / (1024 * 1024)).toStringAsFixed(1);
            final totalMb = (total / (1024 * 1024)).toStringAsFixed(1);

            setState(() {
              _progress = percent;
              _progressText = '${(percent * 100).toInt()}%';
              _bytesInfo = '$recMb MB de $totalMb MB';
            });
          }
        },
      );

      if (!mounted) return;

      setState(() {
        _isDownloading = false;
        _bytesInfo = 'Transferência concluída. A abrir instalador...';
      });

      // 4. Invoca o instalador de pacotes nativo do sistema Android
      final result = await OpenFilex.open(
        savePath,
        type: 'application/vnd.android.package-archive',
      );

      if (result.type != ResultType.done && mounted) {
        setState(() {
          _errorMessage =
              'Não foi possível iniciar o instalador automaticamente (${result.message}). Verifique as permissões de ficheiros nas Definições.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _errorMessage = 'Falha ao descarregar a atualização: $e';
      });
    }
  }

  /// Fluxo de Atualização no iOS: Redireciona para o site oficial/Safari
  Future<void> _startIosUpdate() async {
    try {
      // 1. Salva a sessão ativa para recuperação ao regressar
      await SessionRecoveryService.instance.saveCurrentRouteBeforeUpdate(
        routeName: widget.currentRouteName,
        arguments: widget.currentRouteArgs,
      );

      // 2. Abre a URL no navegador externo (Safari)
      final uri = Uri.parse(widget.updateInfo.actionUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = 'Não foi possível abrir o link: ${widget.updateInfo.actionUrl}';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Erro ao abrir o navegador: $e';
        });
      }
    }
  }

  void _onActionButtonPressed() {
    if (Platform.isAndroid) {
      _startAndroidUpdate();
    } else if (Platform.isIOS) {
      _startIosUpdate();
    } else {
      // Fallback para outras plataformas (Web / Desktop)
      _startIosUpdate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.updateInfo;
    final isKillSwitch = info.forcarAtualizacao;

    return PopScope(
      canPop: !isKillSwitch && !_isDownloading,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        elevation: 16,
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Cabeçalho com Ícone da Plataforma
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: isKillSwitch ? Colors.red.shade50 : Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      isKillSwitch ? Icons.security_update_warning_rounded : Icons.system_update_rounded,
                      color: isKillSwitch ? Colors.red.shade600 : Colors.blue.shade600,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isKillSwitch ? 'Atualização Obrigatória' : 'Nova Versão Disponível',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isKillSwitch ? Colors.red.shade900 : Colors.grey.shade900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Versão ${info.versaoNome} (Build ${info.versaoCodigo})',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Mensagem explicativa
              Text(
                isKillSwitch
                    ? 'Esta atualização contém correções críticas de segurança ou estabilidade. É obrigatório atualizar para continuar a utilizar a app.'
                    : 'Uma nova versão da aplicação Ango_Ifood está pronta com novidades e otimizações.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.4),
              ),

              // Changelog / Notas de Atualização
              if (info.notasAtualizacao.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  constraints: const BoxConstraints(maxHeight: 120),
                  child: SingleChildScrollView(
                    child: Text(
                      info.notasAtualizacao,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade800, height: 1.3),
                    ),
                  ),
                ),
              ],

              // Área de Progresso de Download (Android)
              if (_isDownloading) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.red.shade600),
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_bytesInfo, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    Text(_progressText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],

              // Mensagem de Erro (se houver)
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: TextStyle(fontSize: 11, color: Colors.red.shade700, fontWeight: FontWeight.w500),
                ),
              ],

              const SizedBox(height: 24),

              // Botões de Ação
              Row(
                children: [
                  // Botão "Agora não" (apenas se a atualização NÃO for obrigatória e não estiver a descarregar)
                  if (!isKillSwitch && !_isDownloading) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(
                          'Agora não',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade700, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],

                  // Botão Principal de Atualização
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isDownloading ? null : _onActionButtonPressed,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEA1D2C), // Vermelho Oficial Ango_Ifood
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        _isDownloading
                            ? 'A descarregar...'
                            : Platform.isIOS
                                ? 'Ir para Download (iOS)'
                                : 'Atualizar Agora',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
