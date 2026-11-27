/// Interface de Utilizador (UI) e Gestão de Estado (`flutter_bloc` + `dio`) da App do Cliente
/// para Descoberta de Lojas (`HomeScreen`) e Navegação no Menu (`StoreMenuScreen`).
///
/// Implementa rigorosamente a Secção 6.3 e as Regras de Negócio:
/// - RN-014: Categorias, itens, descrição, preço, imagem, alergénios e grupos de opções.
/// - RN-015: Itens com `isDisponivel == false` aparecem a cinzento (desaturados) e bloqueiam
///   qualquer clique/adição ao carrinho.
/// - RN-025 / RN-026: Lojas filtradas pela morada geolocalizada (`lat`, `lng`), com badge de
///   "Fechada" e indicação do próximo horário de abertura.
/// - RN-027 / RN-028 / RN-029: Ordenação, etiqueta "Patrocinado", ETA estimada, taxa de entrega e
///   filtros interativos (Tipo de Cozinha, Avaliação >= 4.5, Entrega Grátis).

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/network/app_environment_config.dart';
import '../../core/widgets/ango_network_image.dart';
import '../../core/widgets/ango_video_player_widget.dart';
import '../auth/auth_bloc.dart';
import '../auth/storage/secure_token_storage.dart';
import '../cart/cart.dart';
import '../checkout/checkout_screen.dart';

// ============================================================================
// 1. MODELOS DE DADOS DO CATÁLOGO E DESCOBERTA (RN-014, RN-015, RN-025 a RN-029)
// ============================================================================

/// Representa a morada atual geolocalizada do Cliente (RN-005, RN-025).
@immutable
class CustomerGeoAddress extends Equatable {
  final String id;
  final String label;
  final String fullAddress;
  final String referencia;
  final String andarPorta;
  final String instrucoesEstafeta;
  final double latitude;
  final double longitude;

  const CustomerGeoAddress({
    this.id = 'morada_principal',
    required this.label,
    required this.fullAddress,
    this.referencia = '',
    this.andarPorta = '',
    this.instrucoesEstafeta = '',
    required this.latitude,
    required this.longitude,
  });

  factory CustomerGeoAddress.fromMoradaJson(Map<String, dynamic> json) {
    final texto = (json['texto_endereco'] as String?) ?? 'Luanda, Angola';
    final ref = (json['referencia'] as String?) ?? '';
    final labelExtraido = ref.trim().isNotEmpty
        ? ref.trim()
        : texto.split(',').first.trim();
    return CustomerGeoAddress(
      id: '${json['id'] ?? 'morada_principal'}',
      label: labelExtraido.isNotEmpty ? labelExtraido : 'Morada de Entrega',
      fullAddress: texto,
      referencia: ref,
      andarPorta: (json['andar_porta'] as String?) ?? '',
      instrucoesEstafeta: (json['instrucoes_estafeta'] as String?) ?? '',
      latitude: (json['lat'] as num?)?.toDouble() ?? -8.8147,
      longitude: (json['lng'] as num?)?.toDouble() ?? 13.2343,
    );
  }

  @override
  List<Object?> get props => [
        id,
        label,
        fullAddress,
        referencia,
        andarPorta,
        instrucoesEstafeta,
        latitude,
        longitude,
      ];
}

/// Representa uma Loja retornada pelo `StoreDiscoveryViewSet` (`/api/v1/catalog/stores/`).
@immutable
class StoreSummaryModel extends Equatable {
  final String id;
  final String nome;
  final String moradaTexto;
  final String imagemUrl;
  final double scoreReputacao;
  final bool isAberta;
  final String? proximoHorarioAbertura;
  final bool isPatrocinado;
  final String? etiquetaPatrocinado;
  final int etaMinutosEstimado;
  final double distanciaKm;
  final int taxaEntregaCentimos;
  final String tipoCozinha;

  const StoreSummaryModel({
    required this.id,
    required this.nome,
    required this.moradaTexto,
    required this.imagemUrl,
    required this.scoreReputacao,
    required this.isAberta,
    this.proximoHorarioAbertura,
    required this.isPatrocinado,
    this.etiquetaPatrocinado,
    required this.etaMinutosEstimado,
    required this.distanciaKm,
    required this.taxaEntregaCentimos,
    required this.tipoCozinha,
  });

  bool get isEntregaGratis => taxaEntregaCentimos == 0;

  factory StoreSummaryModel.fromJson(Map<String, dynamic> json) {
    final scoreRaw = json['score_reputacao'];
    final parsedScore = scoreRaw is num
        ? scoreRaw.toDouble()
        : double.tryParse('$scoreRaw') ?? 5.0;

    return StoreSummaryModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? 'Loja Parceira',
      moradaTexto: (json['morada_texto'] as String?) ?? '',
      imagemUrl: (json['imagem_url'] as String?) ??
          'https://images.unsplash.com/photo-1504674900247-0877df9cc836?w=800',
      scoreReputacao: parsedScore,
      isAberta: (json['is_aberta'] as bool?) ?? true,
      proximoHorarioAbertura: json['proximo_horario_abertura'] as String?,
      isPatrocinado: (json['is_patrocinado'] as bool?) ?? false,
      etiquetaPatrocinado: json['etiqueta_patrocinado'] as String?,
      etaMinutosEstimado: (json['eta_minutos_estimado'] as num?)?.toInt() ?? 30,
      distanciaKm: (json['distancia_km'] as num?)?.toDouble() ?? 1.2,
      taxaEntregaCentimos: (json['taxa_entrega'] as num?)?.toInt() ?? 50000,
      tipoCozinha: (json['tipo_cozinha'] as String?) ?? 'Restaurante',
    );
  }

  @override
  List<Object?> get props => [
        id,
        nome,
        moradaTexto,
        imagemUrl,
        scoreReputacao,
        isAberta,
        proximoHorarioAbertura,
        isPatrocinado,
        etiquetaPatrocinado,
        etaMinutosEstimado,
        distanciaKm,
        taxaEntregaCentimos,
        tipoCozinha,
      ];
}

/// Representa uma opção individual (`OpcaoItem`) dentro de um `GrupoOpcao` (RN-014).
@immutable
class MenuOptionItemModel extends Equatable {
  final String id;
  final String nome;
  final int precoAdicional;
  final bool isDisponivel;

  const MenuOptionItemModel({
    required this.id,
    required this.nome,
    required this.precoAdicional,
    required this.isDisponivel,
  });

  factory MenuOptionItemModel.fromJson(Map<String, dynamic> json) {
    return MenuOptionItemModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      precoAdicional: (json['preco_adicional'] as num?)?.toInt() ?? 0,
      isDisponivel: (json['is_disponivel'] as bool?) ?? true,
    );
  }

  @override
  List<Object?> get props => [id, nome, precoAdicional, isDisponivel];
}

/// Representa um grupo de opções (`GrupoOpcao`) de um item (RN-014).
@immutable
class MenuOptionGroupModel extends Equatable {
  final String id;
  final String nome;
  final bool isObrigatorio;
  final int minimoEscolhas;
  final int maximoEscolhas;
  final List<MenuOptionItemModel> opcoes;

  const MenuOptionGroupModel({
    required this.id,
    required this.nome,
    required this.isObrigatorio,
    required this.minimoEscolhas,
    required this.maximoEscolhas,
    required this.opcoes,
  });

  factory MenuOptionGroupModel.fromJson(Map<String, dynamic> json) {
    final rawOpcoes = (json['opcoes'] as List<dynamic>?) ?? const [];
    return MenuOptionGroupModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      isObrigatorio: (json['is_obrigatorio'] as bool?) ?? false,
      minimoEscolhas: (json['minimo_escolhas'] as num?)?.toInt() ?? 0,
      maximoEscolhas: (json['maximo_escolhas'] as num?)?.toInt() ?? 1,
      opcoes: rawOpcoes
          .whereType<Map<String, dynamic>>()
          .map(MenuOptionItemModel.fromJson)
          .toList(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        nome,
        isObrigatorio,
        minimoEscolhas,
        maximoEscolhas,
        opcoes,
      ];
}

/// Representa um item do menu (`ItemMenu`) (RN-014, RN-015, RN-016).
@immutable
class MenuItemModel extends Equatable {
  final String id;
  final String nome;
  final String descricao;
  final int preco; // Unidades mínimas inteiras (Cêntimos / Kwanza convertido - RN-059)
  final String imagemUrl;
  final List<String> alergenos;
  final bool isDisponivel;
  final bool isDestaque;
  final List<MenuOptionGroupModel> gruposOpcoes;

  const MenuItemModel({
    required this.id,
    required this.nome,
    required this.descricao,
    required this.preco,
    required this.imagemUrl,
    required this.alergenos,
    required this.isDisponivel,
    this.isDestaque = false,
    required this.gruposOpcoes,
  });

  static const Set<String> _staticSeedNames = {
    'Hambúrguer Artesanal Luanda Duplo',
    'Frango Grelhado no Carvão com Batata Frita',
    'Mufete Tradicional da Ilha',
    'Pizza Familiar Suprema de Luanda',
    'Pizza Familiar Suprema no Forno a Lenha',
    'Sumo Natural de Múcua / Maracujá (500ml)',
    'Pudim Caseiro de Leite Condensado',
    'Chamuças Artesanais Estaladiças (4 Unid.)',
    'Tábua de Camarão ao Alhinho & Torradas',
    'Cocktail Tropical Marginal Sunset (Sem Álcool)',
  };

  static bool isStaticSeedItemName(String nome) =>
      _staticSeedNames.contains(nome.trim());

  factory MenuItemModel.fromJson(Map<String, dynamic> json) {
    final rawAlergenos = (json['alergenos'] as List<dynamic>?) ?? const [];
    final rawGrupos = (json['grupos_opcoes'] as List<dynamic>?) ?? const [];
    final rawPreco = (json['preco'] as num?)?.toInt() ?? 0;
    final precoCentimos =
        (rawPreco > 0 && rawPreco < 50000) ? rawPreco * 100 : rawPreco;

    return MenuItemModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      descricao: (json['descricao'] as String?) ?? '',
      preco: precoCentimos,
      imagemUrl: (json['imagem_url'] as String?) ?? '',
      alergenos: rawAlergenos.map((e) => '$e').toList(),
      isDisponivel: (json['is_disponivel'] as bool?) ?? true,
      isDestaque: (json['is_destaque'] as bool?) ?? false,
      gruposOpcoes: rawGrupos
          .whereType<Map<String, dynamic>>()
          .map(MenuOptionGroupModel.fromJson)
          .toList(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        nome,
        descricao,
        preco,
        imagemUrl,
        alergenos,
        isDisponivel,
        isDestaque,
        gruposOpcoes,
      ];
}

/// Representa uma Categoria do Menu (`CategoriaItem`) com os seus itens (RN-014).
@immutable
class MenuCategoryModel extends Equatable {
  final String id;
  final String nome;
  final int ordemExibicao;
  final List<MenuItemModel> itens;

  const MenuCategoryModel({
    required this.id,
    required this.nome,
    required this.ordemExibicao,
    required this.itens,
  });

  factory MenuCategoryModel.fromJson(Map<String, dynamic> json) {
    final rawItens = (json['itens'] as List<dynamic>?) ?? const [];
    final parsedItens = rawItens
        .whereType<Map<String, dynamic>>()
        .map(MenuItemModel.fromJson)
        .where((item) => !MenuItemModel.isStaticSeedItemName(item.nome))
        .toList();
    return MenuCategoryModel(
      id: '${json['id']}',
      nome: (json['nome'] as String?) ?? '',
      ordemExibicao: (json['ordem_exibicao'] as num?)?.toInt() ?? 0,
      itens: parsedItens,
    );
  }

  @override
  List<Object?> get props => [id, nome, ordemExibicao, itens];
}

/// Modelo completo da Vitrine Digital (CMS) do Restaurante para as 5 secções do Cliente:
/// 1. Home (Identidade, Foto/Vídeo Hero, Conceito, CTAs);
/// 2. Cardápio (Categorias, Ingredientes, Preços);
/// 3. Sobre Nós (A Nossa História, Origem dos Pratos, Filosofia da Equipa, Biografia do Chef, Galeria);
/// 4. Reservas (Configuração de Mesas Online, Zonas, Horários);
/// 5. Localização e Contacto (Morada, Horário de Funcionamento, Telefone, GPS e Mensagens).
@immutable
class StorefrontVitrineModel extends Equatable {
  final String slogan;
  final String resumoConceito;
  final String heroImagemUrl;
  final String heroVideoUrl;
  final String logoUrl;
  final String corDestaqueHex;
  final bool aceitaReservas;
  final bool aceitaPedidos;
  final List<Map<String, dynamic>> pratosDestaque;

  final String tituloHistoria;
  final String historiaRestaurante;
  final String origemPratos;
  final String filosofiaEquipa;
  final String chefNome;
  final String chefTitulo;
  final String chefBiografia;
  final String chefFotoUrl;
  final List<Map<String, dynamic>> galeriaMidia;

  final int capacidadeMaximaPessoas;
  final List<String> zonasDisponiveis;
  final List<String> horariosDisponiveis;
  final String politicaReserva;

