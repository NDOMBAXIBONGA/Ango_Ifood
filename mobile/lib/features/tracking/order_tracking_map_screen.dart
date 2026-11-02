/// Ecrã de Acompanhamento do Pedido em Tempo Real (`OrderTrackingMapScreen`)
/// em Flutter utilizando Google Maps e Django Channels WebSockets.
///
/// Implementa rigorosamente:
/// - RN-094: Rastreamento em tempo real do estafeta durante o transporte com transmissões a cada 5 segundos.
/// - RN-029: Recálculo contínuo do tempo estimado de chegada (ETA) e distância restante.
/// - Secção 4 (Passo 9): Acompanhamento visual da rota (Loja -> Estafeta -> Cliente) e estado da entrega.
/// - Secção 12.1: Consumo do evento 'delivery.location_updated'.
/// - Interpolação suave de marcadores no mapa (Smooth Marker Animation) com rotação realista (bearing).
/// - Conexão WebSocket resiliente com reconexão automática e autenticação JWT.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

// ============================================================================
// 1. MODELOS DE DADOS DE RASTREAMENTO EM TEMPO REAL (SECÇÃO 12.1 & RN-094)
// ============================================================================

enum StatusEntregaVisual {
  emPreparacao,
  aguardandoRecolha,
  aCaminho,
  chegouAoDestino,
  entregue,
}

class CourierLocationUpdate {
  final String estafetaId;
  final String estafetaNome;
  final LatLng posicao;
  final double heading;
  final double velocidadeKmh;
  final double precisaoMetros;
  final DateTime timestamp;

  const CourierLocationUpdate({
    required this.estafetaId,
    required this.estafetaNome,
    required this.posicao,
    required this.heading,
    required this.velocidadeKmh,
    required this.precisaoMetros,
    required this.timestamp,
  });

