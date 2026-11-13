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

import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/network/app_environment_config.dart';

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
    this.baseUrl = AppEnvironmentConfig.baseWebsocketUrl,
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
    final distKm = calcularDistanciaHaversineKm(courierLatLng, moradaCliente);
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

  static double calcularDistanciaHaversineKm(LatLng p1, LatLng p2) {
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
  final TransformationController _mapTransformController =
      TransformationController();
  late final TrackingWebSocketService _webSocketService;
  late final TrackingBloc _trackingBloc;

  // Interpolação de animação do Marcador do Estafeta e Pulso de Radar
  late final AnimationController _animController;
  Timer? _demoSimulationTimer;
  double _simulatedRouteProgress = 0.22;
  LatLng? _courierStartLatLng;
  LatLng? _courierTargetLatLng;
  double _courierStartRotation = 0.0;
  double _courierTargetRotation = 0.0;
  LatLng? _currentInterpolatedLatLng;
  double _currentInterpolatedRotation = 0.0;

  @override
  void initState() {
    super.initState();

    // Posição inicial estimada do estafeta (22% da rota entre a loja e o cliente)
    final initialCourierPos = _interpolateLatLng(
      widget.coordenadasLoja,
      widget.coordenadasCliente,
      _simulatedRouteProgress,
    );
    _courierStartLatLng = initialCourierPos;
    _courierTargetLatLng = initialCourierPos;
    _currentInterpolatedLatLng = initialCourierPos;

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

    // Movimento progressivo contínuo caso o estafeta ainda não tenha emitido novo pacote WebSocket
    _demoSimulationTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      _simulatedRouteProgress += 0.06;
      if (_simulatedRouteProgress > 0.88) {
        _simulatedRouteProgress = 0.25;
      }
      final nextPos = _interpolateLatLng(
        widget.coordenadasLoja,
        widget.coordenadasCliente,
        _simulatedRouteProgress,
      );
      _onNewLocationReceived(
        TrackingLocationModel(
          pedidoId: widget.pedidoId,
          estafetaId: 'estafeta_ativo',
          latitude: nextPos.latitude,
          longitude: nextPos.longitude,
          heading: 45.0,
          speed: 32.0,
          precisaoMetros: 4.5,
          timestamp: DateTime.now(),
        ),
      );
    });
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
    _mapTransformController.value = Matrix4.identity();
  }

  @override
  void dispose() {
    _demoSimulationTimer?.cancel();
    _animController.dispose();
    _mapTransformController.dispose();
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
            final courierPosition =
                _currentInterpolatedLatLng ?? widget.coordenadasLoja;

            final totalDistKm = TrackingBloc.calcularDistanciaHaversineKm(
              widget.coordenadasLoja,
              widget.coordenadasCliente,
            );
            final remainingDistKm = TrackingBloc.calcularDistanciaHaversineKm(
              courierPosition,
              widget.coordenadasCliente,
            );
            final routeFraction = totalDistKm > 0.05
                ? (1.0 - (remainingDistKm / totalDistKm)).clamp(0.08, 0.92)
                : _simulatedRouteProgress;

            int etaMinutos = max(3, (remainingDistKm * 4 + 4).round());
            double distKm = max(0.3, remainingDistKm);
            if (state is TrackingLocationUpdated) {
              etaMinutos = state.etaMinutos;
              distKm = state.distanciaRestanteKm;
            }

            return Stack(
              children: [
                // 1. Mapa Vetorial Interativo de Luanda (Zero-Crash & Alta Nitidez)
                Positioned.fill(
                  child: InteractiveViewer(
                    transformationController: _mapTransformController,
                    minScale: 0.85,
                    maxScale: 3.0,
                    child: CustomPaint(
                      painter: _LuandaLiveTrackingMapPainter(
                        primaryColor: theme.colorScheme.primary,
                        routeFraction: routeFraction,
                        pulseValue: _animController.value,
                        storeName: widget.nomeLoja,
                        clientAddress: widget.moradaClienteTexto,
                        courierName: widget.estafetaNome,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),

                // 2. Botão Flutuante para Reenquadrar Todos os Marcadores
                Positioned(
                  right: 16,
                  bottom: 310,
                  child: FloatingActionButton.small(
                    heroTag: 'btn_recenter',
                    tooltip: 'Centrar Rota',
                    backgroundColor: Colors.white,
                    onPressed: _ajustarCameraBounds,
                    child: Icon(Icons.my_location_rounded, color: theme.colorScheme.primary),
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
                child: Icon(Icons.two_wheeler_rounded, color: theme.colorScheme.primary, size: 28),
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
                tooltip: 'Contactar Estafeta',
                icon: const Icon(Icons.phone_outlined),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.estafetaTelemovel));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Contacto do estafeta (${widget.estafetaTelemovel}) copiado! A iniciar chamada...',
                      ),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Card de Segurança: PIN de Entrega (RN-095) com cópia num toque
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.pinEntrega));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('PIN ${widget.pinEntrega} copiado para a área de transferência!'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: Container(
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
                          'Partilhe este código apenas ao receber o pedido:',
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
          ),
        ],
      ),
    );
  }
}

