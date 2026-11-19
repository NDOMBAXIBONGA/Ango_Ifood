/// Serviço de Telemetria e Transmissão GPS do Estafeta (`courier_gps_service.dart`).
/// Monitoriza a posição do estafeta via Geolocator.getPositionStream com filtro de 10m
/// (máxima economia de bateria e consumo reduzido de pacotes de dados em Angola)
/// e envia as coordenadas em tempo real via WebSocket para o Django Channels.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:geolocator/geolocator.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../../core/network/app_environment_config.dart';

class CourierGpsService {
  static final CourierGpsService _instance = CourierGpsService._internal();
  factory CourierGpsService() => _instance;
  CourierGpsService._internal();

  StreamSubscription<Position>? _positionSubscription;
  WebSocketChannel? _channel;
  String? _pedidoIdAtivo;
  bool _isTracking = false;

  bool get isTracking => _isTracking;

  /// Inicia o envio de telemetria GPS em tempo real para uma corrida/pedido
  Future<bool> startTracking({required String pedidoId}) async {
    if (_isTracking && _pedidoIdAtivo == pedidoId) {
      return true;
    }

    await stopTracking();

    // 1. Verificação de permissões do GPS
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      developer.log('Serviço de localização GPS desativado.', name: 'CourierGpsService');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return false;
    }

    _pedidoIdAtivo = pedidoId;

    // 2. Conectar ao WebSocket do Django Channels
    try {
      final wsBaseUrl = AppEnvironmentConfig.baseWebsocketUrl;
      final uri = Uri.parse('$wsBaseUrl/ws/entrega/$pedidoId/');
      _channel = WebSocketChannel.connect(uri);
    } catch (e) {
      developer.log('Erro ao conectar WebSocket para entrega $pedidoId: $e', name: 'CourierGpsService');
      return false;
    }

    // 3. Configurar LocationSettings com filtro de 10 metros para poupar bateria e dados
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10, // Apenas dispara se o estafeta se mover pelo menos 10 metros
    );

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        _enviarPosicaoGps(position);
      },
      onError: (error) {
        developer.log('Erro no stream GPS: $error', name: 'CourierGpsService');
      },
    );

    _isTracking = true;
    developer.log('Telemetria GPS iniciada para pedido $pedidoId (filtro: 10m).', name: 'CourierGpsService');
    return true;
  }

  /// Transmite a posição atual do estafeta no canal da corrida
  void _enviarPosicaoGps(Position position) {
    if (_channel == null || !_isTracking) return;

    try {
      final payload = jsonEncode({
        'lat': position.latitude,
        'lon': position.longitude,
        'heading': position.heading,
        'velocidade': position.speed,
        'timestamp': DateTime.now().toIso8601String(),
      });

      _channel!.sink.add(payload);
    } catch (e) {
      developer.log('Falha ao enviar pacote GPS via WebSocket: $e', name: 'CourierGpsService');
    }
  }

  /// Para a transmissão e liberta recursos
  Future<void> stopTracking() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;

    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    _pedidoIdAtivo = null;
    _isTracking = false;
    developer.log('Telemetria GPS do estafeta encerrada.', name: 'CourierGpsService');
  }
}