  factory CourierLocationUpdate.fromJson(Map<String, dynamic> json) {
    final geo = json['geolocalizacao'] as Map<String, dynamic>? ?? {};
    final lat = (geo['latitude'] as num?)?.toDouble() ?? 0.0;
    final lng = (geo['longitude'] as num?)?.toDouble() ?? 0.0;

    return CourierLocationUpdate(
      estafetaId: json['estafeta_id']?.toString() ?? '',
      estafetaNome: json['estafeta_nome']?.toString() ?? 'Estafeta',
      posicao: LatLng(lat, lng),
      heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
      velocidadeKmh: (json['velocidade_kmh'] as num?)?.toDouble() ?? 0.0,
      precisaoMetros: (json['precisao_metros'] as num?)?.toDouble() ?? 5.0,
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class TrackingInitialData {
  final String entregaId;
  final String estadoEntrega;
  final int distanciaMetros;
  final DateTime? etaTimestamp;
  final LatLng? posicaoEstafeta;
  final String? estafetaNome;
  final String? estafetaVeiculo;

  const TrackingInitialData({
    required this.entregaId,
    required this.estadoEntrega,
    required this.distanciaMetros,
    this.etaTimestamp,
    this.posicaoEstafeta,
    this.estafetaNome,
    this.estafetaVeiculo,
  });

  factory TrackingInitialData.fromJson(Map<String, dynamic> json) {
    final estafetaJson = json['estafeta'] as Map<String, dynamic>?;
    LatLng? pos;
    if (estafetaJson != null && estafetaJson['ultima_geolocalizacao'] != null) {
      final geo = estafetaJson['ultima_geolocalizacao'] as Map<String, dynamic>;
      pos = LatLng(
        (geo['latitude'] as num).toDouble(),
        (geo['longitude'] as num).toDouble(),
      );
    }

    return TrackingInitialData(
      entregaId: json['entrega_id']?.toString() ?? '',
      estadoEntrega: json['estado_entrega']?.toString() ?? 'EM_TRANSITO',
      distanciaMetros: (json['distancia_metros'] as num?)?.toInt() ?? 0,
      etaTimestamp: json['eta_timestamp'] != null ? DateTime.tryParse(json['eta_timestamp']) : null,
      posicaoEstafeta: pos,
      estafetaNome: estafetaJson?['nome']?.toString(),
      estafetaVeiculo: estafetaJson?['tipo_veiculo']?.toString(),
    );
  }
}

// ============================================================================
// 2. UTILITÁRIOS MATEMÁTICOS DE GEOLOCALIZAÇÃO E INTERPOLAÇÃO (SMOOTH MARKER)
// ============================================================================

class GeoMathUtils {
  const GeoMathUtils._();

  static const double _earthRadiusMeters = 6371000.0;

  /// Calcula a distância em metros entre dois pontos geográficos (Fórmula de Haversine)
  static double calcularDistanciaMetros(LatLng p1, LatLng p2) {
    final dLat = _grausParaRadianos(p2.latitude - p1.latitude);
    final dLng = _grausParaRadianos(p2.longitude - p1.longitude);

    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_grausParaRadianos(p1.latitude)) *
            math.cos(_grausParaRadianos(p2.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return _earthRadiusMeters * c;
  }

  /// Calcula o ângulo azimutal (Bearing / Rotação) entre duas coordenadas em graus (0° a 360°)
  static double calcularBearing(LatLng inicio, LatLng fim) {
    final lat1 = _grausParaRadianos(inicio.latitude);
    final lat2 = _grausParaRadianos(fim.latitude);
    final dLng = _grausParaRadianos(fim.longitude - inicio.longitude);

    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);

    final radianos = math.atan2(y, x);
    return (_radianosParaGraus(radianos) + 360) % 360;
  }

  /// Interpola linearmente entre duas posições geográficas (t de 0.0 a 1.0)
  static LatLng interpolarPosicao(LatLng inicio, LatLng fim, double t) {
    final lat = inicio.latitude + (fim.latitude - inicio.latitude) * t;
    final lng = inicio.longitude + (fim.longitude - inicio.longitude) * t;
    return LatLng(lat, lng);
  }

  /// Interpola o ângulo de rotação pelo caminho circular mais curto
  static double interpolarAngulo(double anguloInicial, double anguloFinal, double t) {
    final diff = ((anguloFinal - anguloInicial + 540) % 360) - 180;
    return (anguloInicial + diff * t + 360) % 360;
  }

  static double _grausParaRadianos(double graus) => graus * math.pi / 180.0;
  static double _radianosParaGraus(double radianos) => radianos * 180.0 / math.pi;
}

// ============================================================================
// 3. WIDGET PRINCIPAL: ORDER TRACKING MAP SCREEN
// ============================================================================

class OrderTrackingMapScreen extends StatefulWidget {
  final String pedidoId;
  final String jwtAccessToken;
  final String wsBaseUrl; // ex.: 'ws://10.0.2.2:8000' ou 'wss://api.meudelivery.ao'
  final String nomeLoja;
  final LatLng localizacaoLoja;
  final String moradaCliente;
  final LatLng localizacaoCliente;
  final String pinConfirmacao; // PIN de 4 dígitos para confirmação segura (RN-095)

  const OrderTrackingMapScreen({
    super.key,
    required this.pedidoId,
    required this.jwtAccessToken,
    this.wsBaseUrl = 'ws://10.0.2.2:8000',
    required this.nomeLoja,
    required this.localizacaoLoja,
    required this.moradaCliente,
    required this.localizacaoCliente,
    this.pinConfirmacao = '4829',
  });

  @override
  State<OrderTrackingMapScreen> createState() => _OrderTrackingMapScreenState();
}

class _OrderTrackingMapScreenState extends State<OrderTrackingMapScreen> with TickerProviderStateMixin {
  // Controlador do Mapa Google
  GoogleMapController? _mapController;
  final Map<MarkerId, Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  // Ícones de Marcadores Customizados
  BitmapDescriptor? _lojaIcon;
  BitmapDescriptor? _clienteIcon;
  BitmapDescriptor? _motaIcon;

  // Estado da Conexão WebSockets
  WebSocketChannel? _wsChannel;
  StreamSubscription? _wsSubscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  bool _isReconnecting = false;

  // Posição e Rotação do Estafeta com Interpolação Suave (Smooth Marker Animation)
  late AnimationController _markerAnimController;
  LatLng? _courierCurrentPos;
  LatLng? _courierTargetPos;
  double _courierCurrentBearing = 0.0;
  double _courierTargetBearing = 0.0;
  String _courierNome = 'Estafeta';
  String _courierVeiculo = 'Mota';

  // Métricas em Tempo Real (RN-029)
  int _distanciaRestanteMetros = 0;
  int _etaMinutosEstimados = 12;
  double _velocidadeAtualKmh = 0.0;
  StatusEntregaVisual _statusVisual = StatusEntregaVisual.aCaminho;

  @override
  void initState() {
    super.initState();
    _inicializarAnimacaoMarcador();
    _carregarIconesPersonalizados();
    _iniciarConexaoWebSocket();
  }

  @override
  void dispose() {
    _markerAnimController.dispose();
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _wsSubscription?.cancel();
    _wsChannel?.sink.close(ws_status.normalClosure);
    _mapController?.dispose();
    super.dispose();
  }

  // ==========================================================================
  // INICIALIZAÇÃO DE MARCADORES E ANIMAÇÕES SUAVES
  // ==========================================================================

  void _inicializarAnimacaoMarcador() {
    _markerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800), // Suaviza os saltos de 5s (RN-094)
    )..addListener(() {
        if (_courierCurrentPos == null || _courierTargetPos == null) return;

        final t = Curves.easeInOut.transform(_markerAnimController.value);
        final posInterpolada = GeoMathUtils.interpolarPosicao(_courierCurrentPos!, _courierTargetPos!, t);
        final rotInterpolada = GeoMathUtils.interpolarAngulo(_courierCurrentBearing, _courierTargetBearing, t);

        _atualizarMarcadorEstafeta(posInterpolada, rotInterpolada);
      });
  }

  Future<void> _carregarIconesPersonalizados() async {
    try {
      _lojaIcon = await _criarMarcadorCircularComIcone(
        Icons.storefront_rounded,
        Colors.orange.shade700,
        Colors.white,
      );
      _clienteIcon = await _criarMarcadorCircularComIcone(
        Icons.home_rounded,
        Colors.green.shade600,
        Colors.white,
      );
      _motaIcon = await _criarMarcadorCircularComIcone(
        Icons.two_wheeler_rounded,
        const Color(0xFF1E88E5),
        Colors.white,
      );
    } catch (e) {
      debugPrint('Erro ao carregar ícones customizados: $e');
      _lojaIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange);
      _clienteIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
      _motaIcon = BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
    }

    _desenharMarcadoresIniciais();
  }

