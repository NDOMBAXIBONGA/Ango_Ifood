/// Modelo de dados de resposta do endpoint Django /api/app/check-update/.
class AppUpdateInfo {
  final bool atualizacaoDisponivel;
  final bool forcarAtualizacao;
  final String versaoNome;
  final int versaoCodigo;
  final String actionUrl;
  final String notasAtualizacao;

  const AppUpdateInfo({
    required this.atualizacaoDisponivel,
    required this.forcarAtualizacao,
    required this.versaoNome,
    required this.versaoCodigo,
    required this.actionUrl,
    required this.notasAtualizacao,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      atualizacaoDisponivel: json['atualizacao_disponivel'] as bool? ?? false,
      forcarAtualizacao: json['forcar_atualizacao'] as bool? ?? false,
      versaoNome: json['versao_nome']?.toString() ?? '',
      versaoCodigo: (json['versao_codigo'] as num?)?.toInt() ?? 0,
      actionUrl: json['action_url']?.toString() ?? '',
      notasAtualizacao: json['notas_atualizacao']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'atualizacao_disponivel': atualizacaoDisponivel,
      'forcar_atualizacao': forcarAtualizacao,
      'versao_nome': versaoNome,
      'versao_codigo': versaoCodigo,
      'action_url': actionUrl,
      'notas_atualizacao': notasAtualizacao,
    };
  }
}
