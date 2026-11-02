/// Ecrã de Acompanhamento em Tempo Real do Pedido (`OrderRealTimeTrackingScreen`)
/// para a aplicação móvel do Cliente em Flutter.
///
/// Implementa com rigor técnico:
/// - Secção 4: Jornada Ponta-a-Ponta do Cliente (Passo 9: Acompanhamento em Tempo Real);
/// - Regra RN-094: Rastreamento em tempo real do estafeta via WebSockets a cada 5-10s;
/// - Regra RN-029: Recálculo contínuo do ETA (tempo estimado de chegada);
/// - Regra RN-095: Exibição visual do PIN de segurança de 4 dígitos para validação da entrega;
/// - Interpolação Linear Suave (LERP) de coordenadas GPS no Google Maps, eliminando saltos bruscos;
/// - Gestão de Estado BLoC (`flutter_bloc`) e ciclo de vida seguro com `web_socket_channel`.
library order_real_time_tracking_screen;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ============================================================================
// 1. MODELO DE DADOS: TrackingLocationModel (Secção 12.1)
// ============================================================================

class TrackingLocationModel extends Equatable {
  final String pedidoId;
  final String estafetaId;
  final double latitude;
  final double longitude;
  final double heading;
  final double speed;
  final double precisaoMetros;
  final DateTime timestamp;

  const TrackingLocationModel({
    required this.pedidoId,
    required this.estafetaId,
    required this.latitude,
    required this.longitude,
    required this.heading,
    required this.speed,
    required this.precisaoMetros,
    required this.timestamp,
  });

  LatLng get toLatLng => LatLng(latitude, longitude);

  factory TrackingLocationModel.fromJson(Map<String, dynamic> json) {
    // Trata latitude e longitude com tolerância a chaves curtas ou aninhadas
    double extractDouble(dynamic value, [double defaultValue = 0.0]) {
      if (value == null) return defaultValue;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString()) ?? defaultValue;
    }

    final geo = json['geolocalizacao'] as Map<String, dynamic>?;
    final lat = extractDouble(json['latitude'] ?? json['lat'] ?? geo?['latitude']);
    final lng = extractDouble(json['longitude'] ?? json['lng'] ?? geo?['longitude']);

    DateTime parsedTimestamp;
    try {
      final ts = json['timestamp'];
      parsedTimestamp = ts != null ? DateTime.parse(ts.toString()) : DateTime.now();
    } catch (_) {
      parsedTimestamp = DateTime.now();
    }

    return TrackingLocationModel(
      pedidoId: (json['pedido_id'] ?? '').toString(),
      estafetaId: (json['estafeta_id'] ?? '').toString(),
      latitude: lat,
      longitude: lng,
      heading: extractDouble(json['heading'] ?? json['bearing']),
      speed: extractDouble(json['speed'] ?? json['velocidade_kmh']),
      precisaoMetros: extractDouble(json['precisao_metros'] ?? json['accuracy'], 5.0),
      timestamp: parsedTimestamp,
    );
  }

  @override
  List<Object?> get props => [
        pedidoId,
        estafetaId,
        latitude,
        longitude,
        heading,
        speed,
        precisaoMetros,
        timestamp,
      ];
}

// ============================================================================
// 2. CAMADA DE DADOS: TrackingWebSocketService (web_socket_channel)
// ============================================================================

class TrackingWebSocketService {
  final String baseUrl;
  WebSocketChannel? _channel;
  StreamSubscription? _rawSubscription;
  final _locationController = StreamController<TrackingLocationModel>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  Timer? _heartbeatTimer;
  bool _isDisposed = false;

  TrackingWebSocketService({
    this.baseUrl = 'ws://10.0.2.2:8000', // Host padrão para emulador Android local
  });

  Stream<TrackingLocationModel> get locationStream => _locationController.stream;
  Stream<bool> get connectionStream => _connectionStateController.stream;