  Future<BitmapDescriptor> _criarMarcadorCircularComIcone(
    IconData iconData,
    Color corFundo,
    Color corIcone,
  ) async {
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);
    const size = 110.0;
    const center = Offset(size / 2, size / 2);

    // Sombra externa
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(center.translate(0, 3), (size / 2) - 8, shadowPaint);

    // Círculo de fundo
    final backgroundPaint = Paint()..color = corFundo;
    canvas.drawCircle(center, (size / 2) - 8, backgroundPaint);

    // Borda branca destacada
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0;
    canvas.drawCircle(center, (size / 2) - 8, borderPaint);

    // Ícone desenhado via TextPainter com a fonte MaterialIcons
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: String.fromCharCode(iconData.codePoint),
      style: TextStyle(
        fontSize: 52.0,
        fontFamily: iconData.fontFamily,
        color: corIcone,
      ),
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset((size - textPainter.width) / 2, (size - textPainter.height) / 2),
    );

    final picture = pictureRecorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  void _desenharMarcadoresIniciais() {
    setState(() {
      // Marcador da Loja
      _markers[const MarkerId('store')] = Marker(
        markerId: const MarkerId('store'),
        position: widget.localizacaoLoja,
        icon: _lojaIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(
          title: widget.nomeLoja,
          snippet: 'Ponto de Confeção e Recolha',
        ),
      );

      // Marcador da Casa do Cliente
      _markers[const MarkerId('client_home')] = Marker(
        markerId: const MarkerId('client_home'),
        position: widget.localizacaoCliente,
        icon: _clienteIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: InfoWindow(
          title: 'Meu Endereço de Entrega',
          snippet: widget.moradaCliente,
        ),
      );
    });

    _tracarRotaLinha();
  }

  void _tracarRotaLinha() {
    final pontosRota = <LatLng>[
      widget.localizacaoLoja,
      if (_courierCurrentPos != null) _courierCurrentPos!,
      widget.localizacaoCliente,
    ];

    setState(() {
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('route_tracking'),
          points: pontosRota,
          color: const Color(0xFF1E88E5),
          width: 5,
          jointType: JointType.round,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
        ),
      );
    });
  }

  // ==========================================================================
  // CONEXÃO WEBSOCKET EM TEMPO REAL (DJANGO CHANNELS - RN-094 & SECÇÃO 12.1)
  // ==========================================================================

  void _iniciarConexaoWebSocket() {
    _reconnectTimer?.cancel();

    final wsUrl = '${widget.wsBaseUrl}/ws/delivery/tracking/${widget.pedidoId}/?token=${widget.jwtAccessToken}';
    debugPrint('A conectar ao WebSocket de Tracking: $wsUrl');

    try {
      _wsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));

      _wsSubscription = _wsChannel!.stream.listen(
        (dynamic mensagem) {
          _tratarMensagemWebSocket(mensagem);
        },
        onDone: () {
          debugPrint('Conexão WebSocket fechada pelo servidor.');
          _agendarReconexao();
        },
        onError: (error) {
          debugPrint('Erro na conexão WebSocket: $error');
          _agendarReconexao();
        },
      );

      setState(() {
        _isConnected = true;
        _isReconnecting = false;
      });

      _iniciarHeartbeat();
    } catch (e) {
      debugPrint('Falha ao instanciar WebSocket: $e');
      _agendarReconexao();
    }
  }

  void _iniciarHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (timer) {
      if (_isConnected && _wsChannel != null) {
        _wsChannel!.sink.add(jsonEncode({'action': 'ping'}));
      }
    });
  }

  void _agendarReconexao() {
    if (!mounted) return;

    setState(() {
      _isConnected = false;
      _isReconnecting = true;
    });

    _heartbeatTimer?.cancel();
    _wsSubscription?.cancel();

    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        debugPrint('Tentando reconectar WebSocket...');
        _iniciarConexaoWebSocket();
      }
    });
  }

  void _tratarMensagemWebSocket(dynamic mensagemRaw) {
    if (mensagemRaw == null) return;

    try {
      final Map<String, dynamic> data = jsonDecode(mensagemRaw.toString());
      final evento = data['event']?.toString();

      if (evento == 'connection_established') {
        final iniciaisJson = data['dados_iniciais'] as Map<String, dynamic>?;
        if (iniciaisJson != null) {
          final initial = TrackingInitialData.fromJson(iniciaisJson);
          _aplicarDadosIniciais(initial);
        }
      } else if (evento == 'delivery.location_updated') {
        // Evento oficial emitido a cada 5 segundos pelo estafeta (RN-094 / Secção 12.1)
        final update = CourierLocationUpdate.fromJson(data);
        _processarAtualizacaoEstafeta(update);
      } else if (evento == 'pong') {
        // Resposta do servidor ao heartbeat
      }
    } catch (e) {
      debugPrint('Erro ao desserializar mensagem WebSocket: $e');
    }
  }

  void _aplicarDadosIniciais(TrackingInitialData initial) {
    setState(() {
      _courierNome = initial.estafetaNome ?? _courierNome;
      _courierVeiculo = initial.estafetaVeiculo ?? _courierVeiculo;
      _distanciaRestanteMetros = initial.distanciaMetros;

      if (initial.etaTimestamp != null) {
        final diff = initial.etaTimestamp!.difference(DateTime.now()).inMinutes;
        _etaMinutosEstimados = math.max(1, diff);
      }
    });

    if (initial.posicaoEstafeta != null) {
      _courierCurrentPos = initial.posicaoEstafeta;
      _courierTargetPos = initial.posicaoEstafeta;
      _courierCurrentBearing = GeoMathUtils.calcularBearing(initial.posicaoEstafeta!, widget.localizacaoCliente);
      _atualizarMarcadorEstafeta(_courierCurrentPos!, _courierCurrentBearing);
      _ajustarCamaraEnquadramento();
    }
  }

  // ==========================================================================
  // ANIMAÇÃO SUAVE DE INTERPOLAÇÃO DO MARCADOR (SMOOTH MARKER ANIMATION)
  // ==========================================================================

  void _processarAtualizacaoEstafeta(CourierLocationUpdate update) {
    final novaPosicao = update.posicao;

    // Se é a primeira posição recebida
    if (_courierCurrentPos == null) {
      _courierCurrentPos = novaPosicao;
      _courierTargetPos = novaPosicao;
      _courierCurrentBearing = update.heading > 0
          ? update.heading
          : GeoMathUtils.calcularBearing(novaPosicao, widget.localizacaoCliente);
      _atualizarMarcadorEstafeta(novaPosicao, _courierCurrentBearing);
      _ajustarCamaraEnquadramento();
      _recalcularMetricas(novaPosicao, update.velocidadeKmh);
      return;
    }

    // Prepara a interpolação suave do ponto atual para o novo ponto
    _courierCurrentPos = _courierTargetPos ?? _courierCurrentPos;
    _courierTargetPos = novaPosicao;

    // Determina o novo ângulo de rotação (heading real do GPS ou bearing vetorial)
    _courierCurrentBearing = _courierTargetBearing;
    _courierTargetBearing = update.heading > 0
        ? update.heading
        : GeoMathUtils.calcularBearing(_courierCurrentPos!, novaPosicao);

    // Dispara a animação fluida do marcador
    _markerAnimController.stop();
    _markerAnimController.reset();
    _markerAnimController.forward();

    _recalcularMetricas(novaPosicao, update.velocidadeKmh);
    _tracarRotaLinha();
  }

  void _atualizarMarcadorEstafeta(LatLng posicao, double rotacao) {
    setState(() {
      _markers[const MarkerId('courier')] = Marker(
        markerId: const MarkerId('courier'),
        position: posicao,
        icon: _motaIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
        rotation: rotacao,
        flat: true, // Garante que o ícone roda colado à superfície do mapa
        anchor: const Offset(0.5, 0.5),
        zIndex: 10,
        infoWindow: InfoWindow(
          title: '$_courierNome ($_courierVeiculo)',
          snippet: 'Velocidade: ${_velocidadeAtualKmh.toStringAsFixed(1)} km/h',
        ),
      );
    });
  }

  void _recalcularMetricas(LatLng posicaoEstafeta, double velocidadeKmh) {
    // Calcula distância direta em linha até o cliente
    final distanciaMetros = GeoMathUtils.calcularDistanciaMetros(
      posicaoEstafeta,
      widget.localizacaoCliente,
    );

    // Estima tempo restante (RN-029):
    // Se estiver a andar (ex: > 10 km/h), usa velocidade real com fator de tráfego de 1.3x.
    // Se parado em semáforo ou engarrafado, adota velocidade média urbana de 25 km/h.
    final velEfetiva = velocidadeKmh >= 10.0 ? velocidadeKmh : 25.0;
    final horas = (distanciaMetros / 1000.0) / velEfetiva;
    final minutos = (horas * 60.0 * 1.3).round();

    setState(() {
      _distanciaRestanteMetros = distanciaMetros.round();
      _velocidadeAtualKmh = velocidadeKmh;
      _etaMinutosEstimados = math.max(1, minutos);

      if (_distanciaRestanteMetros <= 80) {
        _statusVisual = StatusEntregaVisual.chegouAoDestino;
      } else {
        _statusVisual = StatusEntregaVisual.aCaminho;
      }
    });
  }

  void _ajustarCamaraEnquadramento() {
    if (_mapController == null) return;

    final pontos = <LatLng>[
      widget.localizacaoLoja,
      widget.localizacaoCliente,
      if (_courierTargetPos != null) _courierTargetPos!,
    ];

    double minLat = pontos.first.latitude;
    double maxLat = pontos.first.latitude;
    double minLng = pontos.first.longitude;
    double maxLng = pontos.first.longitude;

    for (final p in pontos) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, 80.0),
    );
  }

  // ==========================================================================
  // CONSTRUÇÃO VISUAL (UI MATERIAL DESIGN 3)
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Stack(
        children: [
          // 1. MAPA INTERATIVO GOOGLE MAPS
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: widget.localizacaoLoja,
              zoom: 14.5,
            ),
            markers: Set<Marker>.of(_markers.values),
            polylines: _polylines,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: true,
            mapToolbarEnabled: false,
            onMapCreated: (controller) {
              _mapController = controller;
              _ajustarCamaraEnquadramento();
            },
          ),

          // 2. BARRA SUPERIOR SUSPENSA: BOTÃO VOLTAR E INDICADOR WEBSOCKET
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.white,
                    radius: 22,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Colors.black87),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  _buildIndicadorConexaoLive(theme),
                ],
              ),
            ),
          ),

          // 3. BOTÃO DE REENQUADRAMENTO RÁPIDO DO MAPA
          Positioned(
            right: 16,
            bottom: 300,
            child: FloatingActionButton.small(
              heroTag: 'recenter_map',
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF1E88E5),
              elevation: 4,
              onPressed: _ajustarCamaraEnquadramento,
              child: const Icon(Icons.center_focus_strong_rounded),
            ),
          ),

          // 4. PAINEL INFERIOR DE ESTADO E ETA (RN-029)
          Align(
            alignment: Alignment.bottomCenter,
            child: _buildPainelInferiorAcompanhamento(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildIndicadorConexaoLive(ThemeData theme) {
    final color = _isConnected
        ? Colors.green.shade600
        : (_isReconnecting ? Colors.orange.shade700 : Colors.red.shade600);
    final texto = _isConnected
        ? 'GPS EM TEMPO REAL'
        : (_isReconnecting ? 'A RECONECTAR...' : 'OFFLINE');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            texto,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPainelInferiorAcompanhamento(ThemeData theme) {
    final distanciaTexto = _distanciaRestanteMetros >= 1000
        ? '${(_distanciaRestanteMetros / 1000.0).toStringAsFixed(1)} km'
        : '$_distanciaRestanteMetros metros';

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Barra de arrasto
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),

              // Cabeçalho de ETA e Distância (RN-029)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusVisual == StatusEntregaVisual.chegouAoDestino
                            ? 'O estafeta chegou!'
                            : 'Chegada estimada em',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            _statusVisual == StatusEntregaVisual.chegouAoDestino
                                ? 'À sua porta'
                                : '$_etaMinutosEstimados min',
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1E88E5),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '($distanciaTexto)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  _buildBadgeStatusPedido(),
                ],
              ),
              const SizedBox(height: 16),

              // Barra de progresso dos 4 passos
              _buildBarraProgressoPassos(),
              const SizedBox(height: 18),

              const Divider(height: 1),
              const SizedBox(height: 14),

              // Cartão do Estafeta com Ações Rápidas
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.blue.shade50,
                    child: const Icon(Icons.person_rounded, size: 28, color: Color(0xFF1E88E5)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _courierNome,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Condutor de $_courierVeiculo • ⭐ 4.9',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                  // Botão de Chamada
                  IconButton.filledTonal(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('A ligar para $_courierNome...')),
                      );
                    },
                    icon: const Icon(Icons.phone_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.green.shade50,
                      foregroundColor: Colors.green.shade700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Botão de Mensagem
                  IconButton.filledTonal(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Abrindo chat com o estafeta...')),
                      );
                    },
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.blue.shade50,
                      foregroundColor: const Color(0xFF1E88E5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Cartão do PIN de Confirmação de Entrega (RN-095)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Row(
                  children: [
                    Icon(Icons.pin_rounded, color: Colors.amber.shade900, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Indique este PIN ao estafeta:',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.amber.shade900),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.amber.shade400),
                      ),
                      child: Text(
                        widget.pinConfirmacao,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.0,
                          color: Colors.black87,
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

  Widget _buildBadgeStatusPedido() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E88E5).withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.moped_rounded, size: 16, color: Color(0xFF1E88E5)),
          SizedBox(width: 6),
          Text(
            'A Caminho',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E88E5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBarraProgressoPassos() {
    return Row(
      children: [
        _buildItemPasso(concluido: true, label: 'Aceite'),
        _buildConectorPasso(ativo: true),
        _buildItemPasso(concluido: true, label: 'Preparado'),
        _buildConectorPasso(ativo: true),
        _buildItemPasso(concluido: true, label: 'A Caminho', atual: true),
        _buildConectorPasso(ativo: false),
        _buildItemPasso(concluido: false, label: 'Entregue'),
      ],
    );
  }

  Widget _buildItemPasso({required bool concluido, required String label, bool atual = false}) {
    final cor = concluido ? const Color(0xFF1E88E5) : Colors.grey.shade300;

    return Column(
      children: [
        CircleAvatar(
          radius: atual ? 8 : 6,
          backgroundColor: cor,
          child: atual
              ? const CircleAvatar(
                  radius: 4,
                  backgroundColor: Colors.white,
                )
              : null,
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: atual ? FontWeight.bold : FontWeight.w500,
            color: atual ? const Color(0xFF1E88E5) : Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildConectorPasso({required bool ativo}) {
    return Expanded(
      child: Container(
        height: 2,
        margin: const EdgeInsets.only(bottom: 14),
        color: ativo ? const Color(0xFF1E88E5) : Colors.grey.shade300,
      ),
    );
  }
}

