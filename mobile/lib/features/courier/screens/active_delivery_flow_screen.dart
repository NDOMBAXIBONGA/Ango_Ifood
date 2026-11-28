import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/app_environment_config.dart';
import '../../auth/storage/secure_token_storage.dart';
import '../courier_flow_screens.dart';
import '../courier_pin_verification_sheet.dart';
import '../services/courier_gps_service.dart';

/// Ecrã de Gestão Operacional de Corrida Ativa (`ActiveDeliveryFlowScreen`).
/// Integrado 100% com o backend Django/PostGIS (`/api/v1/logistics/trips/active/`)
/// e acompanhando o estafeta pelas 5 etapas essenciais:
/// 1. A caminho da loja (Mapa OSRM + Navegação GPS);
/// 2. Chegada à loja parceira (`POST /trips/{id}/arrive-store/` - Timer espera RN-089);
/// 3. Confirmação de recolha dos sacos com checklist de artigos (`POST /trips/{id}/pickup/` - RN-093 + Telemetria WS RN-094);
/// 4. A caminho do cliente (`POST /delivery/arrive/` - Tolerância 7m RN-096);
/// 5. Validação presencial do PIN de 4 dígitos do cliente ou Ausência (`POST /delivery/verify-pin/` - RN-095 / RN-097).
class ActiveDeliveryFlowScreen extends StatefulWidget {
  final VoidCallback? onGoToRadar;
  final VoidCallback? onDeliveryFinished;
  final int refreshTrigger;

  const ActiveDeliveryFlowScreen({
    super.key,
    this.onGoToRadar,
    this.onDeliveryFinished,
    this.refreshTrigger = 0,
  });

  @override
  State<ActiveDeliveryFlowScreen> createState() =>
      _ActiveDeliveryFlowScreenState();
}

enum DeliveryStep {
  aCaminhoLoja,
  naLoja,
  aCaminhoCliente,
  noCliente,
  concluido,
}

class _ActiveDeliveryFlowScreenState extends State<ActiveDeliveryFlowScreen> {
  final Dio _dio = createSecureDioClient(tokenStorage: SecureTokenStorage());

  bool _isLoading = true;
  bool _isActionSubmitting = false;
  bool _hasActiveOrder = false;

  DeliveryStep _currentStep = DeliveryStep.aCaminhoLoja;

  // Dados reais da corrida ativa vindos do backend
  String _entregaId = '';
  String _pedidoId = '';
  String _numeroExibicao = '';
  String _pinEsperadoInfo = '';

  String _lojaNome = '';
  String _lojaMorada = '';
  String _lojaTelemovel = '';
  double _lojaLat = -8.8368;
  double _lojaLng = 13.2343;

  String _clienteNome = '';
  String _clienteTelemovel = '';
  String _clienteMorada = '';
  String _clienteReferencia = '';
  String _clienteInstrucoes = '';
  double _clienteLat = -8.8147;
  double _clienteLng = 13.2343;

  int _taxaEntregaCentimos = 60000;
  int _gorjetaCentimos = 0;
  int _bonusEsperaCentimos = 0;
  int _ganhoTotalCentimos = 60000;
  String _metodoPagamento = 'MULTICAIXA_EXPRESS';

  double _distanciaKm = 2.5;
  int _etaMinutos = 12;
  int _minutosEsperaLoja = 0;
  int _segundosRestantesTolerancia = 420;

  List<Map<String, dynamic>> _itensPedido = const [];
  final Set<int> _checkedItemIndices = {};
  List<LatLng> _routePoints = const [];

  @override
  void initState() {
    super.initState();
    _loadActiveTrip();
  }