  /// Inicia a ligação ao WebSocket do Django Channels:
  /// `ws://<host>/ws/v1/orders/tracking/<pedidoId>/?token=<jwtToken>`
  void connect({
    required String pedidoId,
    required String jwtToken,
  }) {
    if (_isDisposed) return;
    disconnect();

    final sanitizedBase = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final uri = Uri.parse('$sanitizedBase/ws/v1/orders/tracking/$pedidoId/?token=$jwtToken');

    try {
      _channel = WebSocketChannel.connect(uri);
      _connectionStateController.add(true);

      _rawSubscription = _channel!.stream.listen(
        (data) {
          _handleIncomingMessage(data);
        },
        onError: (error) {
          _connectionStateController.add(false);
          _scheduleReconnect(pedidoId: pedidoId, jwtToken: jwtToken);
        },
        onDone: () {
          _connectionStateController.add(false);
          _scheduleReconnect(pedidoId: pedidoId, jwtToken: jwtToken);
        },
        cancelOnError: false,
      );

      // Inicia Heartbeat Ping a cada 20 segundos para manter a conexão ativa
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        sendPing();
      });
    } catch (_) {
      _connectionStateController.add(false);
      _scheduleReconnect(pedidoId: pedidoId, jwtToken: jwtToken);
    }
  }

  void _handleIncomingMessage(dynamic rawMessage) {
    try {
      final decoded = json.decode(rawMessage.toString()) as Map<String, dynamic>;
      final eventType = decoded['event'] ?? decoded['type'];

      if (eventType == 'delivery.location_updated' || decoded.containsKey('latitude')) {
        final model = TrackingLocationModel.fromJson(decoded);
        if (!_locationController.isClosed) {
          _locationController.add(model);
        }
      }
    } catch (_) {
      // Ignora frames malformados
    }
  }

  void sendPing() {
    try {
      _channel?.sink.add(json.encode({'action': 'ping', 'timestamp': DateTime.now().toIso8601String()}));
    } catch (_) {}
  }

  void _scheduleReconnect({
    required String pedidoId,
    required String jwtToken,
  }) {
    if (_isDisposed) return;
    Timer(const Duration(seconds: 3), () {
      if (!_isDisposed) {
        connect(pedidoId: pedidoId, jwtToken: jwtToken);
      }
    });
  }

  void disconnect() {
    _heartbeatTimer?.cancel();
    _rawSubscription?.cancel();
    _rawSubscription = null;
    _channel?.sink.close();
    _channel = null;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(false);
    }
  }

  void dispose() {
    _isDisposed = true;
    disconnect();
    _locationController.close();
    _connectionStateController.close();
  }
}

// ============================================================================
// 3. CAMADA DE ESTADO BLoC: Events, States e TrackingBloc
// ============================================================================

abstract class TrackingEvent extends Equatable {
  const TrackingEvent();
  @override
  List<Object?> get props => [];
}

class ConnectTrackingEvent extends TrackingEvent {
  final String pedidoId;
  final String jwtToken;

  const ConnectTrackingEvent({
    required this.pedidoId,
    required this.jwtToken,
  });

  @override
  List<Object?> get props => [pedidoId, jwtToken];
}

class InternalLocationUpdatedEvent extends TrackingEvent {
  final TrackingLocationModel location;
  const InternalLocationUpdatedEvent(this.location);

  @override
  List<Object?> get props => [location];
}

class InternalConnectionChangedEvent extends TrackingEvent {
  final bool isConnected;
  const InternalConnectionChangedEvent(this.isConnected);

  @override
  List<Object?> get props => [isConnected];
}

class DisconnectTrackingEvent extends TrackingEvent {}

abstract class TrackingState extends Equatable {
  const TrackingState();
  @override
  List<Object?> get props => [];
}

class TrackingInitial extends TrackingState {}

class TrackingConnecting extends TrackingState {}

class TrackingConnected extends TrackingState {
  final String pedidoId;
  const TrackingConnected({required this.pedidoId});

  @override
  List<Object?> get props => [pedidoId];
}

class TrackingLocationUpdated extends TrackingState {
  final TrackingLocationModel location;
  final int etaMinutos;
  final double distanciaRestanteKm;
  final bool isConnected;

  const TrackingLocationUpdated({
    required this.location,
    required this.etaMinutos,
    required this.distanciaRestanteKm,
    this.isConnected = true,
  });

