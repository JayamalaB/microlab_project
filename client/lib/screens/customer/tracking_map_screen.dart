import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/screens/customer/lab_progress_screen.dart';

class TrackingMapScreen extends StatefulWidget {
  final int bookingId;
  final int patientId;
  final String trackingId;
  final int technicianId;
  final String technicianName;
  final double? patientLat;
  final double? patientLng;
  final String patientAddress;

  const TrackingMapScreen({
    super.key,
    required this.bookingId,
    required this.patientId,
    required this.trackingId,
    required this.technicianId,
    required this.technicianName,
    required this.patientLat,
    required this.patientLng,
    required this.patientAddress,
  });

  @override
  State<TrackingMapScreen> createState() => _TrackingMapScreenState();
}

class _TrackingMapScreenState extends State<TrackingMapScreen> {
  GoogleMapController? _mapController;

  LatLng? _techLocation;
  final Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};

  bool _enRoute = false;
  bool _arrived = false;
  bool _completed = false;
  bool _followTech = true;
  bool _programmaticMove = false;
  bool _liveActive = false;
  bool _arrivedSnackShown = false;

  // Custom bitmap markers
  BitmapDescriptor? _techIcon;
  BitmapDescriptor? _patientIcon;

  // Route
  LatLng? _lastRouteFetchPos;

  // Dedup — server sends location_update both via room and direct socket
  LatLng? _lastReceivedPos;
  DateTime? _lastReceivedAt;

  // Smooth lerp animation
  Timer? _lerpTimer;

  // ETA & progress
  double? _initialDistKm;
  double? _distKm;
  int? _etaMinutes;

  StreamSubscription<LocationUpdate>? _locationSub;
  StreamSubscription<int>? _enRouteSub;
  StreamSubscription<int>? _arrivedSub;
  StreamSubscription<int>? _completedSub;
  StreamSubscription<bool>? _connectedSub;

  // Last 4 digits of bookingId
  String get _pin {
    final s = widget.bookingId.toString();
    return s.length >= 4 ? s.substring(s.length - 4) : s.padLeft(4, '0');
  }

  String get _initials {
    final parts = widget.technicianName.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return widget.technicianName.isNotEmpty
        ? widget.technicianName[0].toUpperCase()
        : 'T';
  }

  @override
  void initState() {
    super.initState();

    _drawTechIcon();
    _drawPatientPin();

    // Restore status from in-memory state (survives navigation, not app restart)
    final stored = SocketService.instance.activeLabBooking.value;
    if (stored != null && stored.bookingId == widget.bookingId) {
      _enRoute = stored.enRoute;
      _arrived = stored.arrived;
    }

    _setupSocket();
    _fetchBookingStatus(); // Restore authoritative status from DB
  }

  // ── Socket setup (handles initial connect + every reconnect) ─────────────────

  void _setupSocket() {
    // Re-join tracking room and re-register patient socket on every reconnect.
    // Without this, a brief socket drop removes the patient from the room and
    // all subsequent location_update broadcasts are silently lost.
    _connectedSub = SocketService.instance.onConnected.listen((connected) {
      if (!connected || !mounted) return;
      SocketService.instance.joinTracking(widget.trackingId);
      SocketService.instance.registerPatientSocket(
        patientId: widget.patientId,
        bookingId: widget.bookingId,
      );
    });

    // If already connected right now, join immediately
    if (SocketService.instance.isConnected) {
      SocketService.instance.joinTracking(widget.trackingId);
      SocketService.instance.registerPatientSocket(
        patientId: widget.patientId,
        bookingId: widget.bookingId,
      );
    }

    _locationSub = SocketService.instance.onLocationUpdate.listen((update) {
      if (update.trackingId != widget.trackingId) return;
      _onLocationUpdate(update);
    });

    _enRouteSub = SocketService.instance.onTechnicianEnRoute.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      debugPrint('📡 [TRACKING] technician_en_route received for bookingId=$id');
      setState(() => _enRoute = true);
      HapticFeedback.lightImpact();
      if (_techLocation != null && widget.patientLat != null) {
        _lastRouteFetchPos = _techLocation; // prevent double-fetch on next ping
        _fetchRoute(_techLocation!, LatLng(widget.patientLat!, widget.patientLng!));
      }
    });

    _arrivedSub = SocketService.instance.onTechnicianArrived.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      debugPrint('📡 [TRACKING] technician_arrived received for bookingId=$id');
      setState(() {
        _arrived = true;
        _enRoute = false;
        _distKm = 0;
        _etaMinutes = 0;
        _polylines = {};
      });
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 300), () => HapticFeedback.heavyImpact());
      Future.delayed(const Duration(milliseconds: 600), () => HapticFeedback.heavyImpact());
      if (!_arrivedSnackShown && mounted) {
        _arrivedSnackShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.location_on_rounded, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('Technician has arrived!',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            backgroundColor: AppColors.brandGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });

    _completedSub = SocketService.instance.onCollectionCompleted.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      debugPrint('📡 [TRACKING] collection_completed received for bookingId=$id');
      setState(() => _completed = true);
      HapticFeedback.heavyImpact();
    });
  }

  // ── Restore booking status from DB (survives app restarts) ───────────────────

  Future<void> _fetchBookingStatus() async {
    debugPrint('\n🔍 [TRACKING] Fetching booking status for bookingId=${widget.bookingId}');
    try {
      final url = Uri.parse(
          '${AppConstants.serverUrl}/api/bookings/${widget.bookingId}');
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      debugPrint('   HTTP ${res.statusCode}: ${res.body}');
      if (!mounted || res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final booking = data['booking'] as Map<String, dynamic>?;
      if (booking == null) return;
      final status = booking['collection_status'] as String? ?? '';
      debugPrint('   collection_status from DB: "$status"');
      if (!mounted) return;
      setState(() {
        if (status == 'en_route') {
          _enRoute = true;
          debugPrint('   → State: en_route=true');
        } else if (status == 'arrived') {
          _arrived = true;
          _enRoute = false;
          debugPrint('   → State: arrived=true');
        } else if (status == 'collected' ||
            status == 'sample_received' ||
            status == 'test_in_progress' ||
            status == 'report_ready') {
          _completed = true;
          debugPrint('   → State: completed=true (lab stage: $status)');
        } else {
          debugPrint('   → State: no change (status=$status)');
        }
      });
    } catch (e) {
      debugPrint('   ❌ _fetchBookingStatus error: $e');
    }
  }

  @override
  void dispose() {
    _lerpTimer?.cancel();
    _locationSub?.cancel();
    _enRouteSub?.cancel();
    _arrivedSub?.cancel();
    _completedSub?.cancel();
    _connectedSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ── Custom bitmap markers ────────────────────────────────────────────────────

  Future<void> _drawTechIcon() async {
    const size = 60.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..isAntiAlias = true;

    // Outer green circle
    paint
      ..color = AppColors.brandGreen
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, paint);

    // White ring
    paint
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 4, paint);

    // White inner circle
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2 - 10, paint);

    // Green vial shape inside
    paint.color = AppColors.brandGreen;
    final vialBody = RRect.fromLTRBR(
        size / 2 - 6, size / 2 - 6, size / 2 + 6, size / 2 + 11,
        const Radius.circular(4));
    canvas.drawRRect(vialBody, paint);
    canvas.drawRect(const Rect.fromLTWH(size / 2 - 3, size / 2 - 12, 6, 8), paint);

    final img = await recorder
        .endRecording()
        .toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted || bytes == null) return;

    // ignore: deprecated_member_use
    final desc = BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
    setState(() => _techIcon = desc);
    _rebuildPatientMarker();
  }

  Future<void> _drawPatientPin() async {
    const w = 40.0, h = 54.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..isAntiAlias = true;

    // Teardrop pin
    paint
      ..color = AppColors.brandGreen
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(w / 2, h)
      ..cubicTo(w / 2, h, 0, h * 0.6, 0, w / 2)
      ..arcToPoint(const Offset(w, w / 2),
          radius: const Radius.circular(w / 2), clockwise: false)
      ..cubicTo(w, h * 0.6, w / 2, h, w / 2, h)
      ..close();
    canvas.drawPath(path, paint);

    // White inner circle
    paint.color = Colors.white;
    canvas.drawCircle(const Offset(w / 2, w / 2), w / 2 - 8, paint);

    // Green center dot
    paint.color = AppColors.brandGreen;
    canvas.drawCircle(const Offset(w / 2, w / 2), 5, paint);

    final img = await recorder
        .endRecording()
        .toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted || bytes == null) return;

    // ignore: deprecated_member_use
    final desc = BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
    setState(() => _patientIcon = desc);
    _rebuildPatientMarker();
  }

  void _rebuildPatientMarker() {
    if (!mounted || widget.patientLat == null) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'patient');
      _markers.add(Marker(
        markerId: const MarkerId('patient'),
        position: LatLng(widget.patientLat!, widget.patientLng!),
        infoWindow: const InfoWindow(title: 'Your Location'),
        icon: _patientIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        anchor: const Offset(0.5, 1.0),
      ));
    });
  }

  // ── Route (Directions API) ───────────────────────────────────────────────────

  Future<void> _fetchRoute(LatLng origin, LatLng dest) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${dest.latitude},${dest.longitude}'
        '&mode=driving'
        '&key=${AppConstants.googleMapsApiKey}',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 10));
      if (!mounted || res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = data['routes'] as List?;
      if (routes == null || routes.isEmpty) return;
      final encoded =
          routes[0]['overview_polyline']['points'] as String;
      final points = _decodePolyline(encoded);
      if (!mounted) return;
      setState(() {
        _polylines = {
          Polyline(
            polylineId: const PolylineId('route'),
            points: points,
            color: Colors.black87,
            width: 5,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        };
      });
    } catch (_) {}
  }

  List<LatLng> _decodePolyline(String encoded) {
    final result = <LatLng>[];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int b, shift = 0, r = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        r |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : r >> 1;
      shift = 0;
      r = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        r |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : r >> 1;
      result.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return result;
  }

  void _updateRouteIfNeeded(LatLng techPos) {
    if (_arrived || widget.patientLat == null) return;
    final patPos = LatLng(widget.patientLat!, widget.patientLng!);
    if (_lastRouteFetchPos == null ||
        _haversineKm(_lastRouteFetchPos!, techPos) > 0.05) {
      _lastRouteFetchPos = techPos;
      _fetchRoute(techPos, patPos);
    }
  }

  // ── Smooth marker animation (Timer.periodic lerp, 30 steps × 48 ms) ─────────

  void _animateTechTo(LatLng from, LatLng to) {
    _lerpTimer?.cancel();
    const steps = 30;
    int step = 0;
    _lerpTimer = Timer.periodic(const Duration(milliseconds: 48), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      step++;
      final frac = step / steps;
      final pos = LatLng(
        from.latitude + (to.latitude - from.latitude) * frac,
        from.longitude + (to.longitude - from.longitude) * frac,
      );
      _techLocation = pos;
      _markers.removeWhere((m) => m.markerId.value == 'tech');
      _markers.add(Marker(
        markerId: const MarkerId('tech'),
        position: pos,
        infoWindow: InfoWindow(title: widget.technicianName),
        icon: _techIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        flat: true,
        anchor: const Offset(0.5, 0.5),
      ));
      if (step >= steps) {
        t.cancel();
        if (_followTech) {
          _programmaticMove = true;
          _mapController?.animateCamera(CameraUpdate.newLatLng(pos));
        }
      }
      setState(() {});
    });
  }

  // ── Location update ──────────────────────────────────────────────────────────

  void _onLocationUpdate(LocationUpdate update) {
    if (!mounted) return;
    final newPos = LatLng(update.lat, update.lng);

    // Deduplicate: server sends location_update via both room broadcast and
    // direct socket. Drop the second delivery if same coords within 2 seconds.
    final now = DateTime.now();
    if (_lastReceivedPos != null &&
        _lastReceivedAt != null &&
        now.difference(_lastReceivedAt!).inMilliseconds < 2000 &&
        _lastReceivedPos!.latitude == newPos.latitude &&
        _lastReceivedPos!.longitude == newPos.longitude) {
      return;
    }
    _lastReceivedPos = newPos;
    _lastReceivedAt = now;
    final from = _techLocation ?? newPos;

    if (!_liveActive) setState(() => _liveActive = true);

    if (widget.patientLat != null && !_arrived) {
      final patientPos = LatLng(widget.patientLat!, widget.patientLng!);
      final d = _haversineKm(newPos, patientPos);
      _initialDistKm ??= d;
      final speedKmh = (update.speed != null && update.speed! > 0.5)
          ? update.speed! * 3.6
          : 25.0;
      final etaMin = ((d / speedKmh) * 60).ceil().clamp(1, 999);
      setState(() {
        _distKm = d;
        _etaMinutes = etaMin;
      });
    }

    _animateTechTo(from, newPos);
    _updateRouteIfNeeded(newPos);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  double _haversineKm(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final aa = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return R *
        2 *
        math.atan2(math.sqrt(aa.toDouble()), math.sqrt(1 - aa.toDouble()));
  }

  double get _journeyProgress {
    if (_arrived) return 1.0;
    if (_initialDistKm == null || _initialDistKm! == 0 || _distKm == null) {
      return 0;
    }
    return (1 - (_distKm! / _initialDistKm!)).clamp(0.0, 1.0);
  }

  LatLng get _initialCamera => widget.patientLat != null
      ? LatLng(widget.patientLat!, widget.patientLng!)
      : const LatLng(13.0827, 80.2707);

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_completed) return _buildCompletedScreen();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        body: Stack(
          children: [
            // Map
            GoogleMap(
              initialCameraPosition:
                  CameraPosition(target: _initialCamera, zoom: 14),
              markers: _markers,
              polylines: _polylines,
              myLocationEnabled: false,
              onMapCreated: (c) {
                _mapController = c;
                _rebuildPatientMarker();
              },
              onCameraMove: (_) {
                if (_programmaticMove) {
                  _programmaticMove = false;
                  return;
                }
                if (_followTech) setState(() => _followTech = false);
              },
            ),

            // Top bar
            SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _CircleButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      onTap: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 10),
                    // Status pill
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black12,
                              blurRadius: 8,
                              offset: Offset(0, 2))
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _liveActive
                                  ? AppColors.brandGreen
                                  : Colors.orange,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _liveActive ? 'Live' : 'Connecting…',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary),
                          ),
                          const SizedBox(width: 8),
                          Container(
                              width: 1, height: 14, color: AppColors.divider),
                          const SizedBox(width: 8),
                          Text(
                            widget.technicianName,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    _CircleButton(
                      icon: Icons.my_location_rounded,
                      highlighted: !_followTech && _techLocation != null,
                      onTap: () {
                        if (_techLocation == null) return;
                        setState(() => _followTech = true);
                        _programmaticMove = true;
                        _mapController?.animateCamera(
                            CameraUpdate.newLatLng(_techLocation!));
                      },
                    ),
                  ],
                ),
              ),
            ),

            // En route banner
            if (_enRoute && !_arrived)
              Positioned(
                top: 80,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1565C0),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black26,
                          blurRadius: 10,
                          offset: Offset(0, 3))
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.directions_bike_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('Technician is on the way!',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                      ),
                      if (_etaMinutes != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '~$_etaMinutes min',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

            // Arrived banner
            if (_arrived)
              Positioned(
                top: 80,
                left: 16,
                right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black26,
                          blurRadius: 10,
                          offset: Offset(0, 3))
                    ],
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.location_on_rounded,
                          color: Colors.white, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text('Technician has arrived!',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                      ),
                      SizedBox(
                        width: 8,
                        height: 8,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: Colors.white, shape: BoxShape.circle),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // PIN digit boxes + ETA chip row
            Positioned(
              bottom: 270,
              left: 16,
              right: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // PIN card with individual digit boxes
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [
                        BoxShadow(
                            color: Colors.black12,
                            blurRadius: 8,
                            offset: Offset(0, 2))
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'VERIFICATION PIN',
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textHint,
                              letterSpacing: 0.5),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: _pin.split('').map((ch) {
                            return Container(
                              margin: const EdgeInsets.only(right: 4),
                              width: 28,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.brandGreenSurface,
                                borderRadius: BorderRadius.circular(6),
                                border:
                                    Border.all(color: AppColors.brandGreenLight),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                ch,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.brandGreen),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // "Arriving in X min" chip
                  if (!_arrived && _etaMinutes != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreen,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black26,
                              blurRadius: 8,
                              offset: Offset(0, 2))
                        ],
                      ),
                      child: Text(
                        'Arriving in $_etaMinutes min',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700),
                      ),
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
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 16,
                        offset: Offset(0, -4))
                  ],
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        // Dark navy initials avatar
                        Container(
                          width: 48,
                          height: 48,
                          decoration: const BoxDecoration(
                            color: Color(0xFF1A2340),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _initials,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),

                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.technicianName,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary),
                              ),
                              Text(
                                _arrived
                                    ? 'Arrived at your location'
                                    : _enRoute
                                        ? 'En Route — On the way to you'
                                        : _liveActive
                                            ? 'On the way to you'
                                            : 'Locating technician…',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _arrived
                                      ? AppColors.brandGreen
                                      : _enRoute
                                          ? const Color(0xFF1565C0)
                                          : AppColors.textSecondary,
                                  fontWeight: (_arrived || _enRoute)
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // ETA chip or live/connecting badge
                        if (_enRoute && !_arrived && _etaMinutes != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(
                              color: AppColors.blueSurface,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '$_etaMinutes',
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w800,
                                      color: AppColors.blue),
                                ),
                                const Text('min',
                                    style: TextStyle(
                                        fontSize: 9, color: AppColors.blue)),
                              ],
                            ),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: _liveActive
                                  ? AppColors.brandGreenSurface
                                  : const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: _liveActive
                                        ? AppColors.brandGreen
                                        : Colors.orange,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _liveActive ? 'Live' : 'Connecting',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: _liveActive
                                          ? AppColors.brandGreen
                                          : Colors.orange,
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),

                    // Journey progress bar with labels
                    if (_enRoute && !_arrived && _initialDistKm != null) ...[
                      const SizedBox(height: 14),
                      const Row(
                        children: [
                          Text('Technician',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textHint,
                                  fontWeight: FontWeight.w500)),
                          Spacer(),
                          Text('You',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: AppColors.textHint,
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: _journeyProgress,
                                minHeight: 6,
                                backgroundColor: AppColors.divider,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                    AppColors.blue),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _distKm != null
                                ? _distKm! < 1
                                    ? '${(_distKm! * 1000).round()} m'
                                    : '${_distKm!.toStringAsFixed(1)} km'
                                : '',
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 12),
                    const Divider(height: 1),
                    const SizedBox(height: 10),

                    // Collection address card
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.home_outlined,
                              size: 16, color: AppColors.brandGreen),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'COLLECTION ADDRESS',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textHint,
                                      letterSpacing: 0.5),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  widget.patientAddress,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w500),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
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

  // ── Completed screen (full Scaffold) ─────────────────────────────────────────

  Widget _buildCompletedScreen() {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                    color: AppColors.brandGreenSurface,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.science_rounded,
                      color: AppColors.brandGreen, size: 52),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Sample Collected!',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your samples have been collected\nsuccessfully. Results will be ready soon.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      height: 1.55),
                ),
                const SizedBox(height: 44),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(
                          builder: (_) => LabProgressScreen(
                            bookingId: widget.bookingId,
                            patientName:
                                SocketService.instance.userName.isEmpty
                                    ? 'Patient'
                                    : SocketService.instance.userName,
                          ),
                        ),
                        (route) => route.isFirst,
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text('Track Lab Progress',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).popUntil((r) => r.isFirst),
                  child: const Text(
                    'Back to Home',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool highlighted;

  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: highlighted ? AppColors.blue : Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12), blurRadius: 8)
            ],
          ),
          child: Icon(icon,
              size: 16,
              color: highlighted ? Colors.white : AppColors.textPrimary),
        ),
      );
}
