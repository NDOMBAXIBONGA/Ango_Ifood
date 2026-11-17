import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'ango_network_image.dart';

/// Widget profissional e resiliente de reprodução de vídeo nativo no Ango-iFood.
/// Suporta reprodução de arquivos MP4, MOV, WebM e fluxos HTTP 206 Partial Content
/// com buffering, scrubbing de progresso, mute/unmute e recuperação de erros.
class AngoVideoPlayerWidget extends StatefulWidget {
  final String videoUrl;
  final String? thumbnailUrl;
  final bool autoPlay;
  final bool looping;
  final double? preferredAspectRatio;
  final VoidCallback? onFullScreenRequested;

  const AngoVideoPlayerWidget({
    super.key,
    required this.videoUrl,
    this.thumbnailUrl,
    this.autoPlay = false,
    this.looping = true,
    this.preferredAspectRatio = 16 / 9,
    this.onFullScreenRequested,
  });

  @override
  State<AngoVideoPlayerWidget> createState() => _AngoVideoPlayerWidgetState();
}

class _AngoVideoPlayerWidgetState extends State<AngoVideoPlayerWidget> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _showControls = true;
  Timer? _hideControlsTimer;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPlay) {
      _initializeAndPlay();
    }
  }

  @override
  void didUpdateWidget(covariant AngoVideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _disposeController();
      if (widget.autoPlay) {
        _initializeAndPlay();
      } else {
        setState(() {
          _isInitialized = false;
          _hasError = false;
        });
      }
    }
  }

  Future<void> _initializeAndPlay() async {
    final sanitized = sanitizeAngoMediaUrl(widget.videoUrl);
    if (sanitized.isEmpty) {
      setState(() {
        _hasError = true;
        _errorMessage = 'URL de vídeo inválida ou ausente.';
      });
      return;
    }

    setState(() {
      _hasError = false;
      _errorMessage = '';
    });

    try {
      final uri = Uri.parse(sanitized);
      final controller = VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      _controller = controller;

      await controller.initialize();
      await controller.setLooping(widget.looping);

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
        await controller.play();
        _startHideControlsTimer();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = 'Falha ao reproduzir fluxo de vídeo: $e';
        });
      }
    }
  }

  void _disposeController() {
    _hideControlsTimer?.cancel();
    _controller?.pause();
    _controller?.dispose();
    _controller = null;
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  void _togglePlayPause() {
    final ctrl = _controller;
    if (ctrl == null || !_isInitialized) {
      _initializeAndPlay();
      return;
    }

    setState(() {
      if (ctrl.value.isPlaying) {
        ctrl.pause();
        _showControls = true;
        _hideControlsTimer?.cancel();
      } else {
        ctrl.play();
        _startHideControlsTimer();
      }
    });
  }

  void _toggleMute() {
    final ctrl = _controller;
    if (ctrl == null) return;
    setState(() {
      _isMuted = !_isMuted;
      ctrl.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  void _onPlayerTapped() {
    setState(() {
      _showControls = !_showControls;
      if (_showControls && (_controller?.value.isPlaying ?? false)) {
        _startHideControlsTimer();
      }
    });
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final ratio = widget.preferredAspectRatio ??
        (_controller != null && _isInitialized && _controller!.value.aspectRatio > 0
            ? _controller!.value.aspectRatio
            : 16 / 9);

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: ratio,
        child: Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Superfície de Vídeo Ativa ou Poster Frame Inicial
              if (_controller != null && _isInitialized)
                Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio > 0
                        ? _controller!.value.aspectRatio
                        : ratio,
                    child: VideoPlayer(_controller!),
                  ),
                )
              else if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty)
                AngoNetworkImage(
                  imageUrl: widget.thumbnailUrl,
                  fit: BoxFit.cover,
                  fallbackIcon: Icons.videocam_rounded,
                )
              else
                Container(
                  color: const Color(0xFF0F172A),
                  child: const Center(
                    child: Icon(Icons.videocam_rounded, color: Colors.white54, size: 54),
                  ),
                ),

              // 2. Indicador de Buffering / Carregamento
              if (_controller != null &&
                  _isInitialized &&
                  _controller!.value.isBuffering)
                const Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Color(0xFFDC2626),
                  ),
                ),

              // 3. Ecrã de Erro com Botão de Tentar Novamente
              if (_hasError)
                Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 40),
                        const SizedBox(height: 8),
                        Text(
                          _errorMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: _initializeAndPlay,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('Tentar Novamente'),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // 4. Camada de Toque do Utilizador
              if (!_hasError)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _onPlayerTapped,
                    child: Container(color: Colors.transparent),
                  ),
                ),

              // 5. Controles de Reprodução Sobrepostos (Overlay)
              if (!_hasError && (_showControls || !_isInitialized)) ...[
                // Escurecimento suave do fundo para legibilidade
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      color: Colors.black.withOpacity(0.38),
                    ),
                  ),
                ),

                // Botão Central de Play / Pause
                Center(
                  child: GestureDetector(
                    onTap: _togglePlayPause,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDC2626).withOpacity(0.92),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.4),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Icon(
                        (_controller?.value.isPlaying ?? false)
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 42,
                      ),
                    ),
                  ),
                ),

                // Barra Superior: Badge HD e Mute
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              (_controller?.value.isPlaying ?? false)
                                  ? Icons.stream_rounded
                                  : Icons.hd_rounded,
                              color: (_controller?.value.isPlaying ?? false)
                                  ? const Color(0xFF4ADE80)
                                  : Colors.white,
                              size: 15,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              (_controller?.value.isPlaying ?? false)
                                  ? 'HD Vídeo • Em Reprodução'
                                  : 'Vídeo HD 1080p',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isInitialized)
                        IconButton.filledTonal(
                          onPressed: _toggleMute,
                          icon: Icon(
                            _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black.withOpacity(0.65),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                ),

                // Barra Inferior: Progresso e Tempo Decorrido
                if (_controller != null && _isInitialized)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withOpacity(0.85),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          VideoProgressIndicator(
                            _controller!,
                            allowScrubbing: true,
                            colors: const VideoProgressColors(
                              playedColor: Color(0xFFDC2626),
                              bufferedColor: Colors.white38,
                              backgroundColor: Colors.white12,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 6),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              ValueListenableBuilder(
                                valueListenable: _controller!,
                                builder: (context, VideoPlayerValue val, _) {
                                  return Text(
                                    '${_formatDuration(val.position)} / ${_formatDuration(val.duration)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  );
                                },
                              ),
                              if (widget.onFullScreenRequested != null)
                                GestureDetector(
                                  onTap: widget.onFullScreenRequested,
                                  child: const Icon(
                                    Icons.fullscreen_rounded,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
