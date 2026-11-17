import 'package:flutter/material.dart';
import '../network/app_environment_config.dart';

/// Sanitizador universal de URLs de imagem para o ecossistema Ango-iFood.
/// Transforma caminhos relativos (/media/...) em URLs completas HTTPS
/// e garante compatibilidade com o proxy reverso do Render Cloud.
String sanitizeAngoMediaUrl(String? rawUrl) {
  if (rawUrl == null) return '';
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return '';

  if (trimmed.startsWith('/media/') || trimmed.startsWith('/static/')) {
    final base = AppEnvironmentConfig.baseHttpUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base$trimmed';
  }

  if (trimmed.startsWith('http://ango-ifood.onrender.com')) {
    return trimmed.replaceFirst('http://', 'https://');
  }

  return trimmed;
}

/// Widget resiliente para carregamento de imagens de catálogo, vitrine e produtos.
/// Oferece:
/// 1. Sanitização automática de URLs relativas do servidor Render;
/// 2. Indicador de carregamento suave com animação;
/// 3. Fallback visual elegante em caso de falha de conexão (sem ecrãs pretos ou crashes).
class AngoNetworkImage extends StatelessWidget {
  final String? imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius? borderRadius;
  final IconData fallbackIcon;
  final Color? placeholderColor;
  final Widget? customFallback;

  const AngoNetworkImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.fallbackIcon = Icons.restaurant_rounded,
    this.placeholderColor,
    this.customFallback,
  });

  @override
  Widget build(BuildContext context) {
    final sanitizedUrl = sanitizeAngoMediaUrl(imageUrl);
    final theme = Theme.of(context);
    final bgColor = placeholderColor ?? theme.colorScheme.surfaceContainerHighest;

    Widget buildFallback() {
      if (customFallback != null) return customFallback!;
      return Container(
        width: width,
        height: height,
        color: bgColor,
        child: Center(
          child: Icon(
            fallbackIcon,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            size: (width != null && height != null)
                ? (width! < height! ? width! * 0.35 : height! * 0.35).clamp(16.0, 48.0)
                : 28.0,
          ),
        ),
      );
    }

    if (sanitizedUrl.isEmpty) {
      return _applyBorderRadius(buildFallback());
    }

    final imageWidget = Image.network(
      sanitizedUrl,
      width: width,
      height: height,
      fit: fit,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        final total = loadingProgress.expectedTotalBytes;
        final loaded = loadingProgress.cumulativeBytesLoaded;
        final progress = (total != null && total > 0) ? loaded / total : null;

        return Container(
          width: width,
          height: height,
          color: bgColor,
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2,
                color: theme.colorScheme.primary.withOpacity(0.7),
              ),
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return buildFallback();
      },
    );

    return _applyBorderRadius(imageWidget);
  }

  Widget _applyBorderRadius(Widget child) {
    if (borderRadius != null) {
      return ClipRRect(
        borderRadius: borderRadius!,
        child: child,
      );
    }
    return child;
  }
}
