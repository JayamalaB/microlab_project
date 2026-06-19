import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/theme/app_theme.dart';

// ── State machine ──────────────────────────────────────────────────────────────
enum _DriverPhase { idle, enRoute, arrived, completed }

class DriverRequestScreen extends StatefulWidget {
  final int driverId;
  final String driverName;

  const DriverRequestScreen({
    super.key,
    required this.driverId,
    required this.driverName,
  });

  @override
  State<DriverRequestScreen> createState() => _DriverRequestScreenState();
}

class _DriverRequestScreenState extends State<DriverRequestScreen> {
  _DriverPhase _phase = _DriverPhase.idle;
  bool _isOnline = false;

  // Current active booking
  SocketBooking? _activeBooking;

  // Pending request (shown in overlay sheet)
  SocketBooking? _pendingBooking;
  bool _showRequestSheet = false;
  Timer? _requestTimer;
  int _secondsLeft = AppConstants.bookingRequestTimeoutSeconds;

  // Idle heartbeat: emit driver location every 30s while idle
  Timer? _idleHeartbeat;

  // GPS
  LatLng? _driverPos;
  StreamSubscription<Position>? _gpsSub;

  // Map
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  LatLng? _lastRouteFetchPos;

  // Custom marker icons
  BitmapDescriptor? _driverMarkerIcon;
  BitmapDescriptor? _patientMarkerIcon;

  // ETA from driver to patient
  double? _distKm;
  int? _etaMin;

  // Audio player for request beep
  final _player = AudioPlayer();
  Timer? _beepTimer;

  // Socket subscriptions
  StreamSubscription<SocketBooking>? _requestSub;
  StreamSubscription<int>? _cancelledSub;
  StreamSubscription<bool>? _connectedSub;

  @override
  void initState() {
    super.initState();
    _buildMarkerIcons();
    _warmUpGps();
  }

  @override
  void dispose() {
    _requestTimer?.cancel();
    _idleHeartbeat?.cancel();
    _gpsSub?.cancel();
    _requestSub?.cancel();
    _cancelledSub?.cancel();
    _connectedSub?.cancel();
    _beepTimer?.cancel();
    _player.dispose();
    _mapController?.dispose();
    if (_isOnline) SocketService.instance.emitDriverOffline();
    SocketService.instance.disconnect();
    super.dispose();
  }

