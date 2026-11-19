/// Ecrã de Seleção de Localização e Morada no Mapa (`select_location_screen.dart`).
/// 100% Gratuito e Open-Source utilizando FlutterMap + OpenStreetMap (sem Google Maps ou Mapbox).
/// Utiliza o GPS real do telemóvel com fallback para Lubango, Huíla (-14.9172, 13.4925)
/// e um pino fixo no centro do ecrã com arrasto fluido do mapa.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

class SelectLocationScreen extends StatefulWidget {
  final LatLng? initialPosition;
  final String title;

  const SelectLocationScreen({
    super.key,
    this.initialPosition,
    this.title = 'Confirmar Local de Entrega',
  });

  @override
  State<SelectLocationScreen> createState() => _SelectLocationScreenState();
}

class _SelectLocationScreenState extends State<SelectLocationScreen> {
  // Coordenadas centrais padrão para Lubango / Huíla (Angola)
  static const LatLng _defaultLubango = LatLng(-14.9172, 13.4925);

  final MapController _mapController = MapController();
  late LatLng _currentCenter;
  bool _isLoadingGps = true;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _currentCenter = widget.initialPosition ?? _defaultLubango;
    _obterLocalizacaoAtual();
  }

  /// Obtém a posição GPS atual do telemóvel via Geolocator com tratamento de permissões
  Future<void> _obterLocalizacaoAtual() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) setState(() => _isLoadingGps = false);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) setState(() => _isLoadingGps = false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) setState(() => _isLoadingGps = false);
        return;
      }

      // Obtém coordenadas reais com precisão balanceada
      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 6),
      );

      final userLatLng = LatLng(position.latitude, position.longitude);

      if (mounted) {
        setState(() {
          _currentCenter = userLatLng;
          _isLoadingGps = false;
        });
        _mapController.move(userLatLng, 16.0);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingGps = false);
      }
    }
  }

  void _centralizarNoGps() {
    _obterLocalizacaoAtual();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location_rounded),
            tooltip: 'A minha localização',
            onPressed: _centralizarNoGps,
          ),
        ],
      ),
      body: Stack(
        children: [
          // 1. MAPA OPENSTREETMAP GRATUITO (FLUTTER_MAP)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentCenter,
              initialZoom: 15.5,
              minZoom: 4.0,
              maxZoom: 18.0,
              onPositionChanged: (camera, hasGesture) {
                if (hasGesture) {
                  setState(() {
                    _currentCenter = camera.center;
                    _isDragging = true;
                  });
                } else if (_isDragging) {
                  setState(() {
                    _isDragging = false;
                  });
                }
              },
            ),
            children: [
              // Camada oficial de Tiles do OpenStreetMap (100% gratuita, sem API key)
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.delivery.app',
                maxZoom: 19,
              ),
            ],
          ),

          // 2. PINO CENTRAL FIXO COM ANIMAÇÃO DE ARRASTO
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 36.0), // Ajuste para a ponta do pino coincidir com o centro
              child: AnimatedScale(
                scale: _isDragging ? 1.25 : 1.0,
                duration: const Duration(milliseconds: 150),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.2),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Text(
                        _isDragging ? 'A mover...' : 'Local Selecionado',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Icon(
                      Icons.location_on_rounded,
                      color: Color(0xFFEA1D2C),
                      size: 44,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Indicador de Carregamento GPS Inicial
          if (_isLoadingGps)
            Positioned(
              top: 16,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFEA1D2C)),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'A calibrar localização GPS...',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                    ),
                  ],
                ),
              ),
            ),

          // 3. CARD INFERIOR DE CONFIRMAÇÃO COM COORDENADAS REAIS
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF2F2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.pin_drop_rounded, color: Color(0xFFEA1D2C), size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Coordenadas Geográficas',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${_currentCenter.latitude.toStringAsFixed(6)}, ${_currentCenter.longitude.toStringAsFixed(6)}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFEA1D2C),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          // Retorna as coordenadas selecionadas para o ecrã anterior
                          Navigator.of(context).pop(_currentCenter);
                        },
                        icon: const Icon(Icons.check_rounded, size: 20),
                        label: const Text(
                          'Confirmar Este Local',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                      ),
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
}