  final String moradaCompleta;
  final String pontoReferencia;
  final String telefonePrincipal;
  final String whatsapp;
  final String emailContacto;
  final String instagram;
  final String websiteUrl;
  final String gpsLinkExterno;
  final double latitude;
  final double longitude;
  final List<Map<String, dynamic>> horariosSemanal;

  const StorefrontVitrineModel({
    this.slogan = 'Sabores Autênticos & Alta Gastronomia',
    this.resumoConceito =
        'Ingredientes frescos selecionados diariamente, receitas tradicionais e técnicas contemporâneas para uma experiência memorável.',
    this.heroImagemUrl =
        'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=1200',
    this.heroVideoUrl =
        'https://assets.mixkit.co/videos/preview/mixkit-frying-meat-in-a-pan-with-spices-41876-large.mp4',
    this.logoUrl =
        'https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=400',
    this.corDestaqueHex = '#E11D48',
    this.aceitaReservas = true,
    this.aceitaPedidos = true,
    this.pratosDestaque = const [],
    this.tituloHistoria = 'A Nossa História — Tradição e Paixão',
    this.historiaRestaurante =
        'Fundado em Luanda com a missão de unir hospitalidade de excelência e gastronomia autêntica num ambiente acolhedor.',
    this.origemPratos =
        'Trabalhamos diretamente com produtores e pescadores locais para garantir frescura máxima em cada prato.',
    this.filosofiaEquipa =
        'Cozinhamos com paixão, rigor na segurança alimentar e respeito pela tradição culinária.',
    this.chefNome = 'Chef Mateus Ndombaxi',
    this.chefTitulo = 'Chef Executivo & Curador Gastronómico',
    this.chefBiografia =
        'Com mais de 15 anos de experiência em cozinha angolana e internacional, lidera a equipa com criatividade e rigor.',
    this.chefFotoUrl =
        'https://images.unsplash.com/photo-1577219491135-ce391730fb2c?w=600',
    this.galeriaMidia = const [],
    this.capacidadeMaximaPessoas = 20,
    this.zonasDisponiveis = const [
      'Salão Principal Climatizado',
      'Esplanada / Terraço Panorâmico',
      'Sala VIP Privada',
    ],
    this.horariosDisponiveis = const [
      '12:00',
      '13:00',
      '14:00',
      '19:00',
      '20:00',
      '21:00',
      '22:00',
    ],
    this.politicaReserva =
        'Tolerância de 15 minutos após o horário agendado. Para grupos grandes, preparamos a sua mesa com antecedência.',
    this.moradaCompleta = 'Luanda, Angola',
    this.pontoReferencia = 'Próximo à Marginal de Luanda',
    this.telefonePrincipal = '+244 923 000 000',
    this.whatsapp = '+244 923 000 000',
    this.emailContacto = 'reservas@restaurante-luanda.ao',
    this.instagram = '@restaurante.luanda',
    this.websiteUrl = 'https://ango-ifood.onrender.com',
    this.gpsLinkExterno = 'https://www.google.com/maps/search/?api=1&query=-8.8368,13.2343',
    this.latitude = -8.8368,
    this.longitude = 13.2343,
    this.horariosSemanal = const [],
  });

  factory StorefrontVitrineModel.fromJson(
    Map<String, dynamic>? json, {
    List<dynamic>? rawHorarios,
    String fallbackMorada = 'Luanda, Angola',
  }) {
    if (json == null) {
      return StorefrontVitrineModel(moradaCompleta: fallbackMorada);
    }
    final home = json['identidade_home'] is Map<String, dynamic>
        ? json['identidade_home'] as Map<String, dynamic>
        : <String, dynamic>{};
    final sobre = json['sobre_nos'] is Map<String, dynamic>
        ? json['sobre_nos'] as Map<String, dynamic>
        : <String, dynamic>{};
    final res = json['config_reservas'] is Map<String, dynamic>
        ? json['config_reservas'] as Map<String, dynamic>
        : <String, dynamic>{};
    final loc = json['localizacao_contacto'] is Map<String, dynamic>
        ? json['localizacao_contacto'] as Map<String, dynamic>
        : <String, dynamic>{};

    final rawDestaques = (home['pratos_destaque'] as List<dynamic>?) ?? const [];
    final rawGaleria = (sobre['galeria_midia'] as List<dynamic>?) ?? const [];
    final rawZonas = (res['zonas_disponiveis'] as List<dynamic>?) ?? const [];
    final rawSlots = (res['horarios_disponiveis'] as List<dynamic>?) ?? const [];

    return StorefrontVitrineModel(
      slogan: (home['slogan'] ?? 'Sabores Autênticos & Alta Gastronomia')
          .toString(),
      resumoConceito: (home['resumo_conceito'] ??
              'Ingredientes frescos selecionados diariamente e receitas autênticas.')
          .toString(),
      heroImagemUrl: (home['hero_imagem_url'] ??
              'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=1200')
          .toString(),
      heroVideoUrl: (home['hero_video_url'] ?? '').toString(),
      logoUrl: (home['logo_url'] ??
              'https://images.unsplash.com/photo-1555396273-367ea4eb4db5?w=400')
          .toString(),
      corDestaqueHex: (home['cor_destaque_hex'] ?? '#E11D48').toString(),
      aceitaReservas: (home['aceita_reservas'] as bool?) ?? true,
      aceitaPedidos: (home['aceita_pedidos'] as bool?) ?? true,
      pratosDestaque:
          rawDestaques.whereType<Map<String, dynamic>>().toList(),
      tituloHistoria: (sobre['titulo_historia'] ??
              'A Nossa História — Tradição e Paixão')
          .toString(),
      historiaRestaurante: (sobre['historia_restaurante'] ?? '').toString(),
      origemPratos: (sobre['origem_pratos'] ?? '').toString(),
      filosofiaEquipa: (sobre['filosofia_equipa'] ?? '').toString(),
      chefNome: (sobre['chef_nome'] ?? 'Chef Executivo').toString(),
      chefTitulo:
          (sobre['chef_titulo'] ?? 'Curador Gastronómico').toString(),
      chefBiografia: (sobre['chef_biografia'] ?? '').toString(),
      chefFotoUrl: (sobre['chef_foto_url'] ??
              'https://images.unsplash.com/photo-1577219491135-ce391730fb2c?w=600')
          .toString(),
      galeriaMidia: rawGaleria.whereType<Map<String, dynamic>>().toList(),
      capacidadeMaximaPessoas:
          (res['capacidade_maxima_pessoas'] as num?)?.toInt() ?? 20,
      zonasDisponiveis: rawZonas.isNotEmpty
          ? rawZonas.map((e) => e.toString()).toList()
          : const [
              'Salão Principal Climatizado',
              'Esplanada / Terraço Panorâmico',
              'Sala VIP Privada',
            ],
      horariosDisponiveis: rawSlots.isNotEmpty
          ? rawSlots.map((e) => e.toString()).toList()
          : const ['12:00', '13:00', '14:00', '19:00', '20:00', '21:00'],
      politicaReserva: (res['politica_reserva'] ??
              'Tolerância de 15 minutos após o horário agendado.')
          .toString(),
      moradaCompleta:
          (loc['morada_completa'] ?? fallbackMorada).toString(),
      pontoReferencia: (loc['ponto_referencia'] ?? '').toString(),
      telefonePrincipal:
          (loc['telefone_principal'] ?? '+244 923 000 000').toString(),
      whatsapp: (loc['whatsapp'] ?? '+244 923 000 000').toString(),
      emailContacto:
          (loc['email_contacto'] ?? 'contacto@restaurante.ao').toString(),
      instagram: (loc['instagram'] ?? '@restaurante.luanda').toString(),
      websiteUrl: (loc['website_url'] ?? '').toString(),
      gpsLinkExterno: (loc['gps_link_externo'] ?? '').toString(),
      latitude: (loc['latitude'] as num?)?.toDouble() ?? -8.8368,
      longitude: (loc['longitude'] as num?)?.toDouble() ?? 13.2343,
      horariosSemanal: ((rawHorarios != null && rawHorarios.isNotEmpty)
              ? rawHorarios
              : ((loc['horarios'] as List<dynamic>?) ??
                  (json['horarios'] as List<dynamic>?) ??
                  const []))
          .whereType<Map<String, dynamic>>()
          .toList(),
    );
  }

  @override
  List<Object?> get props => [
        slogan,
        resumoConceito,
        heroImagemUrl,
        heroVideoUrl,
        logoUrl,
        aceitaReservas,
        aceitaPedidos,
        tituloHistoria,
        historiaRestaurante,
        chefNome,
        moradaCompleta,
        telefonePrincipal,
      ];
}

/// Formata valores monetários inteiros (unidades mínimas — RN-059) para exibição ao cliente.
String formatarMoedaUnidadesMinimas(int valorInteiro, {String simbolo = 'Kz'}) {
  final valorReal = valorInteiro / 100.0;
  return '${valorReal.toStringAsFixed(2)} $simbolo';
}

// ============================================================================
// 2. REPOSITÓRIO DE CATÁLOGO E DESCOBERTA COM DIO (CatalogRepository)
// ============================================================================

class CatalogRepository {
  final Dio _dio;

  CatalogRepository({
    Dio? dio,
    String baseUrl = AppEnvironmentConfig.baseHttpUrl,
  }) : _dio = dio ??
            createSecureDioClient(
              tokenStorage: SecureTokenStorage(),
            );

  /// RN-025 / RN-026 / RN-027 / RN-028: Carrega a lista de lojas para as coordenadas do cliente
  /// a partir do endpoint `GET /api/v1/catalog/stores/`.
  Future<List<StoreSummaryModel>> fetchStores({
    required double lat,
    required double lng,
    bool incluirFechadas = true,
    String? query,
    double? scoreMin,
  }) async {
    final queryParams = <String, dynamic>{
      'lat': lat,
      'lng': lng,
      'incluir_fechadas': incluirFechadas,
    };
    if (query != null && query.trim().isNotEmpty) {
      queryParams['q'] = query.trim();
    }
    if (scoreMin != null) {
      queryParams['score_min'] = scoreMin;
    }

    final response = await _dio.get<dynamic>(
      '/api/v1/catalog/stores/',
      queryParameters: queryParams,
    );

    final data = response.data;
    if (data == null) return const [];

    List<dynamic> results = const [];
    if (data is Map<String, dynamic>) {
      results = (data['results'] as List<dynamic>?) ?? const [];
    } else if (data is List<dynamic>) {
      results = data;
    }

    return results
        .whereType<Map<String, dynamic>>()
        .map(StoreSummaryModel.fromJson)
        .toList();
  }

  /// RN-014 / RN-015: Carrega as categorias e itens do menu de uma loja específica
  /// a partir do endpoint `GET /api/v1/catalog/stores/<storeId>/menu/`.
  Future<List<MenuCategoryModel>> fetchStoreMenu(String storeId) async {
    final exp = await fetchStoreExperience(storeId);
    return exp.categories;
  }

  /// Carrega simultaneamente as categorias do Cardápio e a Vitrine Digital (CMS)
  /// completa da loja (`Home`, `Sobre Nós`, `Reservas`, `Localização e Contacto`).
  Future<({List<MenuCategoryModel> categories, StorefrontVitrineModel vitrine})>
      fetchStoreExperience(String storeId) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/catalog/stores/$storeId/menu/',
    );

    final data = response.data;
    if (data == null) {
      return (
        categories: const <MenuCategoryModel>[],
        vitrine: const StorefrontVitrineModel(),
      );
    }

    final rawCategories = (data['categorias'] as List<dynamic>?) ?? const [];
    final categories = rawCategories
        .whereType<Map<String, dynamic>>()
        .map(MenuCategoryModel.fromJson)
        .toList();

    final vitrineMap = data['vitrine'] is Map<String, dynamic>
        ? data['vitrine'] as Map<String, dynamic>
        : null;
    final rawHorarios = data['horarios'] as List<dynamic>?;
    final fallbackMorada = (data['morada_texto'] ?? 'Luanda, Angola').toString();

    return (
      categories: categories,
      vitrine: StorefrontVitrineModel.fromJson(
        vitrineMap,
        rawHorarios: rawHorarios,
        fallbackMorada: fallbackMorada,
      ),
    );
  }

  /// Envia um pedido de Reserva de Mesa Online para a loja (`POST /api/v1/catalog/stores/<id>/reservations/`).
  Future<Map<String, dynamic>> submitTableReservation({
    required String storeId,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/catalog/stores/$storeId/reservations/',
      data: payload,
    );
    return response.data ?? <String, dynamic>{};
  }

  /// Envia uma mensagem de contacto do cliente para a gerência da loja (`POST /api/v1/catalog/stores/<id>/messages/`).
  Future<Map<String, dynamic>> submitStoreContactMessage({
    required String storeId,
    required Map<String, dynamic> payload,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/catalog/stores/$storeId/messages/',
      data: payload,
    );
    return response.data ?? <String, dynamic>{};
  }
}

// ============================================================================
// 3. BLOC DE DESCOBERTA DE LOJAS E FILTROS (StoreDiscoveryBloc - RN-028)
// ============================================================================