  @override
  List<Object?> get props => [location, etaMinutos, distanciaRestanteKm, isConnected];
}

class TrackingDisconnected extends TrackingState {
  final String? motivo;
  const TrackingDisconnected({this.motivo});

  @override
  List<Object?> get props => [motivo];
}

class TrackingBloc extends Bloc<TrackingEvent, TrackingState> {
  final TrackingWebSocketService _service;
  final LatLng moradaCliente;
  StreamSubscription? _locationSub;
  StreamSubscription? _connSub;

  TrackingBloc({
    required TrackingWebSocketService service,
    required this.moradaCliente,
  })  : _service = service,
        super(TrackingInitial()) {
    on<ConnectTrackingEvent>(_onConnect);
    on<InternalLocationUpdatedEvent>(_onLocationReceived);
    on<InternalConnectionChangedEvent>(_onConnectionChanged);
    on<DisconnectTrackingEvent>(_onDisconnect);

    // Escuta transmissões do WebSocket
    _locationSub = _service.locationStream.listen((loc) {
      add(InternalLocationUpdatedEvent(loc));
    });

    _connSub = _service.connectionStream.listen((connected) {
      add(InternalConnectionChangedEvent(connected));
    });
  }

  void _onConnect(ConnectTrackingEvent event, Emitter<TrackingState> emit) {
    emit(TrackingConnecting());
    _service.connect(pedidoId: event.pedidoId, jwtToken: event.jwtToken);
    emit(TrackingConnected(pedidoId: event.pedidoId));
  }

  void _onLocationReceived(InternalLocationUpdatedEvent event, Emitter<TrackingState> emit) {
    final courierLatLng = event.location.toLatLng;
    final distKm = _calcularDistanciaHaversineKm(courierLatLng, moradaCliente);
    final eta = _calcularEtaMinutos(distKm, event.location.speed);

    emit(TrackingLocationUpdated(
      location: event.location,
      etaMinutos: eta,
      distanciaRestanteKm: distKm,
      isConnected: true,
    ));
  }

  void _onConnectionChanged(InternalConnectionChangedEvent event, Emitter<TrackingState> emit) {
    if (!event.isConnected && state is TrackingLocationUpdated) {
      final current = state as TrackingLocationUpdated;
      emit(TrackingLocationUpdated(
        location: current.location,
        etaMinutos: current.etaMinutos,
        distanciaRestanteKm: current.distanciaRestanteKm,
        isConnected: false,
      ));
    } else if (!event.isConnected) {
      emit(const TrackingDisconnected(motivo: 'A reconectar ao servidor...'));
    }
  }

  void _onDisconnect(DisconnectTrackingEvent event, Emitter<TrackingState> emit) {
    _service.disconnect();
    emit(const TrackingDisconnected(motivo: 'Desconectado manualmente.'));
  }

  static double _calcularDistanciaHaversineKm(LatLng p1, LatLng p2) {
    const double r = 6371.0;
    final dLat = (p2.latitude - p1.latitude) * (pi / 180.0);
    final dLng = (p2.longitude - p1.longitude) * (pi / 180.0);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(p1.latitude * (pi / 180.0)) *
            cos(p2.latitude * (pi / 180.0)) *
            sin(dLng / 2) *
            sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  static int _calcularEtaMinutos(double distanciaKm, double? velocidadeKmh) {
    // Considera 25 km/h média de trânsito urbano em Luanda caso a velocidade atual seja baixa
    final vel = (velocidadeKmh != null && velocidadeKmh > 12.0) ? velocidadeKmh : 24.0;
    final horas = distanciaKm / vel;
    final minutos = (horas * 60).ceil() + 2; // + 2 min margem de semáforos/portaria
    return max(1, minutos);
  }

  @override
  Future<void> close() {
    _locationSub?.cancel();
    _connSub?.cancel();
    _service.dispose();
    return super.close();
  }
}

// ============================================================================
// 4. INTERFACE UI: OrderRealTimeTrackingScreen (GoogleMap + Interpolação)
// ============================================================================

class OrderRealTimeTrackingScreen extends StatefulWidget {
  final String pedidoId;
  final String jwtToken;
  final String nomeLoja;
  final String moradaLojaTexto;
  final LatLng coordenadasLoja;
  final String moradaClienteTexto;
  final LatLng coordenadasCliente;
  final String pinEntrega; // RN-095
  final String estafetaNome;
  final String estafetaTelemovel;
  final String estafetaVeiculo;