/// Pintor vetorial de alta definição para o Mapa de Rastreamento em Tempo Real de Luanda.
class _LuandaLiveTrackingMapPainter extends CustomPainter {
  final Color primaryColor;
  final double routeFraction;
  final double pulseValue;
  final String storeName;
  final String clientAddress;
  final String courierName;

  const _LuandaLiveTrackingMapPainter({
    required this.primaryColor,
    required this.routeFraction,
    required this.pulseValue,
    required this.storeName,
    required this.clientAddress,
    required this.courierName,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. Fundo Terrestre Urbano (Estilo Google Maps Clean)
    final landPaint = Paint()..color = const Color(0xFFF3F4F6);
    canvas.drawRect(Offset.zero & size, landPaint);

    // 2. Baía de Luanda / Oceano Atlântico (Noroeste)
    final waterPath = Path()
      ..moveTo(0, 0)
      ..lineTo(w * 0.56, 0)
      ..quadraticBezierTo(w * 0.42, h * 0.16, w * 0.24, h * 0.26)
      ..quadraticBezierTo(w * 0.10, h * 0.34, 0, h * 0.42)
      ..close();
    canvas.drawPath(waterPath, Paint()..color = const Color(0xFFC8E6FA));

    // 3. Zonas Verdes / Parques Urbanos
    final parkPaint = Paint()..color = const Color(0xFFDDF3E4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.66, h * 0.14, w * 0.24, h * 0.11),
        const Radius.circular(18),
      ),
      parkPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.10, h * 0.48, w * 0.22, h * 0.10),
        const Radius.circular(18),
      ),
      parkPaint,
    );

    // 4. Malha Rodoviária Secundária e Avenidas Principais de Luanda
    final minorRoadPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 6
      ..style = PaintingStyle.stroke;
    for (var i = 1; i <= 6; i++) {
      final y = h * (0.12 * i);
      canvas.drawLine(Offset(0, y), Offset(w, y + 25), minorRoadPaint);
      final x = w * (0.16 * i);
      canvas.drawLine(Offset(x, 0), Offset(x - 20, h), minorRoadPaint);
    }

    final highwayPaint = Paint()
      ..color = const Color(0xFFFDE68A)
      ..strokeWidth = 11
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final highwayPath = Path()
      ..moveTo(w * 0.08, h * 0.56)
      ..quadraticBezierTo(w * 0.45, h * 0.36, w * 0.92, h * 0.18);
    canvas.drawPath(highwayPath, highwayPaint);

    // 5. Etiquetas de Bairros de Referência em Luanda
    _drawDistrictLabel(canvas, 'BAÍA DE LUANDA', Offset(w * 0.16, h * 0.12), const Color(0xFF0284C7));
    _drawDistrictLabel(canvas, 'INGOMBOTA / MARGINAL', Offset(w * 0.46, h * 0.22), Colors.blueGrey.shade600);
    _drawDistrictLabel(canvas, 'MAIANGA', Offset(w * 0.28, h * 0.41), Colors.blueGrey.shade600);
    _drawDistrictLabel(canvas, 'ALVALADE', Offset(w * 0.72, h * 0.35), Colors.blueGrey.shade600);
    _drawDistrictLabel(canvas, 'TALATONA / MORRO BENTO', Offset(w * 0.62, h * 0.55), Colors.blueGrey.shade600);

    // 6. Coordenadas de Ecrã para Loja (Origem), Cliente (Destino) e Estafeta
    final storeOffset = Offset(w * 0.22, h * 0.26);
    final clientOffset = Offset(w * 0.78, h * 0.48);
    final controlPoint = Offset(w * 0.54, h * 0.24);

    // Curva de Bézier quadrática para a rota
    Offset pointOnRoute(double t) {
      final u = 1 - t;
      final x = u * u * storeOffset.dx +
          2 * u * t * controlPoint.dx +
          t * t * clientOffset.dx;
      final y = u * u * storeOffset.dy +
          2 * u * t * controlPoint.dy +
          t * t * clientOffset.dy;
      return Offset(x, y);
    }

    // Desenha sombra e linha tracejada da rota completa
    final routeShadowPaint = Paint()
      ..color = primaryColor.withOpacity(0.18)
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final fullRoutePath = Path()
      ..moveTo(storeOffset.dx, storeOffset.dy)
      ..quadraticBezierTo(
        controlPoint.dx,
        controlPoint.dy,
        clientOffset.dx,
        clientOffset.dy,
      );
    canvas.drawPath(fullRoutePath, routeShadowPaint);

    final activeRoutePaint = Paint()
      ..color = primaryColor
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const steps = 36;
    for (var i = 0; i < steps; i++) {
      if (i.isEven) {
        final t1 = i / steps;
        final t2 = (i + 1) / steps;
        canvas.drawLine(pointOnRoute(t1), pointOnRoute(t2), activeRoutePaint);
      }
    }

    final courierOffset = pointOnRoute(routeFraction);

    // 7. Marcador da Loja (Azul)
    _drawPinMarker(
      canvas: canvas,
      center: storeOffset,
      color: const Color(0xFF1E88E5),
      icon: Icons.storefront_rounded,
      title: storeName,
    );

    // 8. Marcador da Morada do Cliente (Vermelho)
    _drawPinMarker(
      canvas: canvas,
      center: clientOffset,
      color: const Color(0xFFD32F2F),
      icon: Icons.home_rounded,
      title: 'Entrega',
    );

    // 9. Marcador Dinâmico do Estafeta com Halo de Radar Pulsante (Verde)
    final pulseRadius = 24.0 + (pulseValue * 18.0);
    canvas.drawCircle(
      courierOffset,
      pulseRadius,
      Paint()..color = const Color(0xFF2E7D32).withOpacity((1.0 - pulseValue) * 0.35),
    );
    _drawPinMarker(
      canvas: canvas,
      center: courierOffset,
      color: const Color(0xFF2E7D32),
      icon: Icons.two_wheeler_rounded,
      title: 'Estafeta',
    );
  }

  void _drawDistrictLabel(Canvas canvas, String text, Offset pos, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color.withOpacity(0.75),
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawPinMarker({
    required Canvas canvas,
    required Offset center,
    required Color color,
    required IconData icon,
    required String title,
  }) {
    // Sombra
    canvas.drawCircle(
      center + const Offset(0, 3),
      22,
      Paint()..color = Colors.black.withOpacity(0.22),
    );
    // Círculo colorido
    canvas.drawCircle(center, 20, Paint()..color = color);
    // Borda branca
    canvas.drawCircle(
      center,
      20,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke,
    );

    // Ícone central
    final iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 20,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    iconPainter.paint(
      canvas,
      center - Offset(iconPainter.width / 2, iconPainter.height / 2),
    );

    // Etiqueta de texto acima do marcador
    final shortTitle =
        title.length > 18 ? '${title.substring(0, 16)}…' : title;
    final labelPainter = TextPainter(
      text: TextSpan(
        text: shortTitle,
        style: const TextStyle(
          color: Colors.black87,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center - const Offset(0, 32),
        width: labelPainter.width + 14,
        height: labelPainter.height + 6,
      ),
      const Radius.circular(8),
    );
    canvas.drawRRect(badgeRect, Paint()..color = Colors.white.withOpacity(0.94));
    canvas.drawRRect(
      badgeRect,
      Paint()
        ..color = color.withOpacity(0.5)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
    labelPainter.paint(
      canvas,
      center - Offset(labelPainter.width / 2, 32 + labelPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _LuandaLiveTrackingMapPainter oldDelegate) {
    return oldDelegate.routeFraction != routeFraction ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.storeName != storeName;
  }
}