@immutable
sealed class StoreDiscoveryEvent extends Equatable {
  const StoreDiscoveryEvent();

  @override
  List<Object?> get props => [];
}

final class LoadStoresForLocationEvent extends StoreDiscoveryEvent {
  final CustomerGeoAddress address;
  final String? selectedCuisine;
  final double? minRating;
  final bool onlyFreeDelivery;
  final String searchQuery;

  const LoadStoresForLocationEvent({
    required this.address,
    this.selectedCuisine,
    this.minRating,
    this.onlyFreeDelivery = false,
    this.searchQuery = '',
  });

  @override
  List<Object?> get props => [
        address,
        selectedCuisine,
        minRating,
        onlyFreeDelivery,
        searchQuery,
      ];
}

@immutable
sealed class StoreDiscoveryState extends Equatable {
  final CustomerGeoAddress currentAddress;
  final String? selectedCuisine;
  final double? minRating;
  final bool onlyFreeDelivery;
  final String searchQuery;

  const StoreDiscoveryState({
    required this.currentAddress,
    this.selectedCuisine,
    this.minRating,
    this.onlyFreeDelivery = false,
    this.searchQuery = '',
  });

  @override
  List<Object?> get props => [
        currentAddress,
        selectedCuisine,
        minRating,
        onlyFreeDelivery,
        searchQuery,
      ];
}

final class StoreDiscoveryLoading extends StoreDiscoveryState {
  const StoreDiscoveryLoading({
    required super.currentAddress,
    super.selectedCuisine,
    super.minRating,
    super.onlyFreeDelivery,
    super.searchQuery,
  });
}

final class StoreDiscoveryLoaded extends StoreDiscoveryState {
  final List<StoreSummaryModel> stores;

  const StoreDiscoveryLoaded({
    required this.stores,
    required super.currentAddress,
    super.selectedCuisine,
    super.minRating,
    super.onlyFreeDelivery,
    super.searchQuery,
  });

  @override
  List<Object?> get props => [...super.props, stores];
}

final class StoreDiscoveryError extends StoreDiscoveryState {
  final String message;

  const StoreDiscoveryError({
    required this.message,
    required super.currentAddress,
    super.selectedCuisine,
    super.minRating,
    super.onlyFreeDelivery,
    super.searchQuery,
  });

  @override
  List<Object?> get props => [...super.props, message];
}

class StoreDiscoveryBloc
    extends Bloc<StoreDiscoveryEvent, StoreDiscoveryState> {
  final CatalogRepository _repository;

  StoreDiscoveryBloc({
    required CatalogRepository repository,
    required CustomerGeoAddress initialAddress,
  })  : _repository = repository,
        super(StoreDiscoveryLoading(currentAddress: initialAddress)) {
    on<LoadStoresForLocationEvent>(_onLoadStores);
  }

  Future<void> _onLoadStores(
    LoadStoresForLocationEvent event,
    Emitter<StoreDiscoveryState> emit,
  ) async {
    emit(
      StoreDiscoveryLoading(
        currentAddress: event.address,
        selectedCuisine: event.selectedCuisine,
        minRating: event.minRating,
        onlyFreeDelivery: event.onlyFreeDelivery,
        searchQuery: event.searchQuery,
      ),
    );

    try {
      final combinedQuery = [
        if (event.selectedCuisine != null && event.selectedCuisine!.isNotEmpty)
          event.selectedCuisine!,
        if (event.searchQuery.trim().isNotEmpty) event.searchQuery.trim(),
      ].join(' ');

      var stores = await _repository.fetchStores(
        lat: event.address.latitude,
        lng: event.address.longitude,
        incluirFechadas: true,
        query: combinedQuery.isEmpty ? null : combinedQuery,
        scoreMin: event.minRating,
      );

      // Filtro RN-028: Entrega Grátis
      if (event.onlyFreeDelivery) {
        stores = stores.where((s) => s.isEntregaGratis).toList();
      }

      emit(
        StoreDiscoveryLoaded(
          stores: stores,
          currentAddress: event.address,
          selectedCuisine: event.selectedCuisine,
          minRating: event.minRating,
          onlyFreeDelivery: event.onlyFreeDelivery,
          searchQuery: event.searchQuery,
        ),
      );
    } on DioException catch (e) {
      emit(
        StoreDiscoveryError(
          message:
              'Não foi possível carregar as lojas na sua zona (${e.response?.statusCode ?? 'Erro de Rede'}).',
          currentAddress: event.address,
          selectedCuisine: event.selectedCuisine,
          minRating: event.minRating,
          onlyFreeDelivery: event.onlyFreeDelivery,
          searchQuery: event.searchQuery,
        ),
      );
    } catch (e) {
      emit(
        StoreDiscoveryError(
          message: 'Erro inesperado ao carregar catálogo: $e',
          currentAddress: event.address,
          selectedCuisine: event.selectedCuisine,
          minRating: event.minRating,
          onlyFreeDelivery: event.onlyFreeDelivery,
          searchQuery: event.searchQuery,
        ),
      );
    }
  }
}

// ============================================================================
// 4. BLOC DE MENU DA LOJA E CARRINHO (StoreMenuBloc - RN-014, RN-015, RN-040)
// ============================================================================

@immutable
sealed class StoreMenuEvent extends Equatable {
  const StoreMenuEvent();

  @override
  List<Object?> get props => [];
}

final class LoadStoreMenuEvent extends StoreMenuEvent {
  final String storeId;

  const LoadStoreMenuEvent({required this.storeId});

  @override
  List<Object?> get props => [storeId];
}

final class AddMenuItemToCartEvent extends StoreMenuEvent {
  final MenuItemModel item;

  const AddMenuItemToCartEvent({required this.item});

  @override
  List<Object?> get props => [item];
}

@immutable
sealed class StoreMenuState extends Equatable {
  const StoreMenuState();

  @override
  List<Object?> get props => [];
}

final class StoreMenuLoading extends StoreMenuState {
  const StoreMenuLoading();
}

final class StoreMenuLoaded extends StoreMenuState {
  final List<MenuCategoryModel> categories;
  final StorefrontVitrineModel vitrine;
  final Map<String, int> cartQuantities;
  final int cartSubtotalCentimos;

  const StoreMenuLoaded({
    required this.categories,
    this.vitrine = const StorefrontVitrineModel(),
    this.cartQuantities = const {},
    this.cartSubtotalCentimos = 0,
  });

  int get totalCartItems =>
      cartQuantities.values.fold(0, (acc, qty) => acc + qty);

  @override
  List<Object?> get props => [
        categories,
        vitrine,
        cartQuantities,
        cartSubtotalCentimos,
      ];
}

final class StoreMenuError extends StoreMenuState {
  final String message;

  const StoreMenuError({required this.message});

  @override
  List<Object?> get props => [message];
}

class StoreMenuBloc extends Bloc<StoreMenuEvent, StoreMenuState> {
  final CatalogRepository _repository;

  StoreMenuBloc({required CatalogRepository repository})
      : _repository = repository,
        super(const StoreMenuLoading()) {
    on<LoadStoreMenuEvent>(_onLoadStoreMenu);
    on<AddMenuItemToCartEvent>(_onAddMenuItemToCart);
  }

  Future<void> _onLoadStoreMenu(
    LoadStoreMenuEvent event,
    Emitter<StoreMenuState> emit,
  ) async {
    emit(const StoreMenuLoading());
    try {
      final exp = await _repository.fetchStoreExperience(event.storeId);
      emit(
        StoreMenuLoaded(
          categories: exp.categories,
          vitrine: exp.vitrine,
        ),
      );
    } catch (e) {
      final friendlyMsg = (e is DioException && (e.response?.statusCode == 500 || e.response?.statusCode == 502 || e.response?.statusCode == 503))
          ? 'O restaurante está a sincronizar os pratos e a vitrine. Por favor, toque no botão abaixo para recarregar.'
          : 'Não foi possível carregar o cardápio da loja. Por favor, verifique a ligação e tente novamente.';
      emit(
        StoreMenuError(
          message: friendlyMsg,
        ),
      );
    }
  }

  void _onAddMenuItemToCart(
    AddMenuItemToCartEvent event,
    Emitter<StoreMenuState> emit,
  ) {
    // RN-015: Bloqueio estrito no nível de domínio caso o item esteja indisponível
    if (!event.item.isDisponivel) return;

    final currentState = state;
    if (currentState is! StoreMenuLoaded) return;

    final updatedQuantities = Map<String, int>.from(currentState.cartQuantities);
    updatedQuantities[event.item.id] =
        (updatedQuantities[event.item.id] ?? 0) + 1;

    emit(
      StoreMenuLoaded(
        categories: currentState.categories,
        vitrine: currentState.vitrine,
        cartQuantities: updatedQuantities,
        cartSubtotalCentimos:
            currentState.cartSubtotalCentimos + event.item.preco,
      ),
    );
  }
}

