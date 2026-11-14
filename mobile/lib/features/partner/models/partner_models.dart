import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';

// ============================================================================
// 1. FORMATADOR MONETÁRIO DE KWANZA (RN-016, RN-059)
// ============================================================================

/// Utilitário para formatação monetária em Kwanzas a partir de unidades inteiras (RN-059).
class CurrencyFormatter {
  const CurrencyFormatter._();

  /// Converte unidades inteiras em string formatada (ex.: 4500 -> "4.500 Kz").
  static String formatKwanza(int valorInteiro) {
    final isNegativo = valorInteiro < 0;
    final valorAbs = valorInteiro.abs();
    final strValor = valorAbs.toString().replaceAllMapped(
          RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
          (Match m) => '${m[1]}.',
        );
    final prefixo = isNegativo ? '-' : '';
    return '$prefixo$strValor Kz';
  }
}

// ============================================================================
// 2. ENUMS DE ALERGÉNIOS E ESTADO OPERACIONAL (RN-011, RN-013, RN-014)
// ============================================================================

/// Lista oficial de alergénios alimentares declaráveis no catálogo (RN-014).
enum AllergenType {
  gluten(id: 'gluten', label: 'Glúten', icon: Icons.grass, color: Color(0xFFD4A373)),
  lactose(id: 'lactose', label: 'Lactose', icon: Icons.water_drop, color: Color(0xFF90E0EF)),
  frutosCascaRija(
    id: 'frutos_casca_rija',
    label: 'Frutos de Casca Rija',
    icon: Icons.grain,
    color: Color(0xFFB08968),
  ),
  marisco(id: 'marisco', label: 'Marisco / Crustáceos', icon: Icons.set_meal, color: Color(0xFFE07A5F)),
  ovos(id: 'ovos', label: 'Ovos', icon: Icons.egg, color: Color(0xFFF4A261)),
  peixe(id: 'peixe', label: 'Peixe', icon: Icons.phishing, color: Color(0xFF457B9D)),
  amendoins(id: 'amendoins', label: 'Amendoins', icon: Icons.eco, color: Color(0xFFC6AC8F)),
  soja(id: 'soja', label: 'Soja', icon: Icons.spa, color: Color(0xFF81B29A)),
  sesamo(id: 'sesamo', label: 'Sementes de Sésamo', icon: Icons.grain, color: Color(0xFFDDA15E)),
  sulfitos(id: 'sulfitos', label: 'Sulfitos / Dióxido de Enxofre', icon: Icons.science, color: Color(0xFF9D8189));

  final String id;
  final String label;
  final IconData icon;
  final Color color;

  const AllergenType({
    required this.id,
    required this.label,
    required this.icon,
    required this.color,
  });

  static AllergenType? fromId(String id) {
    for (final allergen in AllergenType.values) {
      if (allergen.id.toLowerCase() == id.toLowerCase()) return allergen;
    }
    return null;
  }
}

/// Estado operacional da loja do Parceiro (RN-011, RN-013).
enum StoreOperationalStatus {
  disponivel(label: 'Disponível', color: Color(0xFF2E7D32)),
  pausaTemporaria(label: 'Pausa Temporária', color: Color(0xFFE65100)),
  fechado(label: 'Fechado', color: Color(0xFFC62828)),
  suspenso(label: 'Suspenso', color: Color(0xFF424242));

  final String label;
  final Color color;

  const StoreOperationalStatus({required this.label, required this.color});
}

// ============================================================================
// 3. MODELOS DE DADOS DA LOJA E CATÁLOGO (RN-012, RN-013, RN-014, RN-015)
// ============================================================================

/// Informações de estado da loja do parceiro e pausas temporárias (RN-013).
class PartnerStoreStatus extends Equatable {
  final String id;
  final String nome;
  final StoreOperationalStatus status;
  final bool isPausaTemporaria;
  final DateTime? reativacaoAutomaticaEm;

  const PartnerStoreStatus({
    required this.id,
    required this.nome,
    required this.status,
    required this.isPausaTemporaria,
    this.reativacaoAutomaticaEm,
  });

  bool get isPausada =>
      isPausaTemporaria &&
      (reativacaoAutomaticaEm == null || reativacaoAutomaticaEm!.isAfter(DateTime.now()));

  /// Tempo estimado padrão de preparo na cozinha em minutos (RN-075)
  int get tempoPreparoMinutos => 30;