  // ── GPS warm-up ──────────────────────────────────────────────────────────────
  Future<void> _warmUpGps() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (!mounted) return;
      setState(() => _driverPos = LatLng(pos.latitude, pos.longitude));
    } catch (_) {}
  }

  // ── Go online ────────────────────────────────────────────────────────────────
  void _goOnline() {
    SocketService.instance.connect(
      userId: widget.driverId,
      role: 'driver',
      name: widget.driverName,
      lat: _driverPos?.latitude,
      lng: _driverPos?.longitude,
    );

    _connectedSub?.cancel();
    _connectedSub = SocketService.instance.onConnected.listen((connected) {
      if (!connected || !mounted) return;
      SocketService.instance.emitDriverOnline(
        lat: _driverPos?.latitude ?? 0,
        lng: _driverPos?.longitude ?? 0,
      );
      _startIdleHeartbeat();
    });

    _requestSub?.cancel();
    _requestSub = SocketService.instance.onBookingRequest.listen((booking) {
      if (!mounted || _phase != _DriverPhase.idle || _showRequestSheet) return;
      _showIncomingRequest(booking);
    });

    // booking_cancelled fires when another driver accepts — dismiss our overlay silently.
    // Per dispatch spec: timeout ≠ decline; silent dismissal must NOT emit booking_declined.
    _cancelledSub?.cancel();
    _cancelledSub = SocketService.instance.onBookingCancelled.listen((cancelledId) {
      if (!mounted || !_showRequestSheet) return;
      if (_pendingBooking?.bookingId == cancelledId) {
        _dismissRequestSheet();
      }
    });

    if (SocketService.instance.isConnected) {
      SocketService.instance.emitDriverOnline(
        lat: _driverPos?.latitude ?? 0,
        lng: _driverPos?.longitude ?? 0,
      );
      _startIdleHeartbeat();
    }

    setState(() => _isOnline = true);
  }

  // ── Go offline ───────────────────────────────────────────────────────────────
  void _goOffline() {
    _idleHeartbeat?.cancel();
    _requestSub?.cancel();
    SocketService.instance.emitDriverOffline();
    setState(() => _isOnline = false);
  }

  // ── Idle heartbeat ───────────────────────────────────────────────────────────
  void _startIdleHeartbeat() {
    _idleHeartbeat?.cancel();
    _idleHeartbeat = Timer.periodic(
      Duration(seconds: AppConstants.idlePingSeconds),
      (_) {
        if (_driverPos != null && _phase == _DriverPhase.idle) {
          SocketService.instance.emitDriverIdleLocation(
            lat: _driverPos!.latitude,
            lng: _driverPos!.longitude,
          );
        }
      },
    );
  }

  // ── Show incoming request ────────────────────────────────────────────────────
  void _showIncomingRequest(SocketBooking booking) {
    setState(() {
      _pendingBooking = booking;
      _showRequestSheet = true;
      _secondsLeft = AppConstants.bookingRequestTimeoutSeconds;
    });
    HapticFeedback.heavyImpact();
    _startBeeping();
    _startRequestCountdown();
  }

  void _startBeeping() {
    _playBeep();
    _beepTimer = Timer.periodic(const Duration(seconds: 2), (_) => _playBeep());
  }

  Future<void> _playBeep() async {
    HapticFeedback.mediumImpact();
    try {
      await _player.play(BytesSource(_generateBeepWav()));
    } catch (_) {}
  }

  void _startRequestCountdown() {
    _requestTimer?.cancel();
    _requestTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        t.cancel();
        _dismissRequestSheet(fromTimeout: true);
      }
    });
  }

  void _dismissRequestSheet({bool fromTimeout = false}) {
    _requestTimer?.cancel();
    _beepTimer?.cancel();
    _player.stop();
    if (!mounted) return;
    setState(() {
      _showRequestSheet = false;
      if (fromTimeout) _pendingBooking = null;
    });
  }

  // ── Accept ride ───────────────────────────────────────────────────────────────
  void _acceptRide() {
    if (_pendingBooking == null) return;
    _dismissRequestSheet();
    HapticFeedback.mediumImpact();

    final booking = _pendingBooking!;
    _activeBooking = booking;

    SocketService.instance.joinTracking(booking.bookingId.toString());
    SocketService.instance.emitRideBookingAccepted(
      bookingId: booking.bookingId.toString(),
      driverId: widget.driverId,
      driverName: widget.driverName,
    );

    _idleHeartbeat?.cancel();
    _startGpsStream();

    if (booking.patientLat != null && booking.patientLng != null) {
      final patientPos = LatLng(booking.patientLat!, booking.patientLng!);
      setState(() {
        _markers.add(Marker(
          markerId: const MarkerId('patient'),
          position: patientPos,
          icon: _patientMarkerIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(title: booking.patientName),
          zIndexInt: 1,
        ));
      });
      _fetchRoute(_driverPos ?? patientPos, patientPos);
    }

    setState(() {
      _phase = _DriverPhase.enRoute;
      _pendingBooking = null;
    });
  }

  // ── Decline ride ──────────────────────────────────────────────────────────────
  void _declineRide() {
    if (_pendingBooking == null) return;
    final bookingId = _pendingBooking!.bookingId.toString();
    _dismissRequestSheet();
    HapticFeedback.mediumImpact();
    SocketService.instance.emitBookingDeclined(bookingId: bookingId);
    setState(() => _pendingBooking = null);
  }

  // ── GPS stream while en-route / arrived ───────────────────────────────────────
  void _startGpsStream() {
    _gpsSub?.cancel();
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) {
      if (!mounted) return;
      final newPos = LatLng(pos.latitude, pos.longitude);
      final bear = pos.heading;

      setState(() {
        _driverPos = newPos;
        _markers.removeWhere((m) => m.markerId.value == 'driver');
        _markers.add(Marker(
          markerId: const MarkerId('driver'),
          position: newPos,
          icon: _driverMarkerIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueYellow),
          rotation: bear,
          flat: true,
          zIndexInt: 2,
        ));
      });

      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(
          target: newPos,
          zoom: 16,
          tilt: 20,
          bearing: bear,
        )),
      );

      if (_activeBooking?.patientLat != null) {
        final patientPos = LatLng(
            _activeBooking!.patientLat!, _activeBooking!.patientLng!);
        if (_lastRouteFetchPos == null ||
            _haversineKm(newPos, _lastRouteFetchPos!) * 1000 > 50) {
          _fetchRoute(newPos, patientPos);
          _lastRouteFetchPos = newPos;
        }
        final d = _haversineKm(newPos, patientPos);
        final speedKmh = pos.speed > 0.5 ? pos.speed * 3.6 : 40.0;
        setState(() {
          _distKm = d;
          _etaMin = ((d / speedKmh) * 60).ceil().clamp(1, 999);
        });
      }

      if (_phase == _DriverPhase.enRoute || _phase == _DriverPhase.arrived) {
        final bkId = _activeBooking!.bookingId.toString();
        SocketService.instance.emitDriverLocation(
          trackingId: bkId,
          bookingId: bkId,
          lat: pos.latitude,
          lng: pos.longitude,
          speed: pos.speed,
          bearing: bear,
          accuracy: pos.accuracy,
        );
      }
    });
  }

  // ── Mark arrived ──────────────────────────────────────────────────────────────
  void _markArrived() {
    if (_activeBooking == null) return;
    SocketService.instance.emitDriverArrived(
      bookingId: _activeBooking!.bookingId.toString(),
    );
    setState(() => _phase = _DriverPhase.arrived);
    HapticFeedback.heavyImpact();
  }

  // ── Complete trip ─────────────────────────────────────────────────────────────
  void _completeTrip() {
    if (_activeBooking == null) return;
    SocketService.instance.emitTripCompleted(
      bookingId: _activeBooking!.bookingId.toString(),
    );
    _gpsSub?.cancel();
    setState(() => _phase = _DriverPhase.completed);
    HapticFeedback.heavyImpact();
  }

  // ── Reset to idle ─────────────────────────────────────────────────────────────
  void _resetToIdle() {
    setState(() {
      _phase = _DriverPhase.idle;
      _activeBooking = null;
      _markers.clear();
      _polylines.clear();
      _distKm = null;
      _etaMin = null;
      _lastRouteFetchPos = null;
    });
    if (_isOnline) _startIdleHeartbeat();
  }

  // ── Google Directions API ─────────────────────────────────────────────────────
  Future<void> _fetchRoute(LatLng origin, LatLng dest) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${dest.latitude},${dest.longitude}'
        '&mode=driving'
        '&key=${AppConstants.googleMapsApiKey}',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || !mounted) return;
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) return;
      final encoded =
          (routes[0]['overview_polyline'] as Map)['points'] as String;
      final points = _decodePolyline(encoded);

      final legs = (routes[0]['legs'] as List?)?.first as Map?;
      if (legs != null) {
        final distM = (legs['distance'] as Map?)?['value'] as int?;
        final durS  = (legs['duration'] as Map?)?['value'] as int?;
        if (distM != null && durS != null && mounted) {
          setState(() {
            _distKm = distM / 1000;
            _etaMin = (durS / 60).ceil();
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _polylines
          ..removeWhere((p) => p.polylineId.value == 'route')
          ..add(Polyline(
            polylineId: const PolylineId('route'),
            points: points,
            color: const Color(0xFF1A2340),
            width: 5,
            geodesic: true,
            jointType: JointType.round,
          ));
      });
    } catch (_) {}
  }

  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int idx = 0, lat = 0, lng = 0;
    while (idx < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;
      shift = 0; result = 0;
      do {
        b = encoded.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  double _haversineKm(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude  - a.latitude)  * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final aa = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a.latitude  * math.pi / 180) *
        math.cos(b.latitude  * math.pi / 180) *
        math.pow(math.sin(dLon / 2), 2);
    return R * 2 * math.atan2(math.sqrt(aa.toDouble()), math.sqrt(1 - aa.toDouble()));
  }

  // ── Custom marker icons ───────────────────────────────────────────────────────
  Future<void> _buildMarkerIcons() async {
    _driverMarkerIcon = await _renderIcon(
      icon: Icons.local_taxi_rounded,
      bgColor: const Color(0xFFFFC107),
      iconColor: Colors.white,
      logicalSize: 44,
    );
    _patientMarkerIcon = await _renderIcon(
      icon: Icons.person_pin_circle_rounded,
      bgColor: const Color(0xFF2E7D32),
      iconColor: Colors.white,
      logicalSize: 34,
    );
  }

  Future<BitmapDescriptor> _renderIcon({
    required IconData icon,
    required Color bgColor,
    required Color iconColor,
    required double logicalSize,
  }) async {
    final px = (logicalSize * 2).toInt();
    final recorder = ui.PictureRecorder();
    final canvas =
        Canvas(recorder, Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()));
    canvas.drawCircle(Offset(px / 2, px / 2), px / 2 - 2,
        Paint()..color = bgColor);
    canvas.drawCircle(
      Offset(px / 2, px / 2), px / 2 - 2,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = px * 0.06,
    );
    final tp = TextPainter(textDirection: TextDirection.ltr)
      ..text = TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: px * 0.52,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: iconColor,
        ),
      )
      ..layout();
    tp.paint(canvas, Offset((px - tp.width) / 2, (px - tp.height) / 2));
    final picture = recorder.endRecording();
    final img = await picture.toImage(px, px);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    // ignore: deprecated_member_use
    return BitmapDescriptor.bytes(data!.buffer.asUint8List(), width: logicalSize);
  }

  // ── Beep WAV generator (880 Hz, 200 ms, fade-out) ────────────────────────────
  Uint8List _generateBeepWav() {
    const sampleRate = 44100;
    const frequency = 880.0;
    const durationSec = 0.2;
    final numSamples = (sampleRate * durationSec).round();
    final samples = Int16List(numSamples);
    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      final fade = 1.0 - (t / durationSec);
      samples[i] =
          (32767 * fade * math.sin(2 * math.pi * frequency * t)).round();
    }
    final bd = ByteData(44 + numSamples * 2);
    void writeStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        bd.setUint8(offset + i, s.codeUnitAt(i));
      }
    }
    writeStr(0, 'RIFF');
    bd.setUint32(4, 36 + numSamples * 2, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, 1, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    bd.setUint32(40, numSamples * 2, Endian.little);
    for (int i = 0; i < numSamples; i++) {
      bd.setInt16(44 + i * 2, samples[i], Endian.little);
    }
    return bd.buffer.asUint8List();
  }

  // ── Navigate to patient ───────────────────────────────────────────────────────
  Future<void> _openMapsToPatient() async {
    if (_activeBooking?.patientLat == null) return;
    final lat = _activeBooking!.patientLat!;
    final lng = _activeBooking!.patientLng!;
    final uri =
        Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── ETA / distance formatting ─────────────────────────────────────────────────
  String get _etaText {
    if (_distKm == null || _etaMin == null) return '—';
    if (_distKm! < 0.05) return '< 1';
    return _etaMin! <= 1 ? '< 1' : '$_etaMin';
  }

  String get _distText {
    if (_distKm == null) return '—';
    if (_distKm! < 1.0) return '${(_distKm! * 1000).round()}';
    return _distKm!.toStringAsFixed(1);
  }

  String get _distUnit {
    if (_distKm == null) return '';
    return _distKm! < 1.0 ? 'm' : 'km';
  }

  // ── Complete trip dialog ──────────────────────────────────────────────────────
  void _showCompleteTripDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Complete Trip?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: Text(
          'Confirm that you have dropped the patient at ${_activeBooking?.hospital ?? 'the hospital'}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _completeTrip();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandGreen,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isActive = _phase != _DriverPhase.idle && _phase != _DriverPhase.completed;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.background,
        // Hide AppBar during active ride so map fills the screen
        appBar: isActive ? null : _buildIdleAppBar(),
        body: Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: switch (_phase) {
                _DriverPhase.idle      => _buildIdle(),
                _DriverPhase.enRoute   => _buildEnRoute(),
                _DriverPhase.arrived   => _buildEnRoute(),
                _DriverPhase.completed => _buildCompleted(),
              },
            ),

            // Incoming request overlay
            if (_showRequestSheet && _pendingBooking != null)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () {},
                  child: Container(
                    color: Colors.black54,
                    alignment: Alignment.bottomCenter,
                    child: _IncomingRideSheet(
                      booking: _pendingBooking!,
                      driverLat: _driverPos?.latitude ?? 0,
                      driverLng: _driverPos?.longitude ?? 0,
                      secondsLeft: _secondsLeft,
                      totalSeconds: AppConstants.bookingRequestTimeoutSeconds,
                      onAccept: _acceptRide,
                      onDecline: _declineRide,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Idle AppBar ───────────────────────────────────────────────────────────────
  PreferredSizeWidget _buildIdleAppBar() => AppBar(
    backgroundColor: Colors.white,
    elevation: 0,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
      onPressed: () => Navigator.of(context).maybePop(),
    ),
    title: Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.driverName,
          style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary),
        ),
        Text(
          _isOnline ? 'Waiting for requests' : 'You are offline',
          style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w400),
        ),
      ],
    ),
    centerTitle: true,
    actions: [
      GestureDetector(
        onTap: _isOnline ? _goOffline : _goOnline,
        child: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isOnline ? AppColors.brandGreen : AppColors.textHint,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                _isOnline ? 'Online' : 'Offline',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _isOnline ? AppColors.brandGreen : AppColors.textHint,
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );

  // ── IDLE PHASE ────────────────────────────────────────────────────────────────
  Widget _buildIdle() {
    return Center(
      key: const ValueKey('idle'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PulseRing(),
            const SizedBox(height: 32),
            Text(
              _isOnline ? 'Waiting for requests…' : 'You are offline',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              _isOnline
                  ? 'You will be notified when a patient needs a ride'
                  : 'Tap "Offline" in the top-right to go online',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5),
            ),
            if (!_isOnline) ...[
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _goOnline,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 40, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Go Online',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── EN-ROUTE / ARRIVED PHASE ──────────────────────────────────────────────────
  Widget _buildEnRoute() {
    final booking = _activeBooking;
    final isArrived = _phase == _DriverPhase.arrived;
    final initial = (booking?.patientName.isNotEmpty ?? false)
        ? booking!.patientName[0].toUpperCase()
        : 'P';

    return Stack(
      key: const ValueKey('enRoute'),
      children: [
        // Full-screen Google Map
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: _driverPos ?? const LatLng(13.0827, 80.2707),
            zoom: 15,
            tilt: 20,
          ),
          markers: _markers,
          polylines: _polylines,
          myLocationEnabled: false,
          zoomControlsEnabled: false,
          onMapCreated: (c) => _mapController = c,
        ),

        // Top status overlay: back button + status pill
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.15),
                              blurRadius: 8)
                        ],
                      ),
                      child: const Icon(Icons.chevron_left_rounded,
                          size: 26, color: AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 11),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 10)
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isArrived
                                  ? AppColors.brandGreen
                                  : const Color(0xFFF57C00),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            isArrived
                                ? 'Arrived at patient'
                                : 'En route to patient',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: isArrived
                                  ? AppColors.brandGreen
                                  : const Color(0xFFF57C00),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ETA / distance chips — top-left, below status bar
        if (_distKm != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + 68,
            left: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MapChip(
                  mainText: _etaText,
                  unit: 'min',
                  label: 'ETA',
                  mainColor: AppColors.textPrimary,
                ),
                const SizedBox(height: 6),
                _MapChip(
                  mainText: _distText,
                  unit: _distUnit,
                  label: 'away',
                  mainColor: AppColors.brandGreen,
                ),
              ],
            ),
          ),

        // Bottom info card
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black12,
                    blurRadius: 16,
                    offset: Offset(0, -4))
              ],
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AppColors.divider,
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 16),

                // Patient row: avatar + name/phone + status badge
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        color: Color(0xFF1A2340),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          initial,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            booking?.patientName ?? '—',
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary),
                          ),
                          if (booking?.patientMobile.isNotEmpty == true)
                            Text(
                              booking!.patientMobile,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary),
                            ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isArrived
                            ? AppColors.brandGreenSurface
                            : const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        isArrived ? 'Arrived' : 'En route',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isArrived
                              ? AppColors.brandGreen
                              : const Color(0xFFF57C00),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Hospital destination row
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F6F8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFEBEE),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.local_hospital_rounded,
                            color: Color(0xFFD32F2F), size: 16),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          booking?.hospital ?? '—',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Text('Destination',
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textHint)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Action buttons: Navigate + Mark Arrived / Complete Trip
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _openMapsToPatient,
                        icon: const Icon(Icons.navigation_rounded, size: 16),
                        label: const Text('Navigate'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A2340),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          textStyle: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: isArrived
                            ? _showCompleteTripDialog
                            : _markArrived,
                        icon: Icon(
                          isArrived
                              ? Icons.check_circle_rounded
                              : Icons.location_on_rounded,
                          size: 16,
                        ),
                        label: Text(
                            isArrived ? 'Complete Trip' : 'Mark Arrived'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF57C00),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          textStyle: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── COMPLETED PHASE ───────────────────────────────────────────────────────────
  Widget _buildCompleted() {
    return Center(
      key: const ValueKey('completed'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreenSurface,
                  shape: BoxShape.circle),
              child: const Icon(Icons.check_circle_rounded,
                  color: AppColors.brandGreen, size: 44),
            ),
            const SizedBox(height: 24),
            const Text('Trip Completed!',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            Text(
              'Patient dropped at ${_activeBooking?.hospital ?? 'destination'}.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _resetToIdle,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Go Online Again',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  ETA MAP CHIP
// ═════════════════════════════════════════════════════════════════════════════

class _MapChip extends StatelessWidget {
  final String mainText;
  final String unit;
  final String label;
  final Color mainColor;

  const _MapChip({
    required this.mainText,
    required this.unit,
    required this.label,
    required this.mainColor,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.13),
                blurRadius: 10,
                offset: const Offset(0, 2))
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: mainText,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: mainColor,
                    ),
                  ),
                  TextSpan(
                    text: ' $unit',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textHint)),
          ],
        ),
      );
}