// ============================================================================
// 5. ECRÃ 1: HomeScreen (Descoberta, Morada Geolocalizada e Filtros RN-028)
// ============================================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _searchController = TextEditingController();

  static const List<String> _cuisines = [
    'Hambúrgueres',
    'Pizza',
    'Tradicional',
    'Sushi',
    'Mercearia',
    'Farmácia',
  ];

  @override
  void initState() {
    super.initState();
    _syncDefaultAddressFromBackend();
  }

  Future<void> _syncDefaultAddressFromBackend() async {
    try {
      var token = await SecureTokenStorage().getAccessToken();
      if ((token == null || token.isEmpty) && mounted) {
        try {
          final authState = context.read<AuthBloc>().state;
          if (authState is Authenticated && authState.tokens.accessToken.isNotEmpty) {
            token = authState.tokens.accessToken;
            await SecureTokenStorage().saveTokens(
              accessToken: authState.tokens.accessToken,
              refreshToken: authState.tokens.refreshToken,
              userRole: authState.user.tipoUtilizador,
            );
          }
        } catch (_) {}
      }
      if (token == null || token.isEmpty) return;

      final dio = createSecureDioClient(tokenStorage: SecureTokenStorage());
      final resp = await dio.get<dynamic>(
        '/api/v1/auth/moradas/',
      );
      final rawData = resp.data;
      List<dynamic> list = const [];
      if (rawData is List) {
        list = rawData;
      } else if (rawData is Map<String, dynamic> && rawData['results'] is List) {
        list = rawData['results'] as List<dynamic>;
      }
      if (list.isNotEmpty && list.first is Map<String, dynamic>) {
        final addr = CustomerGeoAddress.fromMoradaJson(
          list.first as Map<String, dynamic>,
        );
        CartService.instance.updateActiveAddress(
          id: addr.id,
          label: addr.label,
          fullAddress: addr.fullAddress,
          referencia: addr.referencia,
          latitude: addr.latitude,
          longitude: addr.longitude,
        );
        if (mounted) {
          final currentState = context.read<StoreDiscoveryBloc>().state;
          _dispatchFilterUpdate(currentState, address: addr);
        }
      }
    } catch (_) {
      // Mantém morada inicial em caso de falha silenciosa
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _dispatchFilterUpdate(
    StoreDiscoveryState state, {
    CustomerGeoAddress? address,
    String? cuisine,
    bool clearCuisine = false,
    double? minRating,
    bool clearMinRating = false,
    bool? onlyFreeDelivery,
    String? searchQuery,
  }) {
    context.read<StoreDiscoveryBloc>().add(
          LoadStoresForLocationEvent(
            address: address ?? state.currentAddress,
            selectedCuisine:
                clearCuisine ? null : (cuisine ?? state.selectedCuisine),
            minRating:
                clearMinRating ? null : (minRating ?? state.minRating),
            onlyFreeDelivery: onlyFreeDelivery ?? state.onlyFreeDelivery,
            searchQuery: searchQuery ?? state.searchQuery,
          ),
        );
  }

  /// Abre o modal de Filtros Avançados (Cozinha, Avaliação, Entrega Grátis - RN-028).
  void _openFilterBottomSheet(BuildContext context, StoreDiscoveryState state) {
    String? tempCuisine = state.selectedCuisine;
    double? tempMinRating = state.minRating;
    bool tempFreeDelivery = state.onlyFreeDelivery;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Filtros de Descoberta',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tipo de Cozinha / Categoria',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _cuisines.map((cuisine) {
                      final isSelected = tempCuisine == cuisine;
                      return ChoiceChip(
                        label: Text(cuisine),
                        selected: isSelected,
                        onSelected: (selected) {
                          setModalState(() {
                            tempCuisine = selected ? cuisine : null;
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Apenas Entrega Grátis'),
                    subtitle: const Text('Mostrar lojas sem taxa de entrega'),
                    value: tempFreeDelivery,
                    onChanged: (v) => setModalState(() => tempFreeDelivery = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Avaliação 4.5+ ★'),
                    subtitle: const Text('Parceiros com excelente reputação'),
                    value: (tempMinRating ?? 0) >= 4.5,
                    onChanged: (v) =>
                        setModalState(() => tempMinRating = v ? 4.5 : null),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      _dispatchFilterUpdate(
                        state,
                        cuisine: tempCuisine,
                        clearCuisine: tempCuisine == null,
                        minRating: tempMinRating,
                        clearMinRating: tempMinRating == null,
                        onlyFreeDelivery: tempFreeDelivery,
                      );
                    },
                    child: const Text('Aplicar Filtros'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return BlocListener<AuthBloc, AuthState>(
      listener: (context, authState) {
        if (authState is Authenticated) {
          _syncDefaultAddressFromBackend();
        }
      },
      child: BlocBuilder<StoreDiscoveryBloc, StoreDiscoveryState>(
        builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                showCustomerAddressSelectionSheet(
                  context,
                  currentAddress: state.currentAddress,
                  onAddressSelected: (newAddr) {
                    _dispatchFilterUpdate(state, address: newAddr);
                  },
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.location_on_rounded,
                        size: 20,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  'Entregar em • ${state.currentAddress.label}',
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelMedium?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 16,
                                color: colorScheme.primary,
                              ),
                            ],
                          ),
                          Text(
                            state.currentAddress.fullAddress,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              // Botão de Filtros (RN-028)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: IconButton.filledTonal(
                  tooltip: 'Filtros (Cozinha, Avaliação, Entrega Grátis)',
                  onPressed: () => _openFilterBottomSheet(context, state),
                  icon: const Icon(Icons.tune_rounded),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              // Barra de pesquisa e chips rápidos de filtro (RN-028)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _searchController,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (query) =>
                      _dispatchFilterUpdate(state, searchQuery: query),
                  decoration: InputDecoration(
                    hintText: 'Pesquisar lojas, pratos ou categorias...',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded),
                            onPressed: () {
                              _searchController.clear();
                              _dispatchFilterUpdate(state, searchQuery: '');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    FilterChip(
                      avatar: const Icon(Icons.local_shipping_outlined, size: 18),
                      label: const Text('Entrega Grátis'),
                      selected: state.onlyFreeDelivery,
                      onSelected: (selected) => _dispatchFilterUpdate(
                        state,
                        onlyFreeDelivery: selected,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      avatar: const Icon(Icons.star_rounded, size: 18),
                      label: const Text('Avaliação 4.5+'),
                      selected: (state.minRating ?? 0) >= 4.5,
                      onSelected: (selected) => _dispatchFilterUpdate(
                        state,
                        minRating: selected ? 4.5 : null,
                        clearMinRating: !selected,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ..._cuisines.map((cuisine) {
                      final isSelected = state.selectedCuisine == cuisine;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(cuisine),
                          selected: isSelected,
                          onSelected: (selected) => _dispatchFilterUpdate(
                            state,
                            cuisine: selected ? cuisine : null,
                            clearCuisine: !selected,
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Lista Vertical de Lojas em Cards Dinâmicos (RN-025, RN-026, RN-027, RN-029)
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (state is StoreDiscoveryLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (state is StoreDiscoveryError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.wifi_off_rounded,
                                size: 48,
                                color: colorScheme.error,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                state.message,
                                textAlign: TextAlign.center,
                                style: textTheme.bodyLarge,
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () => _dispatchFilterUpdate(state),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Tentar Novamente'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    if (state is StoreDiscoveryLoaded) {
                      if (state.stores.isEmpty) {
                        final hasActiveFilters = state.selectedCuisine != null ||
                            state.minRating != null ||
                            state.onlyFreeDelivery ||
                            state.searchQuery.trim().isNotEmpty;
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.storefront_outlined,
                                  size: 56,
                                  color: colorScheme.outline,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Nenhuma loja encontrada com cobertura para esta morada ou filtros selecionados.',
                                  textAlign: TextAlign.center,
                                  style: textTheme.bodyLarge?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                if (hasActiveFilters) ...[
                                  const SizedBox(height: 16),
                                  FilledButton.tonalIcon(
                                    onPressed: () {
                                      _searchController.clear();
                                      _dispatchFilterUpdate(
                                        state,
                                        clearCuisine: true,
                                        clearMinRating: true,
                                        onlyFreeDelivery: false,
                                        searchQuery: '',
                                      );
                                    },
                                    icon: const Icon(
                                        Icons.filter_alt_off_rounded),
                                    label: const Text('Limpar Filtros'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      }

                      return RefreshIndicator(
                        onRefresh: () async => _dispatchFilterUpdate(state),
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          itemCount: state.stores.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 16),
                          itemBuilder: (context, index) {
                            final store = state.stores[index];
                            return _StoreDiscoveryCard(
                              store: store,
                              onTap: () {
                                CatalogRepository repo;
                                try {
                                  repo = context.read<CatalogRepository>();
                                } catch (_) {
                                  repo = CatalogRepository(
                                    baseUrl: AppEnvironmentConfig.baseHttpUrl,
                                  );
                                }
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        RepositoryProvider<CatalogRepository>.value(
                                      value: repo,
                                      child: BlocProvider(
                                        create: (_) => StoreMenuBloc(
                                          repository: repo,
                                        )..add(
                                            LoadStoreMenuEvent(storeId: store.id),
                                          ),
                                        child: StoreMenuScreen(store: store),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          ),
        );
      },
    ),
    );
  }
}

/// Card dinâmico de Loja exibindo imagem, nome, ETA, taxa de entrega, patrocinado e badge de Fechada (RN-026, RN-027, RN-029).
class _StoreDiscoveryCard extends StatelessWidget {
  final StoreSummaryModel store;
  final VoidCallback onTap;

  const _StoreDiscoveryCard({
    required this.store,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: store.isAberta ? 2 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Imagem de capa com badges sobrepostos (Fechada RN-026 / Patrocinado RN-027 / ETA RN-029)
            Stack(
              children: [
                ColorFiltered(
                  colorFilter: store.isAberta
                      ? const ColorFilter.mode(
                          Colors.transparent,
                          BlendMode.multiply,
                        )
                      : const ColorFilter.matrix(<double>[
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0.2126, 0.7152, 0.0722, 0, 0,
                          0,      0,      0,      1, 0,
                        ]),
                  child: AspectRatio(
                    aspectRatio: 16 / 8,
                    child: AngoNetworkImage(
                      imageUrl: store.imagemUrl,
                      fit: BoxFit.cover,
                      fallbackIcon: Icons.storefront_rounded,
                    ),
                  ),
                ),

                // Etiqueta transparente de Conteúdo Patrocinado (RN-027 / RN-062)
                if (store.isPatrocinado)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.75),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        store.etiquetaPatrocinado ?? 'Patrocinado',
                        style: textTheme.labelSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                // Badge indicativo se a loja estiver Fechada (RN-026)
                if (!store.isAberta)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 16,
                            color: colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            store.proximoHorarioAbertura != null
                                ? 'Fechada • Abre ${store.proximoHorarioAbertura}'
                                : 'Fechada no momento',
                            style: textTheme.labelMedium?.copyWith(
                              color: colorScheme.onErrorContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Chip de ETA Estimada (RN-029)
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 16,
                          color: colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${store.etaMinutosEstimado}-${store.etaMinutosEstimado + 10} min',
                          style: textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // Detalhes da Loja (Nome, Score de Reputação, Distância e Taxa de Entrega)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          store.nome,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 16,
                              color: colorScheme.onPrimaryContainer,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              store.scoreReputacao.toStringAsFixed(1),
                              style: textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.delivery_dining_rounded,
                        size: 18,
                        color: store.isEntregaGratis
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        store.isEntregaGratis
                            ? 'Entrega Grátis'
                            : 'Taxa: ${formatarMoedaUnidadesMinimas(store.taxaEntregaCentimos)}',
                        style: textTheme.bodyMedium?.copyWith(
                          color: store.isEntregaGratis
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                          fontWeight: store.isEntregaGratis
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '• ${store.distanciaKm.toStringAsFixed(1)} km',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 6. ECRÃ 2: StoreMenuScreen — Experiência Completa da Loja em 5 Secções:
//    1. Página Inicial (Home)
//    2. Cardápio (Menu)
//    3. Sobre Nós (A Nossa História & Chef)
//    4. Reservas (Agendamento de Mesa Online)
//    5. Localização e Contacto (Morada, Horários, GPS e Formulário de Mensagens)
// ============================================================================

class StoreMenuScreen extends StatefulWidget {
  final StoreSummaryModel store;

  const StoreMenuScreen({
    super.key,
    required this.store,
  });

  @override
  State<StoreMenuScreen> createState() => _StoreMenuScreenState();
}

class _StoreMenuScreenState extends State<StoreMenuScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _sectionTabController;
  String? _selectedMenuCategoryId;
  String _menuSearchQuery = '';
  final TextEditingController _menuSearchCtrl = TextEditingController();

  // Estado do Formulário de Reserva de Mesa (Secção 4)
  DateTime _reservationDate = DateTime.now().add(const Duration(days: 1));
  String _reservationTime = '20:00';
  int _reservationGuests = 2;
  String _reservationZone = 'Salão Principal Climatizado';
  final TextEditingController _resNameCtrl = TextEditingController();
  final TextEditingController _resPhoneCtrl = TextEditingController();
  final TextEditingController _resNotesCtrl = TextEditingController();
  bool _isSubmittingReservation = false;
  Map<String, dynamic>? _confirmedReservation;

  // Estado do Formulário de Mensagens Diretas (Secção 5)
  final TextEditingController _msgNameCtrl = TextEditingController();
  final TextEditingController _msgContactCtrl = TextEditingController();
  final TextEditingController _msgSubjectCtrl = TextEditingController();
  final TextEditingController _msgBodyCtrl = TextEditingController();
  bool _isSendingMessage = false;

  @override
  void initState() {
    super.initState();
    _sectionTabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _sectionTabController.dispose();
    _menuSearchCtrl.dispose();
    _resNameCtrl.dispose();
    _resPhoneCtrl.dispose();
    _resNotesCtrl.dispose();
    _msgNameCtrl.dispose();
    _msgContactCtrl.dispose();
    _msgSubjectCtrl.dispose();
    _msgBodyCtrl.dispose();
    super.dispose();
  }

  CatalogRepository _getCatalogRepository() {
    try {
      return context.read<CatalogRepository>();
    } catch (_) {
      return CatalogRepository(baseUrl: AppEnvironmentConfig.baseHttpUrl);
    }
  }

  void _navigateToSection(int tabIndex) {
    _sectionTabController.animateTo(tabIndex);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final store = widget.store;

    return AnimatedBuilder(
      animation: CartService.instance,
      builder: (context, _) {
        final cart = CartService.instance;
        final isThisStoreCart = cart.lojaId == store.id && cart.isNotEmpty;

        return BlocBuilder<StoreMenuBloc, StoreMenuState>(
          builder: (context, state) {
            if (state is StoreMenuLoading) {
              return Scaffold(
                appBar: AppBar(title: Text(store.nome)),
                body: const Center(child: CircularProgressIndicator()),
              );
            }

            if (state is StoreMenuError) {
              return Scaffold(
                appBar: AppBar(title: Text(store.nome)),
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(state.message, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => context
                              .read<StoreMenuBloc>()
                              .add(LoadStoreMenuEvent(storeId: store.id)),
                          child: const Text('Recarregar Loja'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            final loadedState = state as StoreMenuLoaded;
            final categories = loadedState.categories;
            final vitrine = loadedState.vitrine;
            final heroBannerUrl = vitrine.heroImagemUrl.isNotEmpty
                ? vitrine.heroImagemUrl
                : store.imagemUrl;

            return Scaffold(
              body: NestedScrollView(
                headerSliverBuilder: (context, innerBoxIsScrolled) {
                  return [
                    SliverAppBar(
                      expandedHeight: 245,
                      pinned: true,
                      stretch: true,
                      title: Text(
                        store.nome,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                          tooltip: 'Atualizar Cardápio e Vitrine',
                          onPressed: () {
                            context
                                .read<StoreMenuBloc>()
                                .add(LoadStoreMenuEvent(storeId: store.id));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('A atualizar cardápio e vitrine em tempo real...'),
                                duration: Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                        ),
                        if (vitrine.heroVideoUrl.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(
                                Icons.play_circle_fill_rounded,
                                color: Colors.redAccent,
                                size: 18,
                              ),
                              label: const Text(
                                'Vídeo da Casa',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              onPressed: () => _showMediaViewerModal(
                                context,
                                title: 'Vídeo em Destaque — ${store.nome}',
                                mediaUrl: vitrine.heroVideoUrl,
                                fallbackImageUrl: heroBannerUrl,
                                isVideo: true,
                                subtitle: vitrine.slogan,
                              ),
                            ),
                          ),
                      ],
                      flexibleSpace: FlexibleSpaceBar(
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            AngoNetworkImage(
                              imageUrl: heroBannerUrl,
                              fit: BoxFit.cover,
                              fallbackIcon: Icons.restaurant_rounded,
                            ),
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black38,
                                    Colors.transparent,
                                    Colors.black87,
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              left: 16,
                              bottom: 60,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: store.isAberta
                                      ? const Color(0xFF16A34A)
                                      : Colors.redAccent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  store.isAberta ? 'Aberto' : 'Fechado',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      bottom: PreferredSize(
                        preferredSize: const Size.fromHeight(50),
                        child: Container(
                          color: colorScheme.surface,
                          child: TabBar(
                            controller: _sectionTabController,
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            labelColor: colorScheme.primary,
                            unselectedLabelColor: colorScheme.onSurfaceVariant,
                            indicatorColor: colorScheme.primary,
                            indicatorWeight: 3,
                            labelStyle: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                            tabs: const [
                              Tab(
                                icon: Icon(Icons.home_rounded, size: 18),
                                text: 'Página Inicial',
                              ),
                              Tab(
                                icon: Icon(Icons.restaurant_menu_rounded, size: 18),
                                text: 'Cardápio',
                              ),
                              Tab(
                                icon: Icon(Icons.auto_stories_rounded, size: 18),
                                text: 'Sobre Nós',
                              ),
                              Tab(
                                icon: Icon(Icons.event_seat_rounded, size: 18),
                                text: 'Reservas',
                              ),
                              Tab(
                                icon: Icon(Icons.location_on_rounded, size: 18),
                                text: 'Localização & Contato',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ];
                },
                body: TabBarView(
                  controller: _sectionTabController,
                  children: [
                    // 1. PÁGINA INICIAL (HOME)
                    _buildHomeTab(
                      context,
                      store: store,
                      vitrine: vitrine,
                      categories: categories,
                    ),

                    // 2. CARDÁPIO (MENU)
                    _buildMenuTab(
                      context,
                      store: store,
                      categories: categories,
                      isThisStoreCart: isThisStoreCart,
                      cart: cart,
                    ),

                    // 3. SOBRE NÓS (A NOSSA HISTÓRIA & CHEF)
                    _buildAboutUsTab(
                      context,
                      store: store,
                      vitrine: vitrine,
                    ),

                    // 4. RESERVAS (AGENDAMENTO DE MESA ONLINE)
                    _buildReservationsTab(
                      context,
                      store: store,
                      vitrine: vitrine,
                    ),

                    // 5. LOCALIZAÇÃO E CONTATO (MORADA, HORÁRIOS, GPS E MENSAGENS)
                    _buildLocationAndContactTab(
                      context,
                      store: store,
                      vitrine: vitrine,
                    ),
                  ],
                ),
              ),

              // Barra inferior de resumo do carrinho (RN-040)
              bottomNavigationBar: isThisStoreCart
                  ? SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => CheckoutScreen(
                                  lojaId: store.id,
                                  lojaNome: store.nome,
                                  moradaId: cart.moradaId,
                                  moradaLabel: cart.moradaLabel,
                                  moradaTexto: cart.moradaTexto,
                                  itensCarrinho: cart.toCheckoutInputs(),
                                ),
                              ),
                            );
                          },
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '${cart.totalItemsCount} item(ns) • Ver Pedido',
                              ),
                              Text(
                                formatarMoedaUnidadesMinimas(
                                  cart.totalSubtotalCentimos,
                                ),
                                style: textTheme.titleMedium?.copyWith(
                                  color: colorScheme.onPrimary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : null,
            );
          },
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // SECÇÃO 1: PÁGINA INICIAL (HOME)
  // --------------------------------------------------------------------------
  Widget _buildHomeTab(
    BuildContext context, {
    required StoreSummaryModel store,
    required StorefrontVitrineModel vitrine,
    required List<MenuCategoryModel> categories,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final allItems = categories.expand((c) => c.itens).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        // 1. Cartão de Identidade Visual & Conceito do Restaurante
        Card(
          elevation: 0,
          color: colorScheme.primaryContainer.withOpacity(0.35),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: colorScheme.primary.withOpacity(0.2)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AngoNetworkImage(
                      imageUrl: vitrine.logoUrl,
                      width: 58,
                      height: 58,
                      borderRadius: BorderRadius.circular(14),
                      fit: BoxFit.cover,
                      fallbackIcon: Icons.restaurant_rounded,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            vitrine.slogan,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                color: Colors.amber,
                                size: 18,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${store.scoreReputacao.toStringAsFixed(1)} • ${store.etaMinutosEstimado} min • ${store.distanciaKm.toStringAsFixed(1)} km',
                                style: textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  vitrine.resumoConceito,
                  style: textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),

                // Botões Diretos para Pedidos e Reservas
                Row(
                  children: [
                    if (vitrine.aceitaPedidos)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _navigateToSection(1),
                          icon: const Icon(Icons.shopping_bag_rounded),
                          label: const Text('Fazer Pedido'),
                        ),
                      ),
                    if (vitrine.aceitaPedidos && vitrine.aceitaReservas)
                      const SizedBox(width: 10),
                    if (vitrine.aceitaReservas)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _navigateToSection(3),
                          icon: const Icon(Icons.event_seat_rounded),
                          label: const Text('Reservar Mesa'),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 20),

        // 2. Fotografia ou Vídeo de Destaque dos Pratos Principais
        Text(
          'Vídeo & Destaque Gastronómico',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _showMediaViewerModal(
            context,
            title: 'Experiência Gastronómica — ${store.nome}',
            mediaUrl: vitrine.heroVideoUrl.isNotEmpty
                ? vitrine.heroVideoUrl
                : vitrine.heroImagemUrl,
            fallbackImageUrl: vitrine.heroImagemUrl,
            isVideo: vitrine.heroVideoUrl.isNotEmpty,
            subtitle: vitrine.resumoConceito,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              alignment: Alignment.center,
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: AngoNetworkImage(
                    imageUrl: vitrine.heroImagemUrl,
                    fit: BoxFit.cover,
                    fallbackIcon: Icons.restaurant_rounded,
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.15),
                          Colors.black.withOpacity(0.75),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withOpacity(0.9),
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black38,
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.redAccent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'DESTAQUE DA COZINHA',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Conheça os Pratos Principais e a Arte da Nossa Brasa',
                        style: textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 22),

        // 3. Pratos Assinatura em Destaque na Home
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Expanded(
              child: Text(
                'Pratos Principais em Destaque',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            InkWell(
              onTap: () => _navigateToSection(1),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Text(
                  'Ver Cardápio Completo',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFDC2626),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Builder(
          builder: (context) {
            final destacadas = allItems.where((i) => i.isDestaque).toList();

            if (destacadas.isNotEmpty) {
              return Column(
                children: destacadas
                    .map(
                      (item) => _MenuItemTile(
                        item: item,
                        storeIsOpen: store.isAberta,
                        quantityInCart: CartService.instance.lojaId == store.id
                            ? CartService.instance.getQuantity(item.id)
                            : 0,
                        onAddPressed: () =>
                            _handleMenuItemTap(context, store, item),
                      ),
                    )
                    .toList(),
              );
            }
            return Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Center(
                child: Text(
                  allItems.isEmpty
                      ? 'O parceiro ainda não publicou artigos no cardápio.'
                      : 'Nenhum prato marcado em destaque. Consulte todos os artigos na aba Cardápio.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13.5,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // SECÇÃO 2: CARDÁPIO (MENU)
  // --------------------------------------------------------------------------
  Widget _buildMenuTab(
    BuildContext context, {
    required StoreSummaryModel store,
    required List<MenuCategoryModel> categories,
    required bool isThisStoreCart,
    required CartService cart,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (categories.isEmpty) {
      return const Center(
        child: Text('Esta loja ainda não publicou itens no cardápio.'),
      );
    }

    final filteredCategories = categories
        .where(
          (cat) =>
              _selectedMenuCategoryId == null ||
              cat.id == _selectedMenuCategoryId,
        )
        .map((cat) {
          if (_menuSearchQuery.trim().isEmpty) return cat;
          final q = _menuSearchQuery.trim().toLowerCase();
          final matchedItems = cat.itens
              .where(
                (i) =>
                    i.nome.toLowerCase().contains(q) ||
                    i.descricao.toLowerCase().contains(q),
              )
              .toList();
          return MenuCategoryModel(
            id: cat.id,
            nome: cat.nome,
            ordemExibicao: cat.ordemExibicao,
            itens: matchedItems,
          );
        })
        .where((cat) => _menuSearchQuery.trim().isEmpty || cat.itens.isNotEmpty)
        .toList();

    return Column(
      children: [
        // Barra de Pesquisa de Pratos/Ingredientes e Filtro de Categorias
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _menuSearchCtrl,
            onChanged: (v) => setState(() => _menuSearchQuery = v),
            decoration: InputDecoration(
              hintText: 'Pesquisar prato, bebida ou ingrediente...',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              suffixIcon: _menuSearchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _menuSearchCtrl.clear();
                        setState(() => _menuSearchQuery = '');
                      },
                    )
                  : null,
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('Todas as Categorias'),
                  selected: _selectedMenuCategoryId == null,
                  onSelected: (_) =>
                      setState(() => _selectedMenuCategoryId = null),
                ),
              ),
              ...categories.map(
                (cat) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${cat.nome} (${cat.itens.length})'),
                    selected: _selectedMenuCategoryId == cat.id,
                    onSelected: (sel) => setState(
                      () => _selectedMenuCategoryId = sel ? cat.id : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 12),
        Expanded(
          child: filteredCategories.isEmpty
              ? const Center(
                  child: Text('Nenhum prato encontrado para esta pesquisa.'),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  itemCount: filteredCategories.length,
                  itemBuilder: (context, catIdx) {
                    final category = filteredCategories[catIdx];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            children: [
                              Container(
                                width: 4,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: colorScheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  category.nome,
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (category.itens.isEmpty)
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.02),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary.withValues(alpha: 0.08),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.restaurant_menu_rounded,
                                    size: 20,
                                    color: colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Categoria em preparação',
                                        style: textTheme.labelLarge?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Esta categoria ainda não possui artigos cadastrados. Novos pratos estarão disponíveis em breve!',
                                        style: textTheme.bodySmall?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          ...category.itens.map((item) {
                            final quantityInCart = isThisStoreCart
                                ? cart.getQuantity(item.id)
                                : 0;
                            return _MenuItemTile(
                              item: item,
                              storeIsOpen: store.isAberta,
                              quantityInCart: quantityInCart,
                              onAddPressed: () =>
                                  _handleMenuItemTap(context, store, item),
                            );
                          }),
                        const SizedBox(height: 12),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // SECÇÃO 3: SOBRE NÓS (A NOSSA HISTÓRIA, ORIGEM, FILOSOFIA & CHEF)
  // --------------------------------------------------------------------------
  Widget _buildAboutUsTab(
    BuildContext context, {
    required StoreSummaryModel store,
    required StorefrontVitrineModel vitrine,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        // 1. A Nossa História
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_stories_rounded, color: colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        vitrine.tituloHistoria,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  vitrine.historiaRestaurante,
                  style: textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 2. Origem dos Pratos & Filosofia da Equipa
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Card(
                elevation: 0,
                color: colorScheme.secondaryContainer.withOpacity(0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.eco_rounded, color: colorScheme.primary),
                      const SizedBox(height: 8),
                      Text(
                        'Origem dos Pratos',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        vitrine.origemPratos,
                        style: textTheme.bodySmall?.copyWith(height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Card(
                elevation: 0,
                color: colorScheme.tertiaryContainer.withOpacity(0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.groups_rounded, color: colorScheme.primary),
                      const SizedBox(height: 8),
                      Text(
                        'Filosofia da Equipa',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        vitrine.filosofiaEquipa,
                        style: textTheme.bodySmall?.copyWith(height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // 3. Biografia do Chef
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: colorScheme.primary.withOpacity(0.3)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AngoNetworkImage(
                      imageUrl: vitrine.chefFotoUrl,
                      width: 72,
                      height: 72,
                      borderRadius: BorderRadius.circular(40),
                      fit: BoxFit.cover,
                      fallbackIcon: Icons.person_rounded,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'BIOGRAFIA DO CHEF',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            vitrine.chefNome,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            vitrine.chefTitulo,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  vitrine.chefBiografia,
                  style: textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
        ),

        // 4. Galeria Multimédia (Fotografias & Vídeos)
        if (vitrine.galeriaMidia.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(
            'Galeria de Fotos & Vídeos do Espaço',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.25,
            ),
            itemCount: vitrine.galeriaMidia.length,
            itemBuilder: (context, idx) {
              final media = vitrine.galeriaMidia[idx];
              final isVideo =
                  (media['tipo'] ?? '').toString().toLowerCase() == 'video';
              final url = (media['url'] ?? '').toString();
              final legenda = (media['legenda'] ?? 'Galeria').toString();

              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _showMediaViewerModal(
                  context,
                  title: legenda,
                  mediaUrl: url,
                  fallbackImageUrl: vitrine.heroImagemUrl,
                  isVideo: isVideo,
                  subtitle: store.nome,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AngoNetworkImage(
                        imageUrl: isVideo ? (url.isNotEmpty ? url : vitrine.heroImagemUrl) : url,
                        fit: BoxFit.cover,
                        fallbackIcon: isVideo ? Icons.videocam_rounded : Icons.image_outlined,
                      ),
                      if (isVideo)
                        const Center(
                          child: CircleAvatar(
                            backgroundColor: Colors.black54,
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          color: Colors.black54,
                          child: Text(
                            legenda,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }

  // --------------------------------------------------------------------------
  // SECÇÃO 4: RESERVAS (AGENDAMENTO DE MESA ONLINE)
  // --------------------------------------------------------------------------
  Widget _buildReservationsTab(
    BuildContext context, {
    required StoreSummaryModel store,
    required StorefrontVitrineModel vitrine,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final formattedDate =
        '${_reservationDate.day.toString().padLeft(2, '0')}/${_reservationDate.month.toString().padLeft(2, '0')}/${_reservationDate.year}';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        if (_confirmedReservation != null) ...[
          Card(
            elevation: 0,
            color: const Color(0xFFDCFCE7),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: Color(0xFF16A34A)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.verified_rounded,
                        color: Color(0xFF16A34A),
                        size: 28,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Mesa Reservada! Código: ${_confirmedReservation!['id']}',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: const Color(0xFF14532D),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Data: ${_confirmedReservation!['data_reserva']} às ${_confirmedReservation!['horario']} • '
                    '${_confirmedReservation!['numero_pessoas']} pessoa(s) • '
                    '${_confirmedReservation!['zona_preferida']}',
                    style: const TextStyle(
                      color: Color(0xFF14532D),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: () =>
                        setState(() => _confirmedReservation = null),
                    child: const Text('Fazer Outra Reserva'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],

        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Agendar uma Mesa Online',
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  vitrine.politicaReserva,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),

                // 1. Seletor de Data
                Text(
                  '1. Selecione a Data',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _reservationDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 60)),
                    );
                    if (picked != null) {
                      setState(() => _reservationDate = picked);
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.calendar_today_rounded),
                      border: OutlineInputBorder(),
                    ),
                    child: Text(
                      formattedDate,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // 2. Seletor de Horário
                Text(
                  '2. Escolha o Horário',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: vitrine.horariosDisponiveis.map((slot) {
                    final selected = _reservationTime == slot;
                    return ChoiceChip(
                      label: Text(slot),
                      selected: selected,
                      onSelected: (_) =>
                          setState(() => _reservationTime = slot),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),

                // 3. Número de Pessoas
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '3. Número de Pessoas',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Row(
                      children: [
                        IconButton.filledTonal(
                          onPressed: _reservationGuests > 1
                              ? () => setState(() => _reservationGuests--)
                              : null,
                          icon: const Icon(Icons.remove_rounded),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Text(
                            '$_reservationGuests',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        IconButton.filledTonal(
                          onPressed:
                              _reservationGuests < vitrine.capacidadeMaximaPessoas
                                  ? () => setState(() => _reservationGuests++)
                                  : null,
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 4. Ambiente / Zona Preferida
                Text(
                  '4. Ambiente Preferido',
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: vitrine.zonasDisponiveis.map((zona) {
                    final selected = _reservationZone == zona;
                    return ChoiceChip(
                      label: Text(zona),
                      selected: selected,
                      onSelected: (_) =>
                          setState(() => _reservationZone = zona),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),

                // 5. Dados do Cliente e Observações
                TextField(
                  controller: _resNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'O seu Nome Completo',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _resPhoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Telemóvel / WhatsApp para Confirmação',
                    prefixIcon: Icon(Icons.phone_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _resNotesCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Pedidos Especiais (Aniversário, Cadeira de Bebé, Alergias)',
                    prefixIcon: Icon(Icons.notes_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSubmittingReservation
                        ? null
                        : () async {
                            setState(() => _isSubmittingReservation = true);
                            try {
                              final dateIso =
                                  '${_reservationDate.year}-${_reservationDate.month.toString().padLeft(2, '0')}-${_reservationDate.day.toString().padLeft(2, '0')}';
                              final repo = _getCatalogRepository();
                              final resp =
                                  await repo.submitTableReservation(
                                storeId: store.id,
                                payload: {
                                  'nome_cliente': _resNameCtrl.text.trim().isEmpty
                                      ? 'Cliente Delivery Pro'
                                      : _resNameCtrl.text.trim(),
                                  'telefone_cliente': _resPhoneCtrl.text.trim(),
                                  'data_reserva': dateIso,
                                  'horario': _reservationTime,
                                  'numero_pessoas': _reservationGuests,
                                  'zona_preferida': _reservationZone,
                                  'notas_especiais': _resNotesCtrl.text.trim(),
                                },
                              );
                              if (!context.mounted) return;
                              setState(() {
                                _isSubmittingReservation = false;
                                _confirmedReservation = resp['reserva'] is Map<String, dynamic>
                                    ? resp['reserva'] as Map<String, dynamic>
                                    : <String, dynamic>{
                                        'id': 'RES-OK',
                                        'data_reserva': dateIso,
                                        'horario': _reservationTime,
                                        'numero_pessoas': _reservationGuests,
                                        'zona_preferida': _reservationZone,
                                      };
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Reserva confirmada com sucesso!',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            } catch (e) {
                              if (!context.mounted) return;
                              setState(() => _isSubmittingReservation = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Erro ao agendar reserva: $e'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                    icon: _isSubmittingReservation
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_circle_outline_rounded),
                    label: Text(
                      _isSubmittingReservation
                          ? 'A Confirmar Reserva...'
                          : 'Confirmar Reserva de Mesa',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // SECÇÃO 5: LOCALIZAÇÃO E CONTATO (MORADA, HORÁRIOS, GPS E MENSAGENS)
  // --------------------------------------------------------------------------
  Widget _buildLocationAndContactTab(
    BuildContext context, {
    required StoreSummaryModel store,
    required StorefrontVitrineModel vitrine,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    const diasNomes = [
      'Segunda-feira',
      'Terça-feira',
      'Quarta-feira',
      'Quinta-feira',
      'Sexta-feira',
      'Sábado',
      'Domingo',
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        // 1. Morada Exata e Link para GPS
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: colorScheme.primaryContainer,
                      child: Icon(
                        Icons.location_on_rounded,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Localização Exata & GPS',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            vitrine.moradaCompleta,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (vitrine.pontoReferencia.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Referência: ${vitrine.pontoReferencia}',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Coordenadas GPS: ${vitrine.latitude.toStringAsFixed(5)}, ${vitrine.longitude.toStringAsFixed(5)}',
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: () {
                      final gpsUrl = vitrine.gpsLinkExterno.isNotEmpty
                          ? vitrine.gpsLinkExterno
                          : 'https://www.google.com/maps/search/?api=1&query=${vitrine.latitude},${vitrine.longitude}';
                      Clipboard.setData(ClipboardData(text: gpsUrl));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Link GPS copiado ($gpsUrl)! Pode colar no Google Maps ou Waze.',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    icon: const Icon(Icons.map_rounded),
                    label: const Text('Copiar Link Direto para o GPS (Google Maps)'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 2. Contactos Diretos (Telefone, WhatsApp, E-mail, Instagram)
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Contactos Diretos',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.phone_in_talk_rounded),
                  title: const Text('Telefone Principal'),
                  subtitle: Text(vitrine.telefonePrincipal),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: vitrine.telefonePrincipal),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Número de telefone copiado!'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.chat_bubble_outline_rounded),
                  title: const Text('WhatsApp & Reservas Rápidas'),
                  subtitle: Text(vitrine.whatsapp),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: vitrine.whatsapp));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Contacto WhatsApp copiado!'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('E-mail & Eventos'),
                  subtitle: Text('${vitrine.emailContacto} • ${vitrine.instagram}'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 3. Horário de Funcionamento Semanal (RN-012)
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.access_time_filled_rounded, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Horário de Funcionamento',
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ...List.generate(7, (diaIndex) {
                  final matching = vitrine.horariosSemanal
                      .where((h) => (h['dia_semana'] as num?)?.toInt() == diaIndex)
                      .toList();
                  final bool isAberto = matching.isNotEmpty;
                  final String horarioTexto;
                  if (isAberto) {
                    final h = matching.first;
                    final ab = h['hora_abertura']?.toString();
                    final fe = h['hora_fecho']?.toString();
                    final abFmt = (ab != null && ab.length >= 5) ? ab.substring(0, 5) : '08:00';
                    final feFmt = (fe != null && fe.length >= 5) ? fe.substring(0, 5) : '22:00';
                    horarioTexto = '$abFmt às $feFmt';
                  } else {
                    horarioTexto = 'Encerrado';
                  }

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          diasNomes[diaIndex],
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isAberto ? null : const Color(0xFF64748B),
                          ),
                        ),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: isAberto ? 0 : 8,
                            vertical: isAberto ? 0 : 2,
                          ),
                          decoration: isAberto
                              ? null
                              : BoxDecoration(
                                  color: const Color(0xFFF1F5F9),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                          child: Text(
                            horarioTexto,
                            style: textTheme.bodyMedium?.copyWith(
                              color: isAberto ? colorScheme.primary : const Color(0xFF64748B),
                              fontWeight: isAberto ? FontWeight.bold : FontWeight.w600,
                              fontSize: isAberto ? 14 : 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 4. Formulário de Mensagens Diretas
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enviar Mensagem ao Restaurante',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Dúvidas sobre pratos, eventos privados ou sugestões? Escreva-nos diretamente:',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _msgNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'O seu Nome',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _msgContactCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Telemóvel ou E-mail de Resposta',
                    prefixIcon: Icon(Icons.contact_phone_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _msgSubjectCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Assunto (ex.: Evento de Aniversário, Dúvida)',
                    prefixIcon: Icon(Icons.subject_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _msgBodyCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'A sua Mensagem',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _isSendingMessage
                        ? null
                        : () async {
                            if (_msgBodyCtrl.text.trim().isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Por favor, escreva a sua mensagem.',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              return;
                            }
                            setState(() => _isSendingMessage = true);
                            try {
                              final repo = _getCatalogRepository();
                              await repo.submitStoreContactMessage(
                                storeId: store.id,
                                payload: {
                                  'nome': _msgNameCtrl.text.trim().isEmpty
                                      ? 'Cliente'
                                      : _msgNameCtrl.text.trim(),
                                  'contacto': _msgContactCtrl.text.trim(),
                                  'assunto': _msgSubjectCtrl.text.trim().isEmpty
                                      ? 'Contacto pelo App'
                                      : _msgSubjectCtrl.text.trim(),
                                  'mensagem': _msgBodyCtrl.text.trim(),
                                },
                              );
                              if (!context.mounted) return;
                              setState(() {
                                _isSendingMessage = false;
                                _msgBodyCtrl.clear();
                                _msgSubjectCtrl.clear();
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Mensagem enviada com sucesso para o restaurante!',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            } catch (e) {
                              if (!context.mounted) return;
                              setState(() => _isSendingMessage = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Erro ao enviar mensagem: $e'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.send_rounded),
                    label: Text(
                      _isSendingMessage
                          ? 'A Enviar...'
                          : 'Enviar Mensagem Direta',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showMediaViewerModal(
    BuildContext context, {
    required String title,
    required String mediaUrl,
    required String fallbackImageUrl,
    required bool isVideo,
    required String subtitle,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isVideo
                      ? Icons.videocam_rounded
                      : Icons.photo_camera_back_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
                IconButton.filledTonal(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: mediaUrl));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Link de mídia copiado!'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  icon: const Icon(Icons.share_rounded, size: 18),
                  tooltip: 'Partilhar Link',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isVideo)
              AngoVideoPlayerWidget(
                videoUrl: mediaUrl,
                thumbnailUrl: fallbackImageUrl,
                autoPlay: true,
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: InteractiveViewer(
                    maxScale: 4.0,
                    child: AngoNetworkImage(
                      imageUrl: mediaUrl.isNotEmpty ? mediaUrl : fallbackImageUrl,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleMenuItemTap(
    BuildContext context,
    StoreSummaryModel store,
    MenuItemModel item,
  ) async {
    final cart = CartService.instance;
    if (cart.hasStoreConflict(store.id)) {
      final confirmClear = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('Limpar sacola atual?'),
          content: Text(
            'A sua sacola já contém itens de "${cart.lojaNome ?? 'outra loja'}". '
            'Deseja limpar a sacola atual e iniciar um novo pedido em "${store.nome}"?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('Sim, limpar e continuar'),
            ),
          ],
        ),
      );
      if (confirmClear != true || !context.mounted) return;
      cart.clear();
    }

    showItemCustomizationBottomSheet(
      context,
      store: store,
      item: item,
      onItemAdded: () {
        if (context.mounted) {
          context
              .read<StoreMenuBloc>()
              .add(AddMenuItemToCartEvent(item: item));
        }
      },
    );
  }
}

/// Componente de Item de Menu (RN-014, RN-015):
/// Se `item.isDisponivel == false`, aplica filtro cinzento (desaturação + opacidade reduzida),
/// exibe badge "Indisponível" e bloqueia estritamente o clique de adição ao carrinho.
class _MenuItemTile extends StatelessWidget {
  final MenuItemModel item;
  final bool storeIsOpen;
  final int quantityInCart;
  final VoidCallback onAddPressed;

  const _MenuItemTile({
    required this.item,
    required this.storeIsOpen,
    required this.quantityInCart,
    required this.onAddPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bool canAdd = item.isDisponivel && storeIsOpen;
    const double imageColWidth = 100.0;
    const double gap = 14.0;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(
          color: Color(0xFFE2E8F0),
          width: 1.2,
        ),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: canAdd ? onAddPressed : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Coluna Textual com preenchimento total do espaço disponível (Expanded)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.nome,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                        height: 1.25,
                        decoration: item.isDisponivel ? null : TextDecoration.lineThrough,
                      ),
                    ),
                        if (!item.isDisponivel) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEE2E2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'Esgotado',
                              style: TextStyle(
                                color: Color(0xFFDC2626),
                                fontWeight: FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                        if (item.descricao.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            item.descricao,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF475569),
                              height: 1.35,
                            ),
                          ),
                        ],
                        if (item.alergenos.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: item.alergenos
                                .map(
                                  (alergeno) => Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 3.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF6ECEC),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      alergeno,
                                      style: const TextStyle(
                                        color: Color(0xFF4A3E3D),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          formatarMoedaUnidadesMinimas(item.preco),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: item.isDisponivel
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: gap),

                  // 2. Coluna da Imagem e Botão de Ação (Pílula Vermelha)
                  SizedBox(
                    width: imageColWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AngoNetworkImage(
                          imageUrl: item.imagemUrl,
                          width: imageColWidth,
                          height: 88,
                          borderRadius: BorderRadius.circular(16),
                          fit: BoxFit.cover,
                          fallbackIcon: Icons.fastfood_outlined,
                        ),
                        const SizedBox(height: 10),
                        if (canAdd)
                          SizedBox(
                            width: imageColWidth,
                            height: 36,
                            child: quantityInCart > 0
                                ? Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFDC2626),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '$quantityInCart no cesto',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  )
                                : InkWell(
                                    onTap: onAddPressed,
                                    borderRadius: BorderRadius.circular(20),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFDC2626),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      alignment: Alignment.center,
                                      child: const Text(
                                        'Adicionar',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                          )
                        else
                          Container(
                            width: imageColWidth,
                            height: 36,
                            decoration: BoxDecoration(
                              color: const Color(0xFFE2E8F0),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              !item.isDisponivel ? 'Esgotado' : 'Fechado',
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
  }
}

// ============================================================================
// 7. MODAL DE PERSONALIZAÇÃO DE ITEM DE MENU (RN-014, RN-042, RN-045)
// ============================================================================

Future<void> showItemCustomizationBottomSheet(
  BuildContext context, {
  required StoreSummaryModel store,
  required MenuItemModel item,
  VoidCallback? onItemAdded,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _ItemCustomizationSheet(
      store: store,
      item: item,
      onItemAdded: onItemAdded,
    ),
  );
}

class _ItemCustomizationSheet extends StatefulWidget {
  final StoreSummaryModel store;
  final MenuItemModel item;
  final VoidCallback? onItemAdded;

  const _ItemCustomizationSheet({
    required this.store,
    required this.item,
    this.onItemAdded,
  });

  @override
  State<_ItemCustomizationSheet> createState() =>
      _ItemCustomizationSheetState();
}

class _ItemCustomizationSheetState extends State<_ItemCustomizationSheet> {
  int _quantity = 1;
  final Map<String, Set<String>> _selectedOptionsByGroup = {};
  final TextEditingController _notesController = TextEditingController();
  String? _validationError;

  @override
  void initState() {
    super.initState();
    for (final group in widget.item.gruposOpcoes) {
      _selectedOptionsByGroup[group.id] = <String>{};
      // Se for obrigatório e tiver pelo menos 1 opção disponível, pré-seleciona a primeira para conveniência
      if (group.isObrigatorio) {
        final available = group.opcoes.where((o) => o.isDisponivel).toList();
        final minNeeded = group.minimoEscolhas > 0 ? group.minimoEscolhas : 1;
        for (var i = 0; i < minNeeded && i < available.length; i++) {
          _selectedOptionsByGroup[group.id]!.add(available[i].id);
        }
      }
    }
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  int get _optionsExtraCentimos {
    var extra = 0;
    for (final group in widget.item.gruposOpcoes) {
      final selectedSet = _selectedOptionsByGroup[group.id] ?? const <String>{};
      for (final opt in group.opcoes) {
        if (selectedSet.contains(opt.id)) {
          extra += opt.precoAdicional;
        }
      }
    }
    return extra;
  }

  int get _unitPriceCentimos => widget.item.preco + _optionsExtraCentimos;

  int get _totalPriceCentimos => _unitPriceCentimos * _quantity;

  bool _validateGroups() {
    for (final group in widget.item.gruposOpcoes) {
      final count = (_selectedOptionsByGroup[group.id] ?? const <String>{}).length;
      final minRequired = group.isObrigatorio
          ? (group.minimoEscolhas > 0 ? group.minimoEscolhas : 1)
          : group.minimoEscolhas;
      if (count < minRequired) {
        setState(() {
          _validationError =
              'Selecione pelo menos $minRequired opção(ões) em "${group.nome}".';
        });
        return false;
      }
      if (group.maximoEscolhas > 0 && count > group.maximoEscolhas) {
        setState(() {
          _validationError =
              'Máximo de ${group.maximoEscolhas} opção(ões) permitido em "${group.nome}".';
        });
        return false;
      }
    }
    setState(() => _validationError = null);
    return true;
  }

  void _toggleOption(MenuOptionGroupModel group, MenuOptionItemModel option) {
    if (!option.isDisponivel) return;
    final set = _selectedOptionsByGroup.putIfAbsent(group.id, () => <String>{});
    setState(() {
      _validationError = null;
      if (set.contains(option.id)) {
        set.remove(option.id);
      } else {
        if (group.maximoEscolhas == 1) {
          set
            ..clear()
            ..add(option.id);
        } else if (group.maximoEscolhas <= 0 ||
            set.length < group.maximoEscolhas) {
          set.add(option.id);
        } else {
          _validationError =
              'Já selecionou o limite máximo (${group.maximoEscolhas}) para "${group.nome}".';
        }
      }
    });
  }

  void _confirmAdd() {
    if (!_validateGroups()) return;

    final selectedIds = <String>[];
    final selectedNames = <String>[];
    for (final group in widget.item.gruposOpcoes) {
      final set = _selectedOptionsByGroup[group.id] ?? const <String>{};
      for (final opt in group.opcoes) {
        if (set.contains(opt.id)) {
          selectedIds.add(opt.id);
          selectedNames.add(opt.nome);
        }
      }
    }

    CartService.instance.addItem(
      itemId: widget.item.id,
      lojaId: widget.store.id,
      lojaNome: widget.store.nome,
      nome: widget.item.nome,
      imagemUrl: widget.item.imagemUrl,
      precoUnitarioCentimos: _unitPriceCentimos,
      quantidade: _quantity,
      opcoesIds: selectedIds,
      opcoesNomes: selectedNames,
      notas: _notesController.text.trim(),
    );

    widget.onItemAdded?.call();
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_quantity}x ${widget.item.nome} adicionado à sacola!',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                children: [
                  if (widget.item.imagemUrl.isNotEmpty) ...[
                    AspectRatio(
                      aspectRatio: 16 / 9,
                      child: AngoNetworkImage(
                        imageUrl: widget.item.imagemUrl,
                        borderRadius: BorderRadius.circular(16),
                        fit: BoxFit.cover,
                        fallbackIcon: Icons.fastfood_rounded,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    widget.item.nome,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    formatarMoedaUnidadesMinimas(widget.item.preco),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (widget.item.descricao.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.item.descricao,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (widget.item.gruposOpcoes.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const Divider(),
                    ...widget.item.gruposOpcoes.map((group) {
                      final selectedSet =
                          _selectedOptionsByGroup[group.id] ?? const <String>{};
                      final minRequired = group.isObrigatorio
                          ? (group.minimoEscolhas > 0 ? group.minimoEscolhas : 1)
                          : group.minimoEscolhas;

                      return Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        group.nome,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        minRequired > 0
                                            ? 'Escolha de $minRequired até ${group.maximoEscolhas}'
                                            : 'Escolha até ${group.maximoEscolhas} (Opcional)',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: group.isObrigatorio
                                        ? colorScheme.primaryContainer
                                        : colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    group.isObrigatorio
                                        ? 'Obrigatório'
                                        : 'Opcional',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: group.isObrigatorio
                                          ? colorScheme.onPrimaryContainer
                                          : colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...group.opcoes.map((opt) {
                              final isSelected = selectedSet.contains(opt.id);
                              return CheckboxListTile(
                                value: isSelected,
                                enabled: opt.isDisponivel,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                onChanged: opt.isDisponivel
                                    ? (_) => _toggleOption(group, opt)
                                    : null,
                                title: Text(
                                  opt.nome,
                                  style: TextStyle(
                                    decoration: opt.isDisponivel
                                        ? null
                                        : TextDecoration.lineThrough,
                                  ),
                                ),
                                secondary: Text(
                                  opt.precoAdicional > 0
                                      ? '+ ${formatarMoedaUnidadesMinimas(opt.precoAdicional)}'
                                      : 'Grátis',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: colorScheme.primary,
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Observações para a cozinha',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _notesController,
                    maxLines: 2,
                    maxLength: 200,
                    decoration: InputDecoration(
                      hintText:
                          'Ex.: Sem cebola, molho à parte, bem passado...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  if (_validationError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _validationError!,
                        style: TextStyle(
                          color: colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Barra inferior: Quantidade + Botão Adicionar
            SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: _quantity > 1
                                ? () => setState(() => _quantity--)
                                : null,
                            icon: const Icon(Icons.remove_rounded),
                          ),
                          Text(
                            '$_quantity',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            onPressed: _quantity < 20
                                ? () => setState(() => _quantity++)
                                : null,
                            icon: const Icon(Icons.add_rounded),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _confirmAdd,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: Text(
                          'Adicionar • ${formatarMoedaUnidadesMinimas(_totalPriceCentimos)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 8. MODAL DE GESTÃO E SELEÇÃO DE MORADAS DE ENTREGA (RN-005, RN-025)
// ============================================================================

Future<void> showCustomerAddressSelectionSheet(
  BuildContext context, {
  CustomerGeoAddress? currentAddress,
  ValueChanged<CustomerGeoAddress>? onAddressSelected,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _CustomerAddressSelectionSheet(
      currentAddress: currentAddress,
      onAddressSelected: onAddressSelected,
    ),
  );
}

class _CustomerAddressSelectionSheet extends StatefulWidget {
  final CustomerGeoAddress? currentAddress;
  final ValueChanged<CustomerGeoAddress>? onAddressSelected;

  const _CustomerAddressSelectionSheet({
    this.currentAddress,
    this.onAddressSelected,
  });

  @override
  State<_CustomerAddressSelectionSheet> createState() =>
      _CustomerAddressSelectionSheetState();
}

class _CustomerAddressSelectionSheetState
    extends State<_CustomerAddressSelectionSheet> {
  bool _isLoading = true;
  bool _isCreating = false;
  bool _showForm = false;
  String? _errorMsg;
  List<CustomerGeoAddress> _savedAddresses = [];

  final _enderecoController = TextEditingController();
  final _referenciaController = TextEditingController();
  final _andarPortaController = TextEditingController();
  final _instrucoesController = TextEditingController();
  final _municipioController = TextEditingController();
  final int _selectedPresetIndex = 0;
  String _selectedProvince = 'Luanda';

  static const List<String> _todasProvinciasAngola = [
    'Luanda',
    'Benguela',
    'Huambo',
    'Huíla',
    'Cabinda',
    'Cuanza Sul',
    'Cuanza Norte',
    'Uíge',
    'Zaire',
    'Malanje',
    'Lunda Norte',
    'Lunda Sul',
    'Moxico',
    'Bié',
    'Namibe',
    'Cunene',
    'Cuando Cubango',
    'Bengo',
  ];

  static const List<CustomerGeoAddress> _angolaNationalPresets = [
    // 1. Luanda
    CustomerGeoAddress(
      id: 'preset_ingombota',
      label: 'Ingombota / Centro (Luanda)',
      fullAddress: 'Avenida 4 de Fevereiro, Marginal de Luanda, Ingombota, Luanda',
      referencia: 'Centro de Luanda',
      latitude: -8.8147,
      longitude: 13.2343,
    ),
    CustomerGeoAddress(
      id: 'preset_talatona',
      label: 'Talatona (Luanda)',
      fullAddress: 'Via S8, Condomínio Belas Business Park, Talatona, Luanda',
      referencia: 'Talatona Shopping',
      latitude: -8.9167,
      longitude: 13.1833,
    ),
    CustomerGeoAddress(
      id: 'preset_kilamba',
      label: 'Centralidade do Kilamba (Luanda)',
      fullAddress: 'Quarteirão Q, Centralidade do Kilamba, Belas, Luanda',
      referencia: 'Kero Kilamba',
      latitude: -8.9950,
      longitude: 13.2680,
    ),
    CustomerGeoAddress(
      id: 'preset_maianga',
      label: 'Maianga / Alvalade (Luanda)',
      fullAddress: 'Rua Comandante Gika, Alvalade, Maianga, Luanda',
      referencia: 'Hotel Alvalade',
      latitude: -8.8399,
      longitude: 13.2345,
    ),
    CustomerGeoAddress(
      id: 'preset_morro_bento',
      label: 'Morro Bento (Luanda)',
      fullAddress: 'Avenida 21 de Janeiro, Morro Bento, Luanda',
      referencia: 'Rotunda da Multiperfil',
      latitude: -8.8850,
      longitude: 13.1950,
    ),
    CustomerGeoAddress(
      id: 'preset_viana',
      label: 'Viana / Zango (Luanda)',
      fullAddress: 'Estrada de Catete, Vila de Viana, Luanda',
      referencia: 'Administração de Viana',
      latitude: -8.9030,
      longitude: 13.3740,
    ),
    // 2. Benguela & Lobito
    CustomerGeoAddress(
      id: 'preset_benguela_centro',
      label: 'Benguela Centro',
      fullAddress: 'Largo da Peça, Zona Comercial, Benguela',
      referencia: 'Praça Central de Benguela',
      latitude: -12.5763,
      longitude: 13.4055,
    ),
    CustomerGeoAddress(
      id: 'preset_lobito',
      label: 'Lobito / Restinga',
      fullAddress: 'Avenida da Independência, Restinga, Lobito, Benguela',
      referencia: 'Porto do Lobito',
      latitude: -12.3644,
      longitude: 13.5360,
    ),
    // 3. Huambo
    CustomerGeoAddress(
      id: 'preset_huambo_centro',
      label: 'Huambo Centro',
      fullAddress: 'Avenida Norton de Matos, Huambo',
      referencia: 'Jardim da Cultura',
      latitude: -12.7761,
      longitude: 15.7392,
    ),
    // 4. Huíla (Lubango)
    CustomerGeoAddress(
      id: 'preset_lubango_centro',
      label: 'Lubango Centro (Huíla)',
      fullAddress: 'Avenida Lúcio Lara, Lubango, Huíla',
      referencia: 'Sé Catedral do Lubango',
      latitude: -14.9172,
      longitude: 13.4925,
    ),
    // 5. Cabinda
    CustomerGeoAddress(
      id: 'preset_cabinda_centro',
      label: 'Cabinda Centro',
      fullAddress: 'Avenida Duque de Chiazi, Cabinda',
      referencia: 'Palácio do Governo de Cabinda',
      latitude: -5.5500,
      longitude: 12.2000,
    ),
    // 6. Cuanza Sul (Sumbe)
    CustomerGeoAddress(
      id: 'preset_sumbe',
      label: 'Sumbe Centro (Cuanza Sul)',
      fullAddress: 'Avenida 4 de Fevereiro, Sumbe, Cuanza Sul',
      referencia: 'Marginal do Sumbe',
      latitude: -11.2061,
      longitude: 13.8437,
    ),
    // 7. Malanje
    CustomerGeoAddress(
      id: 'preset_malanje',
      label: 'Malanje Centro',
      fullAddress: 'Avenida Agostinho Neto, Malanje',
      referencia: 'Largo da Rainha Ginga',
      latitude: -9.5402,
      longitude: 16.3410,
    ),
    // 8. Namibe (Moçâmedes)
    CustomerGeoAddress(
      id: 'preset_namibe',
      label: 'Moçâmedes / Namibe Centro',
      fullAddress: 'Avenida Marginal, Moçâmedes, Namibe',
      referencia: 'Baía de Moçâmedes',
      latitude: -15.1961,
      longitude: 12.1522,
    ),
    // 9. Zaire (Soyo)
    CustomerGeoAddress(
      id: 'preset_soyo',
      label: 'Soyo Centro (Zaire)',
      fullAddress: 'Estrada Principal do Kwanda, Soyo, Zaire',
      referencia: 'Base Petrolífera do Kwanda',
      latitude: -6.1349,
      longitude: 12.3689,
    ),
    // 10. Uíge
    CustomerGeoAddress(
      id: 'preset_uige',
      label: 'Uíge Centro',
      fullAddress: 'Avenida dos Combatentes, Uíge',
      referencia: 'Praça da Independência do Uíge',
      latitude: -7.6086,
      longitude: 15.0614,
    ),
  ];

  static List<CustomerGeoAddress> get _luandaDistrictPresets => _angolaNationalPresets;

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  @override
  void dispose() {
    _enderecoController.dispose();
    _referenciaController.dispose();
    _andarPortaController.dispose();
    _instrucoesController.dispose();
    _municipioController.dispose();
    super.dispose();
  }

  Future<Dio?> _buildAuthDio() async {
    var token = await SecureTokenStorage().getAccessToken();
    if ((token == null || token.isEmpty) && mounted) {
      try {
        final authState = context.read<AuthBloc>().state;
        if (authState is Authenticated && authState.tokens.accessToken.isNotEmpty) {
          token = authState.tokens.accessToken;
          await SecureTokenStorage().saveTokens(
            accessToken: authState.tokens.accessToken,
            refreshToken: authState.tokens.refreshToken,
            userRole: authState.user.tipoUtilizador,
          );
        }
      } catch (_) {}
    }
    if (token == null || token.isEmpty) return null;
    return createSecureDioClient(tokenStorage: SecureTokenStorage());
  }

  Future<void> _loadAddresses() async {
    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });
    try {
      final dio = await _buildAuthDio();
      if (dio == null) {
        setState(() {
          _savedAddresses = _luandaDistrictPresets;
          _isLoading = false;
        });
        return;
      }
      final resp = await dio.get<dynamic>('/api/v1/auth/moradas/');
      final raw = resp.data;
      List<dynamic> list = const [];
      if (raw is List) {
        list = raw;
      } else if (raw is Map<String, dynamic> && raw['results'] is List) {
        list = raw['results'] as List<dynamic>;
      }
      final parsed = list
          .whereType<Map<String, dynamic>>()
          .map(CustomerGeoAddress.fromMoradaJson)
          .toList();

      if (mounted) {
        setState(() {
          _savedAddresses = parsed;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _savedAddresses = _luandaDistrictPresets;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _selectAndActivate(
    CustomerGeoAddress address, {
    bool persistIfPreset = false,
  }) async {
    var chosen = address;
    if (persistIfPreset && address.id.startsWith('preset_')) {
      try {
        final dio = await _buildAuthDio();
        if (dio != null) {
          final resp = await dio.post<Map<String, dynamic>>(
            '/api/v1/auth/moradas/',
            data: {
              'texto_endereco': address.fullAddress,
              'referencia': address.label,
              'andar_porta': address.andarPorta,
              'instrucoes_estafeta': address.instrucoesEstafeta,
              'latitude': address.latitude,
              'longitude': address.longitude,
            },
          );
          if (resp.data != null) {
            chosen = CustomerGeoAddress.fromMoradaJson(resp.data!);
          }
        }
      } catch (_) {}
    }

    CartService.instance.updateActiveAddress(
      id: chosen.id,
      label: chosen.label,
      fullAddress: chosen.fullAddress,
      referencia: chosen.referencia,
      latitude: chosen.latitude,
      longitude: chosen.longitude,
    );
    widget.onAddressSelected?.call(chosen);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _createNewAddress() async {
    final texto = _enderecoController.text.trim();
    if (texto.length < 5) {
      setState(() => _errorMsg = 'Informe o endereço completo (mín. 5 letras).');
      return;
    }

    setState(() {
      _isCreating = true;
      _errorMsg = null;
    });

    final preset = _angolaNationalPresets[_selectedPresetIndex.clamp(0, _angolaNationalPresets.length - 1)];
    final municipioTexto = _municipioController.text.trim().isNotEmpty
        ? _municipioController.text.trim()
        : preset.label;
    final ref = _referenciaController.text.trim().isNotEmpty
        ? _referenciaController.text.trim()
        : '$municipioTexto, $_selectedProvince';
    final fullAddr = '$texto, $municipioTexto, $_selectedProvince, Angola';

    try {
      final dio = await _buildAuthDio();
      if (dio != null) {
        final resp = await dio.post<Map<String, dynamic>>(
          '/api/v1/auth/moradas/',
          data: {
            'texto_endereco': fullAddr,
            'referencia': ref,
            'andar_porta': _andarPortaController.text.trim(),
            'instrucoes_estafeta': _instrucoesController.text.trim(),
            'latitude': preset.latitude,
            'longitude': preset.longitude,
          },
        );
        if (resp.data != null) {
          final created = CustomerGeoAddress.fromMoradaJson(resp.data!);
          await _selectAndActivate(created);
          return;
        }
      }
      // Fallback caso offline
      final fallback = CustomerGeoAddress(
        id: 'morada_principal',
        label: ref,
        fullAddress: fullAddr,
        referencia: ref,
        andarPorta: _andarPortaController.text.trim(),
        instrucoesEstafeta: _instrucoesController.text.trim(),
        latitude: preset.latitude,
        longitude: preset.longitude,
      );
      await _selectAndActivate(fallback);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _errorMsg = 'Não foi possível guardar a morada. Tente novamente.';
        });
      }
    }
  }

  Future<void> _deleteAddress(CustomerGeoAddress addr) async {
    if (addr.id.startsWith('preset_') || addr.id == 'morada_principal') return;
    try {
      final dio = await _buildAuthDio();
      if (dio != null) {
        await dio.delete<void>('/api/v1/auth/moradas/${addr.id}/');
      }
      await _loadAddresses();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final activeId = CartService.instance.moradaId;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: double.infinity,
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _showForm
                          ? 'Nova Morada de Entrega'
                          : 'Moradas de Entrega',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                    onPressed: () => setState(() => _showForm = !_showForm),
                    icon: Icon(_showForm ? Icons.close : Icons.add_location_alt, size: 18),
                    label: Text(_showForm ? 'Voltar' : 'Nova Morada'),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            if (_errorMsg != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _errorMsg!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
            if (_showForm) ...[
              Text(
                'Província (Cobertura Nacional de Angola):',
                style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 38,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _todasProvinciasAngola.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (ctx, i) {
                    final prov = _todasProvinciasAngola[i];
                    final isSel = _selectedProvince == prov;
                    return ChoiceChip(
                      label: Text(prov),
                      selected: isSel,
                      selectedColor: const Color(0xFFEFF6FF),
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        color: isSel ? const Color(0xFF1E88E5) : const Color(0xFF64748B),
                      ),
                      onSelected: (_) => setState(() => _selectedProvince = prov),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _municipioController,
                decoration: InputDecoration(
                  labelText: 'Município / Bairro na província de $_selectedProvince *',
                  hintText: 'Ex.: Maianga, Lobito, Caála, Lubango...',
                  prefixIcon: const Icon(Icons.location_city_rounded),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _enderecoController,
                decoration: const InputDecoration(
                  labelText: 'Rua, Avenida ou Condomínio *',
                  hintText: 'Ex.: Rua Comandante Gika, Casa 24',
                  prefixIcon: Icon(Icons.home_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _referenciaController,
                decoration: const InputDecoration(
                  labelText: 'Nome / Ponto de Referência (ex.: Casa, Trabalho)',
                  hintText: 'Ex.: Em frente à Clínica Multiperfil',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _andarPortaController,
                      decoration: const InputDecoration(
                        labelText: 'Andar / Porta',
                        hintText: 'Ex.: 2.º Andar, Porta B',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _instrucoesController,
                      decoration: const InputDecoration(
                        labelText: 'Instruções p/ Estafeta',
                        hintText: 'Ex.: Tocar campainha',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _isCreating ? null : _createNewAddress,
                icon: _isCreating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: const Text('Guardar e Usar Esta Morada'),
              ),
            ] else ...[
              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                if (_savedAddresses.isNotEmpty) ...[
                  Text(
                    'As Minhas Moradas Guardadas',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._savedAddresses.map((addr) {
                    final isSelected = addr.id == activeId ||
                        addr.fullAddress == CartService.instance.moradaTexto;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      elevation: 0,
                      color: isSelected
                          ? colorScheme.primaryContainer.withOpacity(0.35)
                          : null,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: isSelected
                              ? colorScheme.primary
                              : colorScheme.outlineVariant,
                        ),
                      ),
                      child: ListTile(
                        onTap: () => _selectAndActivate(addr),
                        leading: Icon(
                          isSelected
                              ? Icons.radio_button_checked_rounded
                              : Icons.location_on_outlined,
                          color: colorScheme.primary,
                        ),
                        title: Text(
                          addr.label,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          addr.fullAddress,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: _savedAddresses.length > 1 &&
                                !addr.id.startsWith('preset_')
                            ? IconButton(
                                icon: Icon(
                                  Icons.delete_outline_rounded,
                                  color: colorScheme.error,
                                ),
                                onPressed: () => _deleteAddress(addr),
                              )
                            : null,
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
                Text(
                  'Zonas de Entrega Rápida em Angola',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ..._angolaNationalPresets.map((preset) {
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: const Icon(Icons.my_location_rounded, size: 20),
                    title: Text(
                      preset.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      preset.fullAddress,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _selectAndActivate(
                      preset,
                      persistIfPreset: true,
                    ),
                  );
                }),
              ],
            ],
          ],
        ),
      ),
    ),
  );
}
}