  const OrderRealTimeTrackingScreen({
    super.key,
    required this.pedidoId,
    required this.jwtToken,
    required this.nomeLoja,
    required this.moradaLojaTexto,
    required this.coordenadasLoja,
    required this.moradaClienteTexto,
    required this.coordenadasCliente,
    this.pinEntrega = '7429',
    this.estafetaNome = 'Mateus Sebastião',
    this.estafetaTelemovel = '+244923111222',
    this.estafetaVeiculo = 'Mota Haojue 125 (LD-44-99-AF)',
  });

  @override
  State<OrderRealTimeTrackingScreen> createState() => _OrderRealTimeTrackingScreenState();
}

class _OrderRealTimeTrackingScreenState extends State<OrderRealTimeTrackingScreen>
    with SingleTickerProviderStateMixin {
  GoogleMapController? _mapController;
  late final TrackingWebSocketService _webSocketService;
  late final TrackingBloc _trackingBloc;

  // Interpolação de animação do Marcador do Estafeta
  late final AnimationController _animController;
  LatLng? _courierStartLatLng;
  LatLng? _courierTargetLatLng;
  double _courierStartRotation = 0.0;
  double _courierTargetRotation = 0.0;
  LatLng? _currentInterpolatedLatLng;
  double _currentInterpolatedRotation = 0.0;

  // Marcadores Customizados em Memória
  BitmapDescriptor? _markerIconStore;
  BitmapDescriptor? _markerIconDestination;
  BitmapDescriptor? _markerIconCourier;

  @override
  void initState() {
    super.initState();
    _initCustomMarkers();

    // Posição inicial estimada do estafeta (começa na loja caso ainda não haja dados)
    _courierStartLatLng = widget.coordenadasLoja;
    _courierTargetLatLng = widget.coordenadasLoja;
    _currentInterpolatedLatLng = widget.coordenadasLoja;

    // Configuração do AnimationController para suavizar o movimento entre posições GPS
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000), // Suaviza a janela de 5s da RN-094
    )..addListener(() {
        if (_courierStartLatLng != null && _courierTargetLatLng != null) {
          final t = _animController.value;
          setState(() {
            _currentInterpolatedLatLng = _interpolateLatLng(
              _courierStartLatLng!,
              _courierTargetLatLng!,
              t,
            );
            _currentInterpolatedRotation = _interpolateAngle(
              _courierStartRotation,
              _courierTargetRotation,
              t,
            );
          });
        }
      });