// ═════════════════════════════════════════════════════════════════════════════
//  INCOMING RIDE SHEET
// ═════════════════════════════════════════════════════════════════════════════

class _IncomingRideSheet extends StatelessWidget {
  final SocketBooking booking;
  final double driverLat;
  final double driverLng;
  final int secondsLeft;
  final int totalSeconds;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _IncomingRideSheet({
    required this.booking,
    required this.driverLat,
    required this.driverLng,
    required this.secondsLeft,
    required this.totalSeconds,
    required this.onAccept,
    required this.onDecline,
  });

  double get _distKm {
    if (booking.patientLat == null) return 0;
    const R = 6371.0;
    final dLat =
        (booking.patientLat! - driverLat) * math.pi / 180;
    final dLon =
        (booking.patientLng! - driverLng) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(driverLat * math.pi / 180) *
            math.cos(booking.patientLat! * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return R * 2 * math.atan2(math.sqrt(a.toDouble()), math.sqrt(1 - a.toDouble()));
  }

  int get _etaMin => (_distKm / 40 * 60).ceil().clamp(1, 999);

  String _buildMapUrl() {
    final hasDriver = driverLat != 0 && driverLng != 0;
    var url = 'https://maps.googleapis.com/maps/api/staticmap'
        '?size=400x140'
        '&markers=color:green%7Clabel:P%7C${booking.patientLat},${booking.patientLng}'
        '&key=${AppConstants.googleMapsApiKey}';
    if (hasDriver) {
      url += '&markers=color:blue%7Clabel:D%7C$driverLat,$driverLng'
          '&path=color:0x4A90D9%7Cweight:3%7C$driverLat,$driverLng%7C${booking.patientLat},${booking.patientLng}';
    } else {
      url += '&center=${booking.patientLat},${booking.patientLng}&zoom=14';
    }
    return url;
  }

  @override
  Widget build(BuildContext context) {
    final progress = secondsLeft / totalSeconds;
    final ringColor = secondsLeft > 20
        ? const Color(0xFF2E7D32)
        : secondsLeft > 10
            ? const Color(0xFFF57C00)
            : const Color(0xFFD32F2F);
    final dist = _distKm;
    final eta = _etaMin;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 20),

          // Header: taxi icon | title + subtitle | countdown ring
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                    color: Color(0xFFFFF3E0), shape: BoxShape.circle),
                child: const Icon(Icons.local_taxi_rounded,
                    color: Color(0xFFF57C00), size: 28),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'New Ride Request',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary),
                    ),
                    Text(
                      'Patient needs a ride to hospital',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 62,
                height: 62,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CircularProgressIndicator(
                      value: progress,
                      strokeWidth: 5,
                      backgroundColor: Colors.grey.shade200,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(ringColor),
                    ),
                    Text('$secondsLeft',
                        style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            color: ringColor)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Static map preview
          if (booking.patientLat != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.network(
                _buildMapUrl(),
                height: 140,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 80,
                  color: AppColors.background,
                  child: const Center(
                    child: Icon(Icons.map_outlined,
                        color: AppColors.textHint, size: 32),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Distance / time chips
          if (booking.patientLat != null)
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F4FF),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.straighten_rounded,
                      size: 18, color: Color(0xFF3A7BD5)),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${dist.toStringAsFixed(1)} km',
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary),
                      ),
                      const Text('Distance',
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textHint)),
                    ],
                  ),
                  const Spacer(),
                  Container(
                      width: 1, height: 32, color: AppColors.divider),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$eta min',
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: AppColors.brandGreen),
                      ),
                      const Text('Drive time',
                          style: TextStyle(
                              fontSize: 11, color: AppColors.textHint)),
                    ],
                  ),
                  const SizedBox(width: 10),
                  const Icon(Icons.access_time_rounded,
                      size: 18, color: AppColors.brandGreen),
                ],
              ),
            ),
          const SizedBox(height: 14),

          // Patient detail rows
          _RideDetailRow(
            icon: Icons.person_rounded,
            label: booking.patientName,
            secondary: 'Patient',
          ),
          _RideDetailRow(
            icon: Icons.phone_rounded,
            label: booking.patientMobile.isNotEmpty
                ? booking.patientMobile
                : '—',
            secondary: 'Mobile',
          ),
          _RideDetailRow(
            icon: Icons.location_on_outlined,
            label: booking.patientAddress.isNotEmpty
                ? booking.patientAddress
                : (booking.patientLat != null
                    ? '${booking.patientLat!.toStringAsFixed(4)}, '
                        '${booking.patientLng!.toStringAsFixed(4)}'
                    : 'Location not provided'),
            secondary: 'Pickup',
          ),
          _RideDetailRow(
            icon: Icons.local_hospital_outlined,
            label: booking.hospital,
            secondary: 'Hospital',
            color: AppColors.brandGreen,
          ),
          const SizedBox(height: 20),

          // Decline / Accept buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onDecline,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Decline'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFD32F2F),
                    side: const BorderSide(color: Color(0xFFD32F2F)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: onAccept,
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Accept Ride'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Patient detail row ───────────────────────────────────────────────────────

class _RideDetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String secondary;
  final Color? color;

  const _RideDetailRow({
    required this.icon,
    required this.label,
    required this.secondary,
    this.color,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color ?? AppColors.textHint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: color ?? AppColors.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(secondary,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textHint)),
          ],
        ),
      );
}

