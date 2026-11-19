/// Ecrã de Rastreamento de Entrega em Tempo Real (`tracking_screen.dart`).
/// 100% Gratuito e Open-Source utilizando FlutterMap + OpenStreetMap e WebSockets (Django Channels).
/// Exibe a rota (Polyline) e marcadores dinâmicos da Loja, Cliente e Estafeta.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../../core/network/app_environment_config.dart';

class OrderTrackingScreen extends StatefulWidget {
  final String pedidoId;
  final LatLng lojaLocation;
  final LatLng clienteLocation;
  final LatLng? estafetaLocationInicial;
  final List<LatLng> rotaCoordinates;
  final String nomeLoja;
  final String statusPedido;
  final bool isFallback;

  const OrderTrackingScreen({
    super.key,
    required this.pedidoId,
    required this.lojaLocation,
    required this.clienteLocation,
    this.estafetaLocationInicial,
    this.rotaCoordinates = const [],
    this.nomeLoja = 'Restaurante / Loja',
    this.statusPedido = 'A caminho da sua morada',
    this.isFallback = false,
  });

  @override
  State<OrderTrackingScreen> createState() => _OrderTrackingScreenState();
}

class _OrderTrackingScreenState extends State<OrderTrackingScreen>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();

  WebSocketChannel? _channel;
  StreamSubscription? _socketSubscription;

  late LatLng _estafetaPos;
  double _estafetaHeading = 0.0;
  bool _isConnected = false;
  String _statusMsg = '';

  @override
  void initState() {
    super.initState();
    _estafetaPos = widget.estafetaLocationInicial ?? widget.lojaLocation;
    _statusMsg = widget.statusPedido;
    _conectarWebSocket();
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  /// Conecta ao WebSocket do Django Channels para receber telemetria em tempo real
  void _conectarWebSocket() {
    try {
      final wsBaseUrl = AppEnvironmentConfig.baseWebSocketUrl;
      final uri = Uri.parse('$wsBaseUrl/ws/entrega/${widget.pedidoId}/');

      _channel = WebSocketChannel.connect(uri);

      _socketSubscription = _channel!.stream.listen(
        (data) {
          try {
            final payload = jsonDecode(data as String) as Map<String, dynamic>;
            final tipo = payload['tipo'];

            if (tipo == 'posicao_atualizada') {
              final double lat = (payload['lat'] as num).toDouble();
              final double lon = (payload['lon'] as num).toDouble();
              final double heading = (payload['heading'] as num?)?.toDouble() ?? 0.0;

              setState(() {
                _estafetaPos = LatLng(lat, lon);
                _estafetaHeading = heading;
                _isConnected = true;
              });
            } else if (tipo == 'conexao_estabelecida') {
              setState(() {
                _isConnected = true;
              });
            }
          } catch (_) {}
        },
        onError: (err) {
          setState(() => _isConnected = false);
        },
        onDone: () {
          setState(() => _isConnected = false);
        },
      );
    } catch (_) {
      setState(() => _isConnected = false);
    }
  }

  void _ajustarZoomCompleto() {
    final bounds = LatLngBounds.fromPoints([
      widget.lojaLocation,
      widget.clienteLocation,
      _estafetaPos,
      ...widget.rotaCoordinates,
    ]);

    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(50)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rastreamento em Direto'),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out_map_rounded),
            tooltip: 'Ver rota completa',
            onPressed: _ajustarZoomCompleto,
          ),
        ],
      ),
      body: Stack(
        children: [
          // 1. MAPA OPENSTREETMAP COM POLYLINES E MARCADORES
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _estafetaPos,
              initialZoom: 14.5,
              minZoom: 5.0,
              maxZoom: 18.0,
            ),
            children: [
              // Camada OpenStreetMap gratuita
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.delivery.app',
                maxZoom: 19,
              ),

              // Rota Viária Traçada (Polyline) vinda do OSRM ou Traçado Tracejado em Fallback
              if (widget.rotaCoordinates.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: widget.rotaCoordinates,
                      strokeWidth: 4.5,
                      color: (widget.isFallback || widget.rotaCoordinates.length == 2)
                          ? const Color(0xFFF59E0B) // Âmbar para rota estimada por linha reta
                          : const Color(0xFFEA1D2C), // Vermelho Pro para malha OSRM
                      borderColor: Colors.white,
                      borderStrokeWidth: 1.5,
                      isDotted: widget.isFallback || widget.rotaCoordinates.length == 2,
                    ),
                  ],
                ),

              // Marcadores dos 3 Agentes: Loja, Cliente e Moto do Estafeta
              MarkerLayer(
                markers: [
                  // MARCADOR 1: LOJA / RESTAURANTE
                  Marker(
                    point: widget.lojaLocation,
                    width: 44,
                    height: 44,
                    child: _buildMarkerContainer(
                      icon: Icons.storefront_rounded,
                      color: const Color(0xFF2563EB),
                      label: 'Loja',
                    ),
                  ),

                  // MARCADOR 2: CLIENTE / MORADA DE ENTREGA
                  Marker(
                    point: widget.clienteLocation,
                    width: 44,
                    height: 44,
                    child: _buildMarkerContainer(
                      icon: Icons.home_rounded,
                      color: const Color(0xFF16A34A),
                      label: 'Cliente',
                    ),
                  ),

                  // MARCADOR 3: MOTO DO ESTAFETA (Atualizado via WebSocket)
                  Marker(
                    point: _estafetaPos,
                    width: 52,
                    height: 52,
                    child: Transform.rotate(
                      angle: _estafetaHeading * (3.141592653589793 / 180.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFEA1D2C),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.25),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.two_wheeler_rounded,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // 2. INDICADOR DE STATUS DA CONEXÃO EM TEMPO REAL
          Positioned(
            top: 14,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 6),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isConnected ? const Color(0xFF16A34A) : Colors.amber,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isConnected ? 'GPS em Direto (Online)' : 'A conectar ao radar...',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _isConnected ? const Color(0xFF16A34A) : Colors.amber.shade800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Pedido #${widget.pedidoId.length > 8 ? widget.pedidoId.substring(0, 8).toUpperCase() : widget.pedidoId}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF64748B), fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),

          // 3. CARD INFERIOR COM DETALHES DO ESTAFETA E STATUS
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 24,
                          backgroundColor: const Color(0xFFFEF2F2),
                          child: const Icon(Icons.two_wheeler_rounded, color: Color(0xFFEA1D2C), size: 26),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _statusMsg,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                widget.nomeLoja,
                                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkerContainer({
    required IconData icon,
    required Color color,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ],
    );
  }
}
