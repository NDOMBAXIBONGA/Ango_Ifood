import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/network/app_environment_config.dart';
import '../../auth/storage/secure_token_storage.dart';
import '../../catalog/customer_catalog_screens.dart';

/// Centro de Controlo Total da Vitrine & CMS do Parceiro (`PartnerStorefrontCmsScreen`).
/// Permite ao parceiro comercial controlar 100% dos textos, fotografias, vídeos,
/// história do restaurante, biografia do Chef, galeria multimédia, reservas de mesas,
/// coordenadas GPS, contactos e mensagens de clientes em tempo real.
class PartnerStorefrontCmsScreen extends StatefulWidget {
  const PartnerStorefrontCmsScreen({super.key});

  @override
  State<PartnerStorefrontCmsScreen> createState() =>
      _PartnerStorefrontCmsScreenState();
}

class _PartnerStorefrontCmsScreenState extends State<PartnerStorefrontCmsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final SecureTokenStorage _tokenStorage = SecureTokenStorage();

  bool _isLoading = true;
  bool _isSaving = false;
  String _lojaId = '';

  // 1. Controladores: Página Inicial (Home & Identidade Visual)
  final TextEditingController _nomeLojaCtrl = TextEditingController();
  final TextEditingController _sloganCtrl = TextEditingController();
  final TextEditingController _resumoConceitoCtrl = TextEditingController();
  final TextEditingController _heroImagemUrlCtrl = TextEditingController();
  final TextEditingController _heroVideoUrlCtrl = TextEditingController();
  final TextEditingController _logoUrlCtrl = TextEditingController();
  bool _aceitaPedidos = true;
  bool _aceitaReservas = true;
  List<Map<String, dynamic>> _pratosDestaque = [];

  // 2. Controladores: Sobre Nós, Chef & Galeria Multimédia
  final TextEditingController _tituloHistoriaCtrl = TextEditingController();
  final TextEditingController _historiaRestauranteCtrl =
      TextEditingController();
  final TextEditingController _origemPratosCtrl = TextEditingController();
  final TextEditingController _filosofiaEquipaCtrl = TextEditingController();
  final TextEditingController _chefNomeCtrl = TextEditingController();
  final TextEditingController _chefTituloCtrl = TextEditingController();
  final TextEditingController _chefBiografiaCtrl = TextEditingController();
  final TextEditingController _chefFotoUrlCtrl = TextEditingController();
  List<Map<String, dynamic>> _galeriaMidia = [];

  // 3. Controladores: Reservas de Mesas
  final TextEditingController _capacidadeMaxCtrl =
      TextEditingController(text: '20');
  final TextEditingController _zonasCtrl = TextEditingController();
  final TextEditingController _horariosReservaCtrl = TextEditingController();
  final TextEditingController _politicaReservaCtrl = TextEditingController();
  List<Map<String, dynamic>> _reservasRecebidas = [];

  // 4. Controladores: Localização, GPS, Contactos & Mensagens
  final TextEditingController _moradaCompletaCtrl = TextEditingController();
  final TextEditingController _pontoReferenciaCtrl = TextEditingController();
  final TextEditingController _telefoneCtrl = TextEditingController();
  final TextEditingController _whatsappCtrl = TextEditingController();
  final TextEditingController _emailContactoCtrl = TextEditingController();
  final TextEditingController _instagramCtrl = TextEditingController();
  final TextEditingController _websiteCtrl = TextEditingController();
  final TextEditingController _gpsLinkCtrl = TextEditingController();
  final TextEditingController _latitudeCtrl =
      TextEditingController(text: '-8.8368');
  final TextEditingController _longitudeCtrl =
      TextEditingController(text: '13.2343');
  List<Map<String, dynamic>> _mensagensClientes = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadStorefrontData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nomeLojaCtrl.dispose();
    _sloganCtrl.dispose();
    _resumoConceitoCtrl.dispose();
    _heroImagemUrlCtrl.dispose();
    _heroVideoUrlCtrl.dispose();
    _logoUrlCtrl.dispose();
    _tituloHistoriaCtrl.dispose();
    _historiaRestauranteCtrl.dispose();
    _origemPratosCtrl.dispose();
    _filosofiaEquipaCtrl.dispose();
    _chefNomeCtrl.dispose();
    _chefTituloCtrl.dispose();
    _chefBiografiaCtrl.dispose();
    _chefFotoUrlCtrl.dispose();
    _capacidadeMaxCtrl.dispose();
    _zonasCtrl.dispose();
    _horariosReservaCtrl.dispose();
    _politicaReservaCtrl.dispose();
    _moradaCompletaCtrl.dispose();
    _pontoReferenciaCtrl.dispose();
    _telefoneCtrl.dispose();
    _whatsappCtrl.dispose();
    _emailContactoCtrl.dispose();
    _instagramCtrl.dispose();
    _websiteCtrl.dispose();
    _gpsLinkCtrl.dispose();
    _latitudeCtrl.dispose();
    _longitudeCtrl.dispose();
    super.dispose();
  }

  Future<Dio> _buildAuthDio() async {
    final token = await _tokenStorage.getAccessToken();
    return Dio(
      BaseOptions(
        baseUrl: AppEnvironmentConfig.baseHttpUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          if (token != null && token.isNotEmpty)
            'Authorization': 'Bearer $token',
        },
      ),
    );
  }

  Future<void> _loadStorefrontData() async {
    setState(() => _isLoading = true);
    try {
      final dio = await _buildAuthDio();
      final resp = await dio.get<Map<String, dynamic>>(
        '/api/v1/partner/store/storefront/',
      );
      final data = resp.data;
      if (data != null && mounted) {
        _populateFields(data);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Aviso ao carregar vitrine: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _populateFields(Map<String, dynamic> data) {
    _lojaId = (data['loja_id'] ?? '').toString();
    _nomeLojaCtrl.text = (data['nome_loja'] ?? 'Meu Restaurante').toString();

    final vitrine = data['vitrine'] is Map<String, dynamic>
        ? data['vitrine'] as Map<String, dynamic>
        : <String, dynamic>{};

    final home = vitrine['identidade_home'] is Map<String, dynamic>
        ? vitrine['identidade_home'] as Map<String, dynamic>
        : <String, dynamic>{};
    final sobre = vitrine['sobre_nos'] is Map<String, dynamic>
        ? vitrine['sobre_nos'] as Map<String, dynamic>
        : <String, dynamic>{};
    final res = vitrine['config_reservas'] is Map<String, dynamic>
        ? vitrine['config_reservas'] as Map<String, dynamic>
        : <String, dynamic>{};
    final loc = vitrine['localizacao_contacto'] is Map<String, dynamic>
        ? vitrine['localizacao_contacto'] as Map<String, dynamic>
        : <String, dynamic>{};

    _sloganCtrl.text = (home['slogan'] ?? '').toString();
    _resumoConceitoCtrl.text = (home['resumo_conceito'] ?? '').toString();
    _heroImagemUrlCtrl.text = (home['hero_imagem_url'] ?? '').toString();
    _heroVideoUrlCtrl.text = (home['hero_video_url'] ?? '').toString();
    _logoUrlCtrl.text = (home['logo_url'] ?? '').toString();
    _aceitaPedidos = (home['aceita_pedidos'] as bool?) ?? true;
    _aceitaReservas = (home['aceita_reservas'] as bool?) ?? true;
    _pratosDestaque = ((home['pratos_destaque'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    _tituloHistoriaCtrl.text = (sobre['titulo_historia'] ?? '').toString();
    _historiaRestauranteCtrl.text =
        (sobre['historia_restaurante'] ?? '').toString();
    _origemPratosCtrl.text = (sobre['origem_pratos'] ?? '').toString();
    _filosofiaEquipaCtrl.text = (sobre['filosofia_equipa'] ?? '').toString();
    _chefNomeCtrl.text = (sobre['chef_nome'] ?? '').toString();
    _chefTituloCtrl.text = (sobre['chef_titulo'] ?? '').toString();
    _chefBiografiaCtrl.text = (sobre['chef_biografia'] ?? '').toString();
    _chefFotoUrlCtrl.text = (sobre['chef_foto_url'] ?? '').toString();
    _galeriaMidia = ((sobre['galeria_midia'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    _capacidadeMaxCtrl.text =
        ((res['capacidade_maxima_pessoas'] as num?)?.toInt() ?? 20).toString();
    final zonas = ((res['zonas_disponiveis'] as List<dynamic>?) ?? const [])
        .map((e) => e.toString())
        .toList();
    _zonasCtrl.text = zonas.join(', ');
    final horarios =
        ((res['horarios_disponiveis'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList();
    _horariosReservaCtrl.text = horarios.join(', ');
    _politicaReservaCtrl.text = (res['politica_reserva'] ?? '').toString();

    _moradaCompletaCtrl.text =
        (loc['morada_completa'] ?? data['morada_texto'] ?? '').toString();
    _pontoReferenciaCtrl.text = (loc['ponto_referencia'] ?? '').toString();
    _telefoneCtrl.text =
        (loc['telefone_principal'] ?? data['contacto'] ?? '').toString();
    _whatsappCtrl.text = (loc['whatsapp'] ?? '').toString();
    _emailContactoCtrl.text = (loc['email_contacto'] ?? '').toString();
    _instagramCtrl.text = (loc['instagram'] ?? '').toString();
    _websiteCtrl.text = (loc['website_url'] ?? '').toString();
    _gpsLinkCtrl.text = (loc['gps_link_externo'] ?? '').toString();
    _latitudeCtrl.text =
        ((loc['latitude'] as num?)?.toDouble() ?? -8.8368).toString();
    _longitudeCtrl.text =
        ((loc['longitude'] as num?)?.toDouble() ?? 13.2343).toString();

    _reservasRecebidas = ((data['reservas'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    _mensagensClientes = ((data['mensagens'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  Future<void> _saveAllChanges() async {
    setState(() => _isSaving = true);
    try {
      final dio = await _buildAuthDio();

      final zonasList = _zonasCtrl.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final horariosList = _horariosReservaCtrl.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      final payload = {
        'nome_loja': _nomeLojaCtrl.text.trim(),
        'vitrine': {
          'identidade_home': {
            'slogan': _sloganCtrl.text.trim(),
            'resumo_conceito': _resumoConceitoCtrl.text.trim(),
            'hero_imagem_url': _heroImagemUrlCtrl.text.trim(),
            'hero_video_url': _heroVideoUrlCtrl.text.trim(),
            'logo_url': _logoUrlCtrl.text.trim(),
            'aceita_pedidos': _aceitaPedidos,
            'aceita_reservas': _aceitaReservas,
            'pratos_destaque': _pratosDestaque,
          },
          'sobre_nos': {
            'titulo_historia': _tituloHistoriaCtrl.text.trim(),
            'historia_restaurante': _historiaRestauranteCtrl.text.trim(),
            'origem_pratos': _origemPratosCtrl.text.trim(),
            'filosofia_equipa': _filosofiaEquipaCtrl.text.trim(),
            'chef_nome': _chefNomeCtrl.text.trim(),
            'chef_titulo': _chefTituloCtrl.text.trim(),
            'chef_biografia': _chefBiografiaCtrl.text.trim(),
            'chef_foto_url': _chefFotoUrlCtrl.text.trim(),
            'galeria_midia': _galeriaMidia,
          },
          'config_reservas': {
            'capacidade_maxima_pessoas':
                int.tryParse(_capacidadeMaxCtrl.text.trim()) ?? 20,
            'zonas_disponiveis': zonasList,
            'horarios_disponiveis': horariosList,
            'politica_reserva': _politicaReservaCtrl.text.trim(),
          },
          'localizacao_contacto': {
            'morada_completa': _moradaCompletaCtrl.text.trim(),
            'ponto_referencia': _pontoReferenciaCtrl.text.trim(),
            'telefone_principal': _telefoneCtrl.text.trim(),
            'whatsapp': _whatsappCtrl.text.trim(),
            'email_contacto': _emailContactoCtrl.text.trim(),
            'instagram': _instagramCtrl.text.trim(),
            'website_url': _websiteCtrl.text.trim(),
            'gps_link_externo': _gpsLinkCtrl.text.trim(),
            'latitude': double.tryParse(_latitudeCtrl.text.trim()) ?? -8.8368,
            'longitude': double.tryParse(_longitudeCtrl.text.trim()) ?? 13.2343,
          },
        },
      };

      final resp = await dio.put<Map<String, dynamic>>(
        '/api/v1/partner/store/storefront/',
        data: payload,
      );

      if (resp.data != null && mounted) {
        _populateFields(resp.data!);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Todas as informações, imagens e vídeos foram publicados com sucesso!',
            ),
            backgroundColor: Color(0xFF16A34A),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao guardar alterações: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _updateReservationStatus(String reservaId, String estado) async {
    try {
      final dio = await _buildAuthDio();
      final resp = await dio.patch<Map<String, dynamic>>(
        '/api/v1/partner/store/storefront/',
        data: {
          'acao': 'atualizar_reserva',
          'reserva_id': reservaId,
          'estado': estado,
        },
      );
      if (resp.data != null && mounted) {
        setState(() {
          _reservasRecebidas =
              ((resp.data!['reservas'] as List<dynamic>?) ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .toList();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reserva $reservaId atualizada para $estado.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _replyToCustomerMessage(
    String mensagemId,
    String resposta,
  ) async {
    try {
      final dio = await _buildAuthDio();
      final resp = await dio.patch<Map<String, dynamic>>(
        '/api/v1/partner/store/storefront/',
        data: {
          'acao': 'responder_mensagem',
          'mensagem_id': mensagemId,
          'resposta_parceiro': resposta,
        },
      );
      if (resp.data != null && mounted) {
        setState(() {
          _mensagensClientes =
              ((resp.data!['mensagens'] as List<dynamic>?) ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map((m) => Map<String, dynamic>.from(m))
                  .toList();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Resposta registada com sucesso!'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {}
  }

  void _openCustomerPreview() {
    if (_lojaId.isEmpty) return;
    final previewStore = StoreSummaryModel(
      id: _lojaId,
      nome: _nomeLojaCtrl.text.trim().isNotEmpty
          ? _nomeLojaCtrl.text.trim()
          : 'Minha Loja',
      moradaTexto: _moradaCompletaCtrl.text.trim().isNotEmpty
          ? _moradaCompletaCtrl.text.trim()
          : 'Luanda, Angola',
      imagemUrl: _heroImagemUrlCtrl.text.trim().isNotEmpty
          ? _heroImagemUrlCtrl.text.trim()
          : 'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=800',
      tipoCozinha: 'Restaurante Parceiro',
      distanciaKm: 1.2,
      etaMinutosEstimado: 25,
      taxaEntregaCentimos: 50000,
      scoreReputacao: 5.0,
      isPatrocinado: false,
      isAberta: true,
    );

    final repo = CatalogRepository(baseUrl: AppEnvironmentConfig.baseHttpUrl);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RepositoryProvider<CatalogRepository>.value(
          value: repo,
          child: BlocProvider<StoreMenuBloc>(
            create: (_) => StoreMenuBloc(repository: repo)
              ..add(LoadStoreMenuEvent(storeId: _lojaId)),
            child: StoreMenuScreen(store: previewStore),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Vitrine Digital & CMS Total',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: 17,
            color: Color(0xFF0F172A),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: _openCustomerPreview,
            icon: const Icon(Icons.visibility_rounded, size: 18),
            label: const Text('Ver Loja'),
          ),
          IconButton(
            tooltip: 'Recarregar Dados',
            onPressed: _loadStorefrontData,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: const Color(0xFF1E88E5),
          unselectedLabelColor: const Color(0xFF64748B),
          indicatorColor: const Color(0xFF1E88E5),
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          tabs: [
            const Tab(
              icon: Icon(Icons.home_work_rounded, size: 18),
              text: '1. Home, Fotos & Vídeos',
            ),
            const Tab(
              icon: Icon(Icons.auto_stories_rounded, size: 18),
              text: '2. Sobre Nós, Chef & Galeria',
            ),
            Tab(
              icon: const Icon(Icons.event_seat_rounded, size: 18),
              text: '3. Reservas (${_reservasRecebidas.length})',
            ),
            Tab(
              icon: const Icon(Icons.location_on_rounded, size: 18),
              text: '4. Localização, GPS & Mensagens (${_mensagensClientes.length})',
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildHomeEditorTab(colorScheme),
                _buildAboutAndGalleryEditorTab(colorScheme),
                _buildReservationsManagerTab(colorScheme),
                _buildLocationAndMessagesTab(colorScheme),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 10,
                offset: const Offset(0, -3),
              ),
            ],
          ),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1E88E5),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _isSaving ? null : _saveAllChanges,
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.cloud_upload_rounded),
            label: Text(
              _isSaving
                  ? 'A Publicar na Loja...'
                  : 'Guardar e Publicar Todas as Alterações',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // ABA 1: EDITOR DA PÁGINA INICIAL (HOME), IDENTIDADE, FOTO E VÍDEO HERO
  // --------------------------------------------------------------------------
  Widget _buildHomeEditorTab(ColorScheme colorScheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _buildSectionCard(
          title: 'Identidade Visual & Conceito (Página Inicial)',
          subtitle:
              'Configure o nome, o slogan, o resumo do conceito e os botões de ação que o cliente vê ao entrar na loja.',
          children: [
            TextField(
              controller: _nomeLojaCtrl,
              decoration: const InputDecoration(
                labelText: 'Nome Comercial do Restaurante',
                prefixIcon: Icon(Icons.storefront_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sloganCtrl,
              decoration: const InputDecoration(
                labelText: 'Slogan / Título de Destaque na Home',
                prefixIcon: Icon(Icons.auto_awesome_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _resumoConceitoCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Resumo do Conceito Gastronómico',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Exibir Botão Direto para Pedidos Online'),
              subtitle: const Text(
                'Permite ao cliente saltar diretamente para o Cardápio',
              ),
              value: _aceitaPedidos,
              onChanged: (v) => setState(() => _aceitaPedidos = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Exibir Botão Direto para Reservas de Mesa'),
              subtitle: const Text(
                'Permite ao cliente agendar uma mesa online na loja',
              ),
              value: _aceitaReservas,
              onChanged: (v) => setState(() => _aceitaReservas = v),
            ),
          ],
        ),
        const SizedBox(height: 16),

        _buildSectionCard(
          title: 'Fotografia de Capa, Logótipo & Vídeo em Destaque',
          subtitle:
              'Insira os URLs das suas imagens e vídeos (ou escolha modelos profissionais de alta definição).',
          children: [
            if (_heroImagemUrlCtrl.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Image.network(
                      _heroImagemUrlCtrl.text.trim(),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                ),
              ),
            TextField(
              controller: _heroImagemUrlCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'URL da Fotografia Principal de Capa (Hero)',
                prefixIcon: Icon(Icons.image_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _heroVideoUrlCtrl,
              decoration: const InputDecoration(
                labelText: 'URL do Vídeo em Destaque dos Pratos Principais (MP4)',
                prefixIcon: Icon(Icons.videocam_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _logoUrlCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'URL do Logótipo do Restaurante',
                prefixIcon: Icon(Icons.verified_outlined),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        _buildSectionCard(
          title: 'Pratos em Destaque na Página Inicial (${_pratosDestaque.length})',
          subtitle:
              'Adicione ou edite cartões visuais de destaque na Home do restaurante.',
          children: [
            ..._pratosDestaque.asMap().entries.map((entry) {
              final idx = entry.key;
              final item = entry.value;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      (item['midia_url'] ?? '').toString(),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.restaurant_menu_rounded),
                    ),
                  ),
                  title: Text(
                    (item['titulo'] ?? '').toString(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text((item['subtitulo'] ?? '').toString()),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () {
                      setState(() => _pratosDestaque.removeAt(idx));
                    },
                  ),
                ),
              );
            }),
            OutlinedButton.icon(
              onPressed: _showAddFeaturedDishDialog,
              icon: const Icon(Icons.add_photo_alternate_rounded),
              label: const Text('Adicionar Prato/Vídeo em Destaque'),
            ),
          ],
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // ABA 2: EDITOR SOBRE NÓS, BIOGRAFIA DO CHEF E GALERIA MULTIMÉDIA
  // --------------------------------------------------------------------------
  Widget _buildAboutAndGalleryEditorTab(ColorScheme colorScheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _buildSectionCard(
          title: 'Sobre Nós (A Nossa História & Filosofia)',
          subtitle:
              'Conte a trajetória do restaurante, a origem dos ingredientes e a filosofia da equipa.',
          children: [
            TextField(
              controller: _tituloHistoriaCtrl,
              decoration: const InputDecoration(
                labelText: 'Título da Secção Sobre Nós',
                prefixIcon: Icon(Icons.title_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _historiaRestauranteCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'A Nossa História / Trajetória do Restaurante',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _origemPratosCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'A Origem dos Nossos Pratos & Ingredientes',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _filosofiaEquipaCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Filosofia da Equipa & Atendimento',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        _buildSectionCard(
          title: 'Biografia & Fotografia do Chef',
          subtitle:
              'Apresente o Chef responsável pela assinatura gastronómica da casa.',
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.network(
                    _chefFotoUrlCtrl.text.trim(),
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const CircleAvatar(
                      radius: 32,
                      child: Icon(Icons.person_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _chefNomeCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Nome do Chef',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _chefTituloCtrl,
              decoration: const InputDecoration(
                labelText: 'Cargo / Especialidade do Chef',
                prefixIcon: Icon(Icons.workspace_premium_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _chefFotoUrlCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'URL da Fotografia do Chef',
                prefixIcon: Icon(Icons.portrait_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _chefBiografiaCtrl,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Biografia Completa do Chef',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        _buildSectionCard(
          title: 'Galeria Multimédia — Fotos & Vídeos (${_galeriaMidia.length})',
          subtitle:
              'Adicione ou remova fotografias e vídeos do salão, esplanada e cozinha.',
          children: [
            ..._galeriaMidia.asMap().entries.map((entry) {
              final idx = entry.key;
              final media = entry.value;
              final isVideo =
                  (media['tipo'] ?? '').toString().toLowerCase() == 'video';
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Icon(
                    isVideo ? Icons.videocam_rounded : Icons.photo_rounded,
                    color: const Color(0xFF1E88E5),
                  ),
                  title: Text(
                    (media['legenda'] ?? 'Mídia').toString(),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    (media['url'] ?? '').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () {
                      setState(() => _galeriaMidia.removeAt(idx));
                    },
                  ),
                ),
              );
            }),
            OutlinedButton.icon(
              onPressed: _showAddGalleryMediaDialog,
              icon: const Icon(Icons.perm_media_rounded),
              label: const Text('Adicionar Fotografia ou Vídeo à Galeria'),
            ),
          ],
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // ABA 3: GESTOR DE RESERVAS DE MESAS ONLINE
  // --------------------------------------------------------------------------
  Widget _buildReservationsManagerTab(ColorScheme colorScheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _buildSectionCard(
          title: 'Configuração de Reservas de Mesas',
          subtitle:
              'Defina a capacidade máxima, horários disponíveis e ambientes da loja.',
          children: [
            TextField(
              controller: _capacidadeMaxCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Capacidade Máxima de Pessoas por Reserva',
                prefixIcon: Icon(Icons.groups_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _zonasCtrl,
              decoration: const InputDecoration(
                labelText: 'Ambientes / Zonas (separados por vírgula)',
                hintText: 'Salão Principal, Esplanada, Sala VIP',
                prefixIcon: Icon(Icons.deck_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _horariosReservaCtrl,
              decoration: const InputDecoration(
                labelText: 'Horários Disponíveis (separados por vírgula)',
                hintText: '12:00, 13:00, 19:00, 20:00, 21:00',
                prefixIcon: Icon(Icons.schedule_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _politicaReservaCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Política e Instruções de Reserva',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        _buildSectionCard(
          title: 'Reservas Agendadas pelos Clientes (${_reservasRecebidas.length})',
          subtitle:
              'Acompanhe e gira em tempo real as mesas reservadas pelos clientes.',
          children: [
            if (_reservasRecebidas.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Ainda não existem reservas agendadas.',
                  textAlign: TextAlign.center,
                ),
              )
            else
              ..._reservasRecebidas.map((res) {
                final id = (res['id'] ?? '').toString();
                final estado = (res['estado'] ?? 'CONFIRMADA').toString();
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '$id • ${res['nome_cliente'] ?? 'Cliente'}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                              ),
                            ),
                            Chip(
                              label: Text(
                                estado,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          'Data: ${res['data_reserva']} às ${res['horario']} • ${res['numero_pessoas']} pessoa(s)',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Ambiente: ${res['zona_preferida']} • Tel: ${res['telefone_cliente']}',
                        ),
                        if ((res['notas_especiais'] ?? '')
                            .toString()
                            .isNotEmpty)
                          Text('Notas: ${res['notas_especiais']}'),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: () =>
                                  _updateReservationStatus(id, 'CANCELADA'),
                              child: const Text(
                                'Cancelar',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: () =>
                                  _updateReservationStatus(id, 'CONCLUIDA'),
                              child: const Text('Marcar Concluída'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
          ],
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // ABA 4: LOCALIZAÇÃO, GPS, CONTACTOS E CAIXA DE MENSAGENS DE CLIENTES
  // --------------------------------------------------------------------------
  Widget _buildLocationAndMessagesTab(ColorScheme colorScheme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      children: [
        _buildSectionCard(
          title: 'Localização Exata, Coordenadas GPS & Contactos',
          subtitle:
              'Atualize a morada física, link de GPS (Google Maps) e todos os canais de contacto da loja.',
          children: [
            TextField(
              controller: _moradaCompletaCtrl,
              decoration: const InputDecoration(
                labelText: 'Morada Física Completa',
                prefixIcon: Icon(Icons.location_on_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pontoReferenciaCtrl,
              decoration: const InputDecoration(
                labelText: 'Ponto de Referência / Estacionamento',
                prefixIcon: Icon(Icons.place_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _latitudeCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Latitude GPS',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _longitudeCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Longitude GPS',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _gpsLinkCtrl,
              decoration: const InputDecoration(
                labelText: 'Link Direto para GPS (Google Maps / Waze)',
                prefixIcon: Icon(Icons.map_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _telefoneCtrl,
              decoration: const InputDecoration(
                labelText: 'Número de Telefone Principal',
                prefixIcon: Icon(Icons.phone_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _whatsappCtrl,
              decoration: const InputDecoration(
                labelText: 'WhatsApp de Atendimento',
                prefixIcon: Icon(Icons.chat_rounded),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailContactoCtrl,
              decoration: const InputDecoration(
                labelText: 'E-mail Comercial',
                prefixIcon: Icon(Icons.email_outlined),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _instagramCtrl,
              decoration: const InputDecoration(
                labelText: 'Instagram / Redes Sociais',
                prefixIcon: Icon(Icons.camera_alt_outlined),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        _buildSectionCard(
          title: 'Mensagens Recebidas de Clientes (${_mensagensClientes.length})',
          subtitle:
              'Mensagens enviadas pelos clientes através do formulário de contacto da loja.',
          children: [
            if (_mensagensClientes.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Nenhuma mensagem recebida até ao momento.',
                  textAlign: TextAlign.center,
                ),
              )
            else
              ..._mensagensClientes.map((msg) {
                final msgId = (msg['id'] ?? '').toString();
                final respostaAtual =
                    (msg['resposta_parceiro'] ?? '').toString();
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    title: Text(
                      '${msg['assunto']} — ${msg['nome']} (${msg['contacto']})',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text((msg['mensagem'] ?? '').toString()),
                        if (respostaAtual.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            'A sua resposta: $respostaAtual',
                            style: const TextStyle(
                              color: Color(0xFF16A34A),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                    trailing: IconButton(
                      tooltip: 'Responder ao Cliente',
                      icon: const Icon(Icons.reply_rounded),
                      onPressed: () async {
                        final replyCtrl =
                            TextEditingController(text: respostaAtual);
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('Responder a ${msg['nome']}'),
                            content: TextField(
                              controller: replyCtrl,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                labelText: 'A sua resposta',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(false),
                                child: const Text('Cancelar'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.of(ctx).pop(true),
                                child: const Text('Guardar Resposta'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          _replyToCustomerMessage(
                            msgId,
                            replyCtrl.text.trim(),
                          );
                        }
                      },
                    ),
                  ),
                );
              }),
          ],
        ),
      ],
    );
  }

  Widget _buildSectionCard({
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Future<void> _showAddFeaturedDishDialog() async {
    final tituloCtrl = TextEditingController();
    final subtituloCtrl = TextEditingController();
    final precoCtrl = TextEditingController(text: '350000');
    final urlCtrl = TextEditingController(
      text: 'https://images.unsplash.com/photo-1544025162-d76694265947?w=800',
    );

    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Adicionar Destaque na Home'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tituloCtrl,
                decoration: const InputDecoration(labelText: 'Nome do Prato'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: subtituloCtrl,
                decoration:
                    const InputDecoration(labelText: 'Resumo / Ingredientes'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: precoCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Preço em Cêntimos (ex.: 350000 = 3.500 Kz)',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'URL da Fotografia ou Vídeo',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Adicionar'),
          ),
        ],
      ),
    );

    if (added == true && tituloCtrl.text.trim().isNotEmpty) {
      setState(() {
        _pratosDestaque.add({
          'titulo': tituloCtrl.text.trim(),
          'subtitulo': subtituloCtrl.text.trim(),
          'preco': int.tryParse(precoCtrl.text.trim()) ?? 350000,
          'midia_url': urlCtrl.text.trim(),
          'tipo_midia': 'imagem',
        });
      });
    }
  }

  Future<void> _showAddGalleryMediaDialog() async {
    final legendaCtrl = TextEditingController();
    final urlCtrl = TextEditingController(
      text: 'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=800',
    );
    String tipo = 'imagem';

    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          title: const Text('Adicionar Foto ou Vídeo à Galeria'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'imagem',
                      label: Text('Fotografia'),
                      icon: Icon(Icons.photo_rounded),
                    ),
                    ButtonSegment(
                      value: 'video',
                      label: Text('Vídeo'),
                      icon: Icon(Icons.videocam_rounded),
                    ),
                  ],
                  selected: {tipo},
                  onSelectionChanged: (s) =>
                      setModalState(() => tipo = s.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: legendaCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Legenda / Descrição',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'URL da Fotografia ou Vídeo',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Adicionar à Galeria'),
            ),
          ],
        ),
      ),
    );

    if (added == true && urlCtrl.text.trim().isNotEmpty) {
      setState(() {
        _galeriaMidia.add({
          'tipo': tipo,
          'legenda': legendaCtrl.text.trim().isEmpty
              ? 'Espaço & Gastronomia'
              : legendaCtrl.text.trim(),
          'url': urlCtrl.text.trim(),
        });
      });
    }
  }
}