  @override
  void didUpdateWidget(covariant ActiveDeliveryFlowScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTrigger != oldWidget.refreshTrigger) {
      _loadActiveTrip();
    }
  }

  DeliveryStep _parseStep(String raw) {
    switch (raw) {
      case 'naLoja':
        return DeliveryStep.naLoja;
      case 'aCaminhoCliente':
        return DeliveryStep.aCaminhoCliente;
      case 'noCliente':
        return DeliveryStep.noCliente;
      case 'concluido':
        return DeliveryStep.concluido;
      default:
        return DeliveryStep.aCaminhoLoja;
    }
  }

  Future<void> _loadActiveTrip({bool showSpinner = true}) async {
    if (showSpinner && mounted) {
      setState(() => _isLoading = true);
    }
    try {
      final resp = await _dio.get<dynamic>('/api/v1/logistics/trips/active/');
      if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
        final d = resp.data as Map<String, dynamic>;
        if (d['has_active_trip'] == true) {
          _applyTripPayload(d);
          await _loadOsrmRoute();
          return;
        }
      }
      if (mounted) {
        setState(() {
          _hasActiveOrder = false;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyTripPayload(Map<String, dynamic> d) {
    final loja = (d['loja'] as Map<String, dynamic>?) ?? {};
    final cliente = (d['cliente'] as Map<String, dynamic>?) ?? {};
    final fin = (d['financeiro'] as Map<String, dynamic>?) ?? {};
    final tempos = (d['tempos'] as Map<String, dynamic>?) ?? {};
    final rawItens = (d['itens'] as List<dynamic>?) ?? const [];

    final step = _parseStep(d['etapa_atual']?.toString() ?? 'aCaminhoLoja');
    final pId = d['pedido_id']?.toString() ?? '';

    if (step == DeliveryStep.aCaminhoCliente || step == DeliveryStep.noCliente) {
      if (pId.isNotEmpty) {
        unawaited(CourierGpsService().startTracking(pedidoId: pId));
      }
    }

    if (!mounted) return;
    setState(() {
      _hasActiveOrder = true;
      _isLoading = false;
      _entregaId = d['entrega_id']?.toString() ?? '';
      _pedidoId = pId;
      _numeroExibicao = d['numero_exibicao']?.toString() ?? 'LUA';
      _pinEsperadoInfo = d['pin_entrega']?.toString() ?? '';
      _currentStep = step;

      _lojaNome = loja['nome']?.toString() ?? 'Restaurante Parceiro';
      _lojaMorada = loja['morada']?.toString() ?? 'Luanda, Angola';
      _lojaTelemovel = loja['telemovel']?.toString() ?? '+244923000000';
      _lojaLat = (loja['latitude'] as num?)?.toDouble() ?? -8.8368;
      _lojaLng = (loja['longitude'] as num?)?.toDouble() ?? 13.2343;

      _clienteNome = cliente['nome']?.toString() ?? 'Cliente Delivery Pro';
      _clienteTelemovel = cliente['telemovel']?.toString() ?? '+244923111222';
      _clienteMorada = cliente['morada']?.toString() ?? 'Luanda, Angola';
      _clienteReferencia = cliente['referencia']?.toString() ?? '';
      _clienteInstrucoes = cliente['instrucoes_estafeta']?.toString() ?? '';
      _clienteLat = (cliente['latitude'] as num?)?.toDouble() ?? -8.8147;
      _clienteLng = (cliente['longitude'] as num?)?.toDouble() ?? 13.2343;

      _taxaEntregaCentimos = (fin['taxa_entrega_centimos'] as num?)?.toInt() ?? 60000;
      _gorjetaCentimos = (fin['gorjeta_centimos'] as num?)?.toInt() ?? 0;
      _bonusEsperaCentimos = (fin['bonus_espera_centimos'] as num?)?.toInt() ?? 0;
      _ganhoTotalCentimos = (fin['ganho_total_centimos'] as num?)?.toInt() ?? 60000;
      _metodoPagamento = fin['metodo_pagamento']?.toString() ?? 'MULTICAIXA_EXPRESS';

      _distanciaKm = (tempos['distancia_km'] as num?)?.toDouble() ?? 2.5;
      _etaMinutos = (tempos['eta_minutos'] as num?)?.toInt() ?? 12;
      _minutosEsperaLoja = (tempos['minutos_espera_loja'] as num?)?.toInt() ?? 0;
      _segundosRestantesTolerancia =
          (tempos['segundos_restantes_tolerancia_cliente'] as num?)?.toInt() ?? 420;

      _itensPedido = rawItens.whereType<Map<String, dynamic>>().toList();
    });
  }

  Future<void> _loadOsrmRoute() async {
    try {
      final resp = await _dio.post<dynamic>(
        '/api/v1/logistics/calcular-frete/',
        data: {
          'lat_origem': _lojaLat,
          'lon_origem': _lojaLng,
          'lat_destino': _clienteLat,
          'lon_destino': _clienteLng,
        },
      );
      if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
        final d = resp.data as Map<String, dynamic>;
        List<dynamic>? rawCoords;
        if (d['geometria'] is List) {
          rawCoords = d['geometria'] as List<dynamic>;
        } else {
          final geo = d['geometria_rota'] ?? d['rota_geojson'];
          if (geo is Map<String, dynamic> && geo['coordinates'] is List) {
            rawCoords = geo['coordinates'] as List<dynamic>;
          }
        }
        if (rawCoords != null) {
          final pts = <LatLng>[];
          for (final c in rawCoords) {
            if (c is List && c.length >= 2) {
              final lng = (c[0] as num).toDouble();
              final lat = (c[1] as num).toDouble();
              pts.add(LatLng(lat, lng));
            }
          }
          if (pts.isNotEmpty && mounted) {
            setState(() => _routePoints = pts);
            return;
          }
        }
      }
    } catch (_) {}

    if (mounted) {
      setState(() {
        _routePoints = [
          LatLng(_lojaLat, _lojaLng),
          LatLng(_clienteLat, _clienteLng),
        ];
      });
    }
  }

  Future<void> _advanceStep() async {
    if (_isActionSubmitting) return;
    HapticFeedback.mediumImpact();

    setState(() => _isActionSubmitting = true);
    try {
      switch (_currentStep) {
        case DeliveryStep.aCaminhoLoja:
          final resp = await _dio.post<dynamic>(
            '/api/v1/logistics/trips/$_entregaId/arrive-store/',
          );
          if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
            final corrida = resp.data['corrida'];
            if (corrida is Map<String, dynamic>) {
              _applyTripPayload(corrida);
            } else {
              setState(() => _currentStep = DeliveryStep.naLoja);
            }
          }
          break;

        case DeliveryStep.naLoja:
          final resp = await _dio.post<dynamic>(
            '/api/v1/logistics/trips/$_entregaId/pickup/',
          );
          if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
            final corrida = resp.data['corrida'];
            if (corrida is Map<String, dynamic>) {
              _applyTripPayload(corrida);
            } else {
              setState(() => _currentStep = DeliveryStep.aCaminhoCliente);
            }
            if (_pedidoId.isNotEmpty) {
              unawaited(CourierGpsService().startTracking(pedidoId: _pedidoId));
            }
          }
          break;

        case DeliveryStep.aCaminhoCliente:
          final resp = await _dio.post<dynamic>(
            '/api/v1/logistics/delivery/arrive/',
            data: {
              'pedido_id': _pedidoId,
              'latitude': _clienteLat,
              'longitude': _clienteLng,
            },
          );
          if (resp.statusCode == 200 && resp.data is Map<String, dynamic>) {
            final restante =
                (resp.data['tempo_restante_segundos'] as num?)?.toInt() ?? 420;
            setState(() {
              _currentStep = DeliveryStep.noCliente;
              _segundosRestantesTolerancia = restante;
            });
          } else {
            setState(() => _currentStep = DeliveryStep.noCliente);
          }
          _openPinVerification();
          break;

        case DeliveryStep.noCliente:
          _openPinVerification();
          break;

        case DeliveryStep.concluido:
          await CourierGpsService().stopTracking();
          if (mounted) {
            context.read<CourierBloc>().add(const LoadCourierProfileEvent());
            setState(() => _hasActiveOrder = false);
            widget.onDeliveryFinished?.call();
            widget.onGoToRadar?.call();
          }
          break;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Não foi possível avançar etapa: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isActionSubmitting = false);
      }
    }
  }

  void _openPinVerification() {
    CourierPinVerificationSheet.show(
      context,
      pedidoId: _pedidoId.isNotEmpty ? _pedidoId : _entregaId,
      nomeCliente: _clienteNome,
      moradaClienteTexto: _clienteMorada,
      tempoToleranciaSegundos: _segundosRestantesTolerancia,
      currentLatitude: _clienteLat,
      currentLongitude: _clienteLng,
      onSucessoEntrega: () async {
        await CourierGpsService().stopTracking();
        if (mounted) {
          context.read<CourierBloc>().add(const LoadCourierProfileEvent());
          widget.onDeliveryFinished?.call();
          setState(() {
            _currentStep = DeliveryStep.concluido;
          });
        }
      },
    );
  }

  Future<void> _callPhoneNumber(String phone, String label) async {
    final clean = phone.replaceAll(' ', '');
    final uri = Uri.parse('tel:$clean');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        return;
      }
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Contacto de $label: $phone'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openExternalNavigation() async {
    final isGoingToStore = _currentStep == DeliveryStep.aCaminhoLoja ||
        _currentStep == DeliveryStep.naLoja;
    final destLat = isGoingToStore ? _lojaLat : _clienteLat;
    final destLng = isGoingToStore ? _lojaLng : _clienteLng;

    final googleMapsUri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$destLat,$destLng&travelmode=driving',
    );
    try {
      await launchUrl(googleMapsUri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Coordenadas de destino: $destLat, $destLng'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showIncidentSosDialog() async {
    final motivos = [
      'Avaria mecânica / Furo de pneu na viatura (RN-098)',
      'Acidente de viação ou bloqueio policial em rota',
      'Restaurante fechado ou pedido indisponível',
      'Pacote danificado acidentalmente no transporte (RN-101)',
    ];
    String selectedMotivo = motivos.first;
    bool libertarCorrida = _currentStep == DeliveryStep.aCaminhoLoja ||
        _currentStep == DeliveryStep.naLoja;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E2228),
              title: const Row(
                children: [
                  Icon(Icons.sos_rounded, color: Colors.redAccent),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Reportar Incidente / SOS',
                      style: TextStyle(color: Colors.white, fontSize: 17),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Selecione o motivo do incidente operacional:',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                    ...motivos.map(
                      (m) => RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        activeColor: const Color(0xFF00E676),
                        title: Text(
                          m,
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        value: m,
                        groupValue: selectedMotivo,
                        onChanged: (v) {
                          if (v != null) {
                            setDialogState(() => selectedMotivo = v);
                          }
                        },
                      ),
                    ),
                    if (_currentStep == DeliveryStep.aCaminhoLoja ||
                        _currentStep == DeliveryStep.naLoja) ...[
                      const Divider(color: Colors.white24),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        activeColor: const Color(0xFF00E676),
                        title: const Text(
                          'Transferir corrida para outro estafeta',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        value: libertarCorrida,
                        onChanged: (v) => setDialogState(() => libertarCorrida = v),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Enviar Alerta SOS'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true) return;

    try {
      final resp = await _dio.post<dynamic>(
        '/api/v1/logistics/trips/$_entregaId/incident/',
        data: {
          'motivo': selectedMotivo,
          'libertar_corrida': libertarCorrida,
        },
      );
      if (mounted && resp.statusCode == 200) {
        final msg = (resp.data is Map && resp.data['mensagem'] != null)
            ? resp.data['mensagem'].toString()
            : 'Incidente registado pela central de operações.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
        final libertada = (resp.data is Map && resp.data['corrida_libertada'] == true);
        if (libertada) {
          await _loadActiveTrip();
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121417),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Corrida Ativa',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_hasActiveOrder)
            IconButton(
              tooltip: 'SOS / Reportar Incidente',
              icon: const Icon(Icons.sos_rounded, color: Colors.redAccent),
              onPressed: _showIncidentSosDialog,
            ),
          IconButton(
            tooltip: 'Atualizar Estado da Corrida',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: () => _loadActiveTrip(),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00E676)),
            )
          : (!_hasActiveOrder
              ? _buildNoActiveOrderState(context)
              : _buildActiveDeliveryContent(context)),
    );
  }

  Widget _buildNoActiveOrderState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF00E676).withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delivery_dining_rounded,
                size: 72,
                color: Color(0xFF00E676),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Sem entregas em curso',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Fique Online no Radar e aceite uma oferta para iniciar o acompanhamento passo a passo da corrida.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: widget.onGoToRadar,
              icon: const Icon(Icons.radar_rounded),
              label: const Text('Ir para o Radar de Ofertas'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActiveDeliveryContent(BuildContext context) {
    String stepTitle = '';
    String actionLabel = '';
    IconData actionIcon = Icons.arrow_forward_rounded;

    switch (_currentStep) {
      case DeliveryStep.aCaminhoLoja:
        stepTitle = '1. A Caminho do Restaurante';
        actionLabel = 'Cheguei ao Restaurante';
        actionIcon = Icons.storefront_rounded;
        break;
      case DeliveryStep.naLoja:
        stepTitle = '2. No Restaurante (Conferência e Recolha)';
        actionLabel = 'Confirmar Recolha dos Sacos';
        actionIcon = Icons.shopping_bag_rounded;
        break;
      case DeliveryStep.aCaminhoCliente:
        stepTitle = '3. A Caminho do Cliente (GPS Ativo)';
        actionLabel = 'Cheguei ao Endereço do Cliente';
        actionIcon = Icons.location_on_rounded;
        break;
      case DeliveryStep.noCliente:
        stepTitle = '4. No Destino (Validação de PIN / Tolerância 7m)';
        actionLabel = 'Introduzir PIN de 4 Dígitos / Ausência';
        actionIcon = Icons.pin_rounded;
        break;
      case DeliveryStep.concluido:
        stepTitle = '5. Entrega Concluída e Creditada!';
        actionLabel = 'Finalizar e Voltar ao Radar';
        actionIcon = Icons.check_circle_rounded;
        break;
    }

    final ganhoFormatado = CourierCurrencyFormatter.formatKwanza(_ganhoTotalCentimos);
    final centerLat = (_lojaLat + _clienteLat) / 2;
    final centerLng = (_lojaLng + _clienteLng) / 2;

    return RefreshIndicator(
      onRefresh: () => _loadActiveTrip(showSpinner: false),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. Mapa Interativo OpenStreetMap + Rota Viária OSRM
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: 210,
              child: Stack(
                children: [
                  FlutterMap(
                    options: MapOptions(
                      initialCenter: LatLng(centerLat, centerLng),
                      initialZoom: 13.5,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.delivery.app',
                      ),
                      if (_routePoints.isNotEmpty)
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: _routePoints,
                              strokeWidth: 4.5,
                              color: const Color(0xFF00C853),
                            ),
                          ],
                        ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: LatLng(_lojaLat, _lojaLng),
                            width: 42,
                            height: 42,
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.amber,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.storefront_rounded,
                                color: Colors.black,
                                size: 22,
                              ),
                            ),
                          ),
                          Marker(
                            point: LatLng(_clienteLat, _clienteLng),
                            width: 42,
                            height: 42,
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.redAccent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.person_pin_circle_rounded,
                                color: Colors.white,
                                size: 24,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$_distanciaKm km • ~$_etaMinutos min',
                        style: const TextStyle(
                          color: Color(0xFF00E676),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // 2. Card de Status da Corrida, Loja e Cliente
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2228),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF00E676).withOpacity(0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Pedido #$_numeroExibicao',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E676).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Ganho: $ganhoFormatado',
                        style: const TextStyle(
                          color: Color(0xFF00E676),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  stepTitle,
                  style: const TextStyle(
                    color: Color(0xFF00E676),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                if (_minutosEsperaLoja > 0 && _currentStep == DeliveryStep.naLoja) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Tempo de espera na loja: $_minutosEsperaLoja min (Bónus automático > 10 min - RN-089)',
                    style: const TextStyle(color: Colors.amber, fontSize: 11),
                  ),
                ],
                const SizedBox(height: 10),
                const Divider(color: Colors.white10),
                const SizedBox(height: 8),

                // Origem: Restaurante
                Row(
                  children: [
                    Expanded(
                      child: _buildLocationRow(
                        icon: Icons.store_mall_directory_rounded,
                        iconColor: Colors.amber,
                        label: 'Recolha no Restaurante:',
                        address: '$_lojaNome • $_lojaMorada',
                      ),
                    ),
                    IconButton(
                      tooltip: 'Ligar ao Restaurante',
                      onPressed: () => _callPhoneNumber(_lojaTelemovel, _lojaNome),
                      icon: const Icon(Icons.phone_in_talk_rounded, color: Colors.amber),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Destino: Cliente
                Row(
                  children: [
                    Expanded(
                      child: _buildLocationRow(
                        icon: Icons.location_on_rounded,
                        iconColor: Colors.redAccent,
                        label: 'Entrega a $_clienteNome:',
                        address: _clienteReferencia.isNotEmpty
                            ? '$_clienteMorada ($_clienteReferencia)'
                            : _clienteMorada,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Ligar ao Cliente',
                      onPressed: () => _callPhoneNumber(_clienteTelemovel, _clienteNome),
                      icon: const Icon(Icons.phone_forwarded_rounded, color: Color(0xFF00E676)),
                    ),
                  ],
                ),

                if (_clienteInstrucoes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '📝 Instruções: $_clienteInstrucoes',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 3. Checklist de Artigos do Pedido para Conferência na Recolha (RN-093)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E2228),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Checklist de Artigos para Recolha (RN-093)',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${_itensPedido.length} item(ns)',
                      style: const TextStyle(color: Color(0xFF00E676), fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...List.generate(_itensPedido.length, (idx) {
                  final item = _itensPedido[idx];
                  final qtd = item['quantidade'] ?? 1;
                  final nome = item['nome'] ?? 'Artigo';
                  final checked = _checkedItemIndices.contains(idx);
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: const Color(0xFF00E676),
                    checkColor: Colors.black,
                    value: checked,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _checkedItemIndices.add(idx);
                        } else {
                          _checkedItemIndices.remove(idx);
                        }
                      });
                    },
                    title: Text(
                      '${qtd}x $nome',
                      style: TextStyle(
                        color: checked ? Colors.white54 : Colors.white,
                        decoration: checked ? TextDecoration.lineThrough : null,
                        fontSize: 13,
                      ),
                    ),
                  );
                }),
                const Divider(color: Colors.white12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Pagamento: $_metodoPagamento',
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                    if (_gorjetaCentimos > 0)
                      Text(
                        'Inclui Gorjeta 100%: ${CourierCurrencyFormatter.formatKwanza(_gorjetaCentimos)}',
                        style: const TextStyle(
                          color: Color(0xFF00E676),
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 4. Botão Principal de Avanço de Etapa
          FilledButton.icon(
            onPressed: _isActionSubmitting ? null : _advanceStep,
            icon: _isActionSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : Icon(actionIcon),
            label: Text(
              actionLabel,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 5. Botões de Navegação Externa e Reporte SOS
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openExternalNavigation,
                  icon: const Icon(Icons.navigation_rounded, size: 18),
                  label: const Text('Google Maps / Waze'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _showIncidentSosDialog,
                icon: const Icon(Icons.sos_rounded, color: Colors.redAccent, size: 18),
                label: const Text('SOS / Avaria'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: BorderSide(color: Colors.redAccent.withOpacity(0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildLocationRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String address,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: iconColor, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              Text(
                address,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