// ─── Animated pulse ring ──────────────────────────────────────────────────────

class _PulseRing extends StatefulWidget {
  const _PulseRing();

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing> with TickerProviderStateMixin {
  late final AnimationController _c1, _c2;
  late final Animation<double> _s1, _o1, _s2, _o2;

  @override
  void initState() {
    super.initState();
    _c1 = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat();
    _c2 = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..forward(from: 0.6)
      ..repeat();
    _s1 = Tween(begin: 0.4, end: 1.6)
        .animate(CurvedAnimation(parent: _c1, curve: Curves.easeOut));
    _o1 = Tween(begin: 0.9, end: 0.0)
        .animate(CurvedAnimation(parent: _c1, curve: Curves.easeOut));
    _s2 = Tween(begin: 0.4, end: 1.6)
        .animate(CurvedAnimation(parent: _c2, curve: Curves.easeOut));
    _o2 = Tween(begin: 0.9, end: 0.0)
        .animate(CurvedAnimation(parent: _c2, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _c1.dispose();
    _c2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 130,
        height: 130,
        child: Stack(
          alignment: Alignment.center,
          children: [
            _ring(_c1, _s1, _o1),
            _ring(_c2, _s2, _o2),
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreen, shape: BoxShape.circle),
              child: const Icon(Icons.local_taxi_rounded,
                  color: Colors.white, size: 32),
            ),
          ],
        ),
      );

  Widget _ring(
    AnimationController ctrl,
    Animation<double> scale,
    Animation<double> opacity,
  ) =>
      AnimatedBuilder(
        animation: ctrl,
        builder: (_, __) => Transform.scale(
          scale: scale.value,
          child: Opacity(
            opacity: opacity.value,
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border:
                    Border.all(color: AppColors.brandGreen, width: 2.5),
              ),
            ),
          ),
        ),
      );
}