  Duration? get tempoRestantePausa {
    if (!isPausada || reativacaoAutomaticaEm == null) return null;
    final diff = reativacaoAutomaticaEm!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  PartnerStoreStatus copyWith({
    String? id,
    String? nome,
    StoreOperationalStatus? status,
    bool? isPausaTemporaria,
    DateTime? reativacaoAutomaticaEm,
  }) {
    return PartnerStoreStatus(
      id: id ?? this.id,
      nome: nome ?? this.nome,
      status: status ?? this.status,
      isPausaTemporaria: isPausaTemporaria ?? this.isPausaTemporaria,
      reativacaoAutomaticaEm: reativacaoAutomaticaEm ?? this.reativacaoAutomaticaEm,
    );
  }

  factory PartnerStoreStatus.fromJson(Map<String, dynamic> json) {
    final isPausa = json['is_pausa_temporaria'] as bool? ?? false;
    final estadoStr = (json['estado'] as String? ?? 'ATIVO').toUpperCase();
    final reativacaoStr = json['reativacao_automatica_em'] as String?;

    StoreOperationalStatus status = StoreOperationalStatus.disponivel;
    if (isPausa || estadoStr == 'PAUSADO') {
      status = StoreOperationalStatus.pausaTemporaria;
    } else if (estadoStr == 'SUSPENSO') {
      status = StoreOperationalStatus.suspenso;
    } else if (estadoStr == 'PENDENTE') {
      status = StoreOperationalStatus.fechado;
    }

    return PartnerStoreStatus(
      id: json['id'] as String? ?? '',
      nome: json['nome'] as String? ?? 'A Minha Loja',
      status: status,
      isPausaTemporaria: isPausa,
      reativacaoAutomaticaEm: reativacaoStr != null ? DateTime.tryParse(reativacaoStr) : null,
    );
  }

  @override
  List<Object?> get props => [id, nome, status, isPausaTemporaria, reativacaoAutomaticaEm];
}

/// Categoria organizadora de itens no menu da loja (RN-014).
class MenuCategory extends Equatable {
  final String id;
  final String nome;
  final int ordemExibicao;
  final int totalItens;

  const MenuCategory({
    required this.id,
    required this.nome,
    required this.ordemExibicao,
    this.totalItens = 0,
  });

  MenuCategory copyWith({
    String? id,
    String? nome,
    int? ordemExibicao,
    int? totalItens,
  }) {
    return MenuCategory(
      id: id ?? this.id,
      nome: nome ?? this.nome,
      ordemExibicao: ordemExibicao ?? this.ordemExibicao,
      totalItens: totalItens ?? this.totalItens,
    );
  }