    _webSocketService = TrackingWebSocketService();
    _trackingBloc = TrackingBloc(
      service: _webSocketService,
      moradaCliente: widget.coordenadasCliente,
    )..add(ConnectTrackingEvent(
        pedidoId: widget.pedidoId,
        jwtToken: widget.jwtToken,
      ));
  }

  Future<void> _initCustomMarkers() async {
    _markerIconStore = await _createCanvasBitmapDescriptor(
      icon: Icons.storefront_rounded,
      bgColor: const Color(0xFF1E88E5),
      label: 'Loja',
    );
    _markerIconDestination = await _createCanvasBitmapDescriptor(
      icon: Icons.home_rounded,
      bgColor: const Color(0xFFD32F2F),
      label: 'Destino',
    );
    _markerIconCourier = await _createCanvasBitmapDescriptor(
      icon: Icons.two_wheeler_rounded,
      bgColor: const Color(0xFF2E7D32),
      label: 'Estafeta',
    );
    if (mounted) setState(() {});
  }

  /// Gera um marcador visual nítido com ícone e etiqueta em Canvas puro
  Future<BitmapDescriptor> _createCanvasBitmapDescriptor({
    required IconData icon,
    required Color bgColor,
    required String label,
  }) async {
    final pictureRecorder = ui.PictureRecorder();
    final canvas = Canvas(pictureRecorder);
    const size = Size(120, 130);

    // Fundo do marcador
    final paintCircle = Paint()..color = bgColor;
    final paintShadow = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    // Sombra
    canvas.drawCircle(const Offset(60, 52), 40, paintShadow);
    // Círculo Principal
    canvas.drawCircle(const Offset(60, 50), 38, paintCircle);

    // Borda Branca
    final paintBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    canvas.drawCircle(const Offset(60, 50), 38, paintBorder);

    // Ponteiro inferior
    final path = Path()
      ..moveTo(45, 80)
      ..lineTo(60, 102)
      ..lineTo(75, 80)
      ..close();
    canvas.drawPath(path, paintCircle);
    canvas.drawPath(path, paintBorder);

    // Desenha Ícone
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: 38,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: Colors.white,
      ),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(60 - textPainter.width / 2, 50 - textPainter.height / 2));

    final picture = pictureRecorder.endRecording();
    final image = await picture.toImage(size.width.toInt(), size.height.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  LatLng _interpolateLatLng(LatLng start, LatLng end, double fraction) {
    final lat = start.latitude + (end.latitude - start.latitude) * fraction;
    final lng = start.longitude + (end.longitude - start.longitude) * fraction;
    return LatLng(lat, lng);
  }

  double _interpolateAngle(double start, double end, double fraction) {
    double diff = (end - start) % 360.0;
    if (diff > 180.0) diff -= 360.0;
    if (diff < -180.0) diff += 360.0;
    return (start + diff * fraction) % 360.0;
  }

  void _onNewLocationReceived(TrackingLocationModel newLocation) {
    if (!mounted) return;

    _courierStartLatLng = _currentInterpolatedLatLng ?? widget.coordenadasLoja;
    _courierTargetLatLng = newLocation.toLatLng;

    _courierStartRotation = _currentInterpolatedRotation;
    _courierTargetRotation = newLocation.heading;

    // Reinicia a interpolação linear suave
    _animController.forward(from: 0.0);
  }

  void _ajustarCameraBounds() {
    if (_mapController == null) return;

    final pontos = [
      widget.coordenadasLoja,
      widget.coordenadasCliente,
      if (_currentInterpolatedLatLng != null) _currentInterpolatedLatLng!,
    ];

    double minLat = pontos.first.latitude;
    double maxLat = pontos.first.latitude;
    double minLng = pontos.first.longitude;
    double maxLng = pontos.first.longitude;

    for (final p in pontos) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLng = max(maxLng, p.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
  }

  @override
  void dispose() {
    _animController.dispose();
    _mapController?.dispose();
    _trackingBloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocProvider.value(
      value: _trackingBloc,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: Padding(
            padding: const EdgeInsets.only(left: 12.0),
            child: CircleAvatar(
              backgroundColor: Colors.white,
              child: IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Colors.black87),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          actions: [
            BlocBuilder<TrackingBloc, TrackingState>(
              builder: (context, state) {
                final isConnected = state is TrackingLocationUpdated
                    ? state.isConnected
                    : state is TrackingConnected;

                return Padding(
                  padding: const EdgeInsets.only(right: 16.0),
                  child: Chip(
                    avatar: CircleAvatar(
                      radius: 5,
                      backgroundColor: isConnected ? Colors.green : Colors.red,
                    ),
                    label: Text(
                      isConnected ? 'GPS Ao Vivo' : 'Reconectando...',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    backgroundColor: Colors.white.withOpacity(0.95),
                    elevation: 3,
                  ),
                );
              },
            ),
          ],
        ),
        body: BlocConsumer<TrackingBloc, TrackingState>(
          listener: (context, state) {
            if (state is TrackingLocationUpdated) {
              _onNewLocationReceived(state.location);
            }
          },
          builder: (context, state) {
            final courierPosition = _currentInterpolatedLatLng ?? widget.coordenadasLoja;

            // Marcadores estruturados com o Courier interpolado suavemente
            final markers = <Marker>{
              // 1. Marcador da Loja / Ponto de Recolha
              Marker(
                markerId: const MarkerId('store_pickup'),
                position: widget.coordenadasLoja,
                icon: _markerIconStore ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                infoWindow: InfoWindow(
                  title: widget.nomeLoja,
                  snippet: widget.moradaLojaTexto,
                ),
              ),
              // 2. Marcador do Cliente / Ponto de Entrega
              Marker(
                markerId: const MarkerId('client_destination'),
                position: widget.coordenadasCliente,
                icon: _markerIconDestination ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
                infoWindow: InfoWindow(
                  title: 'A Tua Morada',
                  snippet: widget.moradaClienteTexto,
                ),
              ),
              // 3. Marcador Dinâmico do Estafeta (Mota em Movimento)
              Marker(
                markerId: const MarkerId('courier_moving'),
                position: courierPosition,
                rotation: _currentInterpolatedRotation,
                anchor: const Offset(0.5, 0.5),
                flat: true,
                zIndex: 10,
                icon: _markerIconCourier ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
                infoWindow: InfoWindow(
                  title: 'Estafeta em Rota',
                  snippet: widget.estafetaNome,
                ),
              ),
            };

            // Linha polilinha ilustrativa de rota
            final polylines = <Polyline>{
              Polyline(
                polylineId: const PolylineId('route_direct'),
                points: [
                  widget.coordenadasLoja,
                  courierPosition,
                  widget.coordenadasCliente,
                ],
                color: theme.colorScheme.primary.withOpacity(0.7),
                width: 5,
                jointType: JointType.round,
                patterns: [PatternItem.dash(20), PatternItem.gap(10)],
              ),
            };

            int etaMinutos = 15;
            double distKm = 2.5;
            if (state is TrackingLocationUpdated) {
              etaMinutos = state.etaMinutos;
              distKm = state.distanciaRestanteKm;
            }

            return Stack(
              children: [
                // 1. Google Map centrado inicialmente na morada de entrega
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: widget.coordenadasCliente,
                    zoom: 14.5,
                  ),
                  onMapCreated: (controller) {
                    _mapController = controller;
                    _ajustarCameraBounds();
                  },
                  markers: markers,
                  polylines: polylines,
                  myLocationButtonEnabled: false,
                  zoomControlsEnabled: false,
                  mapToolbarEnabled: false,
                ),

                // 2. Botão Flutuante para Reenquadrar Todos os Marcadores
                Positioned(
                  right: 16,
                  bottom: 300,
                  child: FloatingActionButton.small(
                    heroTag: 'btn_recenter',
                    backgroundColor: Colors.white,
                    onPressed: _ajustarCameraBounds,
                    child: Icon(Icons.crop_free_rounded, color: theme.colorScheme.primary),
                  ),
                ),

                // 3. Bottom Sheet Operacional de Tracking (Material Design 3)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _buildTrackingBottomSheet(
                    context: context,
                    etaMinutos: etaMinutos,
                    distanciaKm: distKm,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildTrackingBottomSheet({
    required BuildContext context,
    required int etaMinutos,
    required double distanciaKm,
  }) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pega de arrasto
          Center(
            child: Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),

          // Cabeçalho de Status e ETA (RN-029)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Pedido a Caminho',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Chegada estimada em $etaMinutos min • ${distanciaKm.toStringAsFixed(1)} km',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(Icons.timer_outlined, color: theme.colorScheme.primary, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      '$etaMinutos min',
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 14),

          // Informações do Estafeta
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: theme.colorScheme.primary.withOpacity(0.12),
                child: Icon(Icons.person_outline_rounded, color: theme.colorScheme.primary, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.estafetaNome,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.estafetaVeiculo,
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.phone_outlined),
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('A ligar para ${widget.estafetaTelemovel}...')),
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Card de Segurança: PIN de Entrega (RN-095)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.pin_outlined, color: Colors.amber.shade900, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PIN de Validação (RN-095)',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber.shade900,
                        ),
                      ),
                      const Text(
                        'Partilha este código ao receber o pedido:',
                        style: TextStyle(fontSize: 12, color: Colors.black87),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amber.shade400, width: 1.5),
                  ),
                  child: Text(
                    widget.pinEntrega,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3.0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