  factory MenuCategory.fromJson(Map<String, dynamic> json) {
    return MenuCategory(
      id: json['id'] as String? ?? '',
      nome: json['nome'] as String? ?? '',
      ordemExibicao: json['ordem_exibicao'] as int? ?? 0,
      totalItens: json['total_itens'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'nome': nome,
        'ordem_exibicao': ordemExibicao,
      };

  @override
  List<Object?> get props => [id, nome, ordemExibicao, totalItens];
}

/// Produto do menu comercializado pelo parceiro (RN-014, RN-015, RN-016).
class MenuItemModel extends Equatable {
  final String id;
  final String categoriaId;
  final String nome;
  final String descricao;
  final int preco; // Em unidades inteiras (Kwanza)
  final String? imagemUrl;
  final List<String> alergenos;
  final bool isDisponivel; // RN-015
  final bool isDestaque; // Destaque na Página Inicial da vitrine

  const MenuItemModel({
    required this.id,
    required this.categoriaId,
    required this.nome,
    required this.descricao,
    required this.preco,
    this.imagemUrl,
    this.alergenos = const [],
    this.isDisponivel = true,
    this.isDestaque = false,
  });

  MenuItemModel copyWith({
    String? id,
    String? categoriaId,
    String? nome,
    String? descricao,
    int? preco,
    String? imagemUrl,
    List<String>? alergenos,
    bool? isDisponivel,
    bool? isDestaque,
  }) {
    return MenuItemModel(
      id: id ?? this.id,
      categoriaId: categoriaId ?? this.categoriaId,
      nome: nome ?? this.nome,
      descricao: descricao ?? this.descricao,
      preco: preco ?? this.preco,
      imagemUrl: imagemUrl ?? this.imagemUrl,
      alergenos: alergenos ?? this.alergenos,
      isDisponivel: isDisponivel ?? this.isDisponivel,
      isDestaque: isDestaque ?? this.isDestaque,
    );
  }

  /// Converte a lista de identificadores textuais de alergénios nos enums tipificados oficiais
  List<AllergenType> get allergenTypes {
    final result = <AllergenType>[];
    for (final a in alergenos) {
      for (final val in AllergenType.values) {
        if (val.id.toLowerCase() == a.toLowerCase() || val.name.toLowerCase() == a.toLowerCase()) {
          result.add(val);
          break;
        }
      }
    }
    return result;
  }

  factory MenuItemModel.fromJson(Map<String, dynamic> json) {
    final rawAlergenos = json['alergenos'];
    List<String> listaAlergenos = [];
    if (rawAlergenos is List) {
      listaAlergenos = rawAlergenos.map((e) => e.toString()).toList();
    }

    return MenuItemModel(
      id: json['id'] as String? ?? '',
      categoriaId: json['categoria'] as String? ?? json['categoria_id'] as String? ?? '',
      nome: json['nome'] as String? ?? '',
      descricao: json['descricao'] as String? ?? '',
      preco: (json['preco'] as num?)?.toInt() ?? 0,
      imagemUrl: json['imagem_url'] as String?,
      alergenos: listaAlergenos,
      isDisponivel: json['is_disponivel'] as bool? ?? true,
      isDestaque: json['is_destaque'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'categoria': categoriaId,
        'nome': nome,
        'descricao': descricao,
        'preco': preco,
        if (imagemUrl != null) 'imagem_url': imagemUrl,
        'alergenos': alergenos,
        'is_disponivel': isDisponivel,
        'is_destaque': isDestaque,
      };

  @override
  List<Object?> get props => [
        id,
        categoriaId,
        nome,
        descricao,
        preco,
        imagemUrl,
        alergenos,
        isDisponivel,
        isDestaque,
      ];
}

/// Configuração de horário de funcionamento por dia da semana (RN-012).
class BusinessHourSlot extends Equatable {
  final String? id;
  final int diaSemana; // 0 = Segunda-feira .. 6 = Domingo
  final TimeOfDay horaAbertura;
  final TimeOfDay horaFecho;
  final bool isAtivo;

  const BusinessHourSlot({
    this.id,
    required this.diaSemana,
    required this.horaAbertura,
    required this.horaFecho,
    this.isAtivo = true,
  });

  String get nomeDia {
    switch (diaSemana) {
      case 0:
        return 'Segunda-feira';
      case 1:
        return 'Terça-feira';
      case 2:
        return 'Quarta-feira';
      case 3:
        return 'Quinta-feira';
      case 4:
        return 'Sexta-feira';
      case 5:
        return 'Sábado';
      case 6:
        return 'Domingo';
      default:
        return 'Desconhecido';
    }
  }

  /// Retorna a hora de abertura formatada em string HH:mm
  String get aberturaFormatada =>
      '${horaAbertura.hour.toString().padLeft(2, '0')}:${horaAbertura.minute.toString().padLeft(2, '0')}';

  /// Retorna a hora de fecho formatada em string HH:mm
  String get fechoFormatada =>
      '${horaFecho.hour.toString().padLeft(2, '0')}:${horaFecho.minute.toString().padLeft(2, '0')}';

  bool get cruzaMeiaNoite {
    final minAbertura = horaAbertura.hour * 60 + horaAbertura.minute;
    final minFecho = horaFecho.hour * 60 + horaFecho.minute;
    return minAbertura > minFecho;
  }

  BusinessHourSlot copyWith({
    String? id,
    int? diaSemana,
    TimeOfDay? horaAbertura,
    TimeOfDay? horaFecho,
    bool? isAtivo,
  }) {
    return BusinessHourSlot(
      id: id ?? this.id,
      diaSemana: diaSemana ?? this.diaSemana,
      horaAbertura: horaAbertura ?? this.horaAbertura,
      horaFecho: horaFecho ?? this.horaFecho,
      isAtivo: isAtivo ?? this.isAtivo,
    );
  }

  static TimeOfDay _parseTime(String timeStr) {
    final parts = timeStr.split(':');
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return TimeOfDay(hour: hour, minute: minute);
  }

  static String _formatTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m:00';
  }

  factory BusinessHourSlot.fromJson(Map<String, dynamic> json) {
    return BusinessHourSlot(
      id: json['id'] as String?,
      diaSemana: json['dia_semana'] as int? ?? 0,
      horaAbertura: _parseTime(json['hora_abertura'] as String? ?? '08:00:00'),
      horaFecho: _parseTime(json['hora_fecho'] as String? ?? '22:00:00'),
      isAtivo: true,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'dia_semana': diaSemana,
        'hora_abertura': _formatTime(horaAbertura),
        'hora_fecho': _formatTime(horaFecho),
      };

  @override
  List<Object?> get props => [id, diaSemana, horaAbertura, horaFecho, isAtivo];
}

