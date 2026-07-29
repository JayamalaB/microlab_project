import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;
import 'package:microlab/models/technician_booking.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/foreground_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';
import 'technician_booking_detail_screen.dart';

enum _JobStatus { assigned, enRoute, arrived, handedOver }

class TechnicianActiveJobScreen extends StatefulWidget {
  final int bookingId;
  final String patientName;
  final String patientMobile;
  final String patientAddress;
  final double? patientLat;
  final double? patientLng;
  final String hospital;
  // When true the screen opens already in enRoute state (tech started from dashboard)
  final bool startInEnRoute;

  const TechnicianActiveJobScreen({
    super.key,
    required this.bookingId,
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    this.patientLat,
    this.patientLng,
    required this.hospital,
    this.startInEnRoute = false,
  });

  @override
  State<TechnicianActiveJobScreen> createState() =>
      _TechnicianActiveJobScreenState();
}

class _TechnicianActiveJobScreenState extends State<TechnicianActiveJobScreen>
    with TickerProviderStateMixin {
  static const Color _navy = Color(0xFF1A2340);

  _JobStatus _status = _JobStatus.assigned;
  bool _isDisposing = false;
  bool _followMode = true;

  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  LatLng? _lastRouteFetchPos;

  // Beacon (self) animated marker
  BitmapDescriptor? _beaconIcon;
  BitmapDescriptor? _patientIcon;
  late AnimationController _pulseController;

  double? _distKm;     // haversine straight-line — used for progress bar ratio
  double? _roadDistKm; // road distance from Directions API — used for display only
  int? _etaMin;
  double? _initialDistKm;
  double? _speedKmh;

  Position? _myPosition;
  StreamSubscription<Position>? _posSub;
  bool _isMapReady = false;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();

    // When opened from the dashboard "Start Journey", skip the assigned state
    // so the tech doesn't have to tap a second "Start Journey" button.
    if (widget.startInEnRoute) {
      _status = _JobStatus.enRoute;
    }

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    _pulseController.addListener(_rebuildBeacon);

    _drawPatientPin().then((icon) {
      if (!mounted) return;
      setState(() => _patientIcon = icon);
      _rebuildPatientMarker();
    });

    _requestLocationAndStart();
    _rebuildPatientMarker();

    // When resuming a journey (back button → Continue Journey), the screen is a
    // fresh instance with empty _polylines.  Kick off an immediate route fetch
    // using the last-known position so the line reappears without waiting for
    // the GPS stream's first distanceFilter trigger.
    if (widget.startInEnRoute) _restoreRouteOnResume();
  }

  void _restoreRouteOnResume() {
    Geolocator.getLastKnownPosition().then((pos) {
      if (pos == null || !mounted || _isDisposing || _lastRouteFetchPos != null) return;
      final myPos     = LatLng(pos.latitude, pos.longitude);
      final patientPos = widget.patientLat != null && widget.patientLng != null
          ? LatLng(widget.patientLat!, widget.patientLng!)
          : null;
      _lastRouteFetchPos = myPos;
      _fetchRoute(myPos, patientPos);
      setState(() => _myPosition = pos);
      _rebuildSelfMarker();
    });
  }

  @override
  void dispose() {
    _isDisposing = true;
    // If the screen closes without a completed handover (e.g. back button),
    // reset the persistent notification to the waiting state so the technician
    // doesn't see "Collecting from..." when they're actually idle on the dashboard.
    if (_status != _JobStatus.handedOver) {
      ForegroundService.instance.updateText('Ready for booking requests');
    }
    _pulseController.removeListener(_rebuildBeacon);
    _pulseController.dispose();
    _posSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ── Animated beacon icon ─────────────────────────────────────────────────────

  void _rebuildBeacon() {
    if (_isDisposing || !mounted || _myPosition == null) return;
    _drawBeacon(_pulseController.value).then((icon) {
      if (!mounted || _isDisposing) return;
      setState(() => _beaconIcon = icon);
      _rebuildSelfMarker();
    });
  }

  Future<BitmapDescriptor> _drawBeacon(double pulse) async {
    const size = 80.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));

    // Outer pulse ring
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      22 + 16 * pulse,
      Paint()
        ..color = AppColors.brandGreen
            .withValues(alpha: (1 - pulse).clamp(0.0, 1.0) * 0.3)
        ..style = PaintingStyle.fill,
    );

    // Mid ring
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      18,
      Paint()
        ..color = AppColors.brandGreen.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill,
    );

    // White border circle
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      14,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    // Green core
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      12,
      Paint()
        ..color = AppColors.brandGreen
        ..style = PaintingStyle.fill,
    );

    // White inner dot
    canvas.drawCircle(
      const Offset(size / 2, size / 2),
      4,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen);
    }
    // ignore: deprecated_member_use
    return BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _drawPatientPin() async {
    const w = 40.0, h = 54.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..isAntiAlias = true;

    paint
      ..color = const Color(0xFFD32F2F)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(w / 2, h)
      ..cubicTo(w / 2, h, 0, h * 0.6, 0, w / 2)
      ..arcToPoint(const Offset(w, w / 2),
          radius: const Radius.circular(w / 2), clockwise: false)
      ..cubicTo(w, h * 0.6, w / 2, h, w / 2, h)
      ..close();
    canvas.drawPath(path, paint);

    paint.color = Colors.white;
    canvas.drawCircle(const Offset(w / 2, w / 2), w / 2 - 8, paint);

    paint.color = const Color(0xFFD32F2F);
    canvas.drawCircle(const Offset(w / 2, w / 2), 5, paint);

    final img =
        await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed);
    }
    // ignore: deprecated_member_use
    return BitmapDescriptor.fromBytes(bytes.buffer.asUint8List());
  }

  void _rebuildSelfMarker() {
    if (_myPosition == null) return;
    final pos = LatLng(_myPosition!.latitude, _myPosition!.longitude);
    final updated = <Marker>{};
    for (final m in _markers) {
      if (m.markerId.value != 'me') updated.add(m);
    }
    updated.add(Marker(
      markerId: const MarkerId('me'),
      position: pos,
      infoWindow: const InfoWindow(title: 'You'),
      icon: _beaconIcon ??
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      anchor: const Offset(0.5, 0.5),
      rotation: _myPosition!.heading,
      flat: true,
      zIndex: 2,
    ));
    setState(() => _markers = updated);
  }

  void _rebuildPatientMarker() {
    if (widget.patientLat == null || widget.patientLng == null) return;
    final pos = LatLng(widget.patientLat!, widget.patientLng!);
    final updated = <Marker>{};
    for (final m in _markers) {
      if (m.markerId.value != 'patient') updated.add(m);
    }
    updated.add(Marker(
      markerId: const MarkerId('patient'),
      position: pos,
      infoWindow: InfoWindow(title: widget.patientName),
      icon: _patientIcon ??
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      anchor: const Offset(0.5, 1.0),
      zIndex: 1,
    ));
    setState(() => _markers = updated);
  }

  // ── GPS stream ───────────────────────────────────────────────────────────────

  Future<void> _requestLocationAndStart() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        setState(() => _permissionDenied = true);
        _showPermissionDialog();
        return;
      }
      if (perm == LocationPermission.denied) {
        _showPermissionDialog();
        return;
      }

      // Check if location services are enabled
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showLocationServiceDialog();
        return;
      }

      // Emit an immediate position so the customer sees the marker right away,
      // without waiting for the stream's first distanceFilter trigger.
      Geolocator.getLastKnownPosition().then((last) {
        if (last != null && mounted && !_isDisposing) _onNewPosition(last);
      });
      Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).then((pos) {
        if (mounted && !_isDisposing) _onNewPosition(pos);
      }).catchError((_) {});

      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 8,
        ),
      ).listen(_onNewPosition);
    } catch (e) {
      debugPrint('Error requesting location: $e');
      _showPermissionDialog();
    }
  }

  void _showPermissionDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Location Permission Required'),
        content: const Text(
          'This app needs location access to track your journey to the patient.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context); // Go back to dashboard
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _showLocationServiceDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Location Services Disabled'),
        content: const Text(
          'Please enable location services to use this feature.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context); // Go back to dashboard
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openLocationSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _onNewPosition(Position pos) {
    if (!mounted || _isDisposing) return;
    final myPos = LatLng(pos.latitude, pos.longitude);

    setState(() {
      _myPosition = pos;
      _speedKmh = pos.speed > 0.5 ? pos.speed * 3.6 : null;
    });

    // Keep ETA badge and progress bar live on every GPS tick (8 m resolution).
    // Haversine gives the straight-line distance; the Directions API overrides
    // this with the accurate road distance every 50 m when it responds.
    if ((_status == _JobStatus.assigned || _status == _JobStatus.enRoute) &&
        widget.patientLat != null && widget.patientLng != null) {
      final hvKm = _haversineKm(
          myPos, LatLng(widget.patientLat!, widget.patientLng!));
      // Use GPS speed when moving; default 25 km/h when stationary/unknown.
      // 1.3× converts straight-line to approximate road distance for ETA.
      final speedKmh = (pos.speed > 1.0) ? pos.speed * 3.6 : 25.0;
      final estEta = ((hvKm * 1.3 / speedKmh) * 60).ceil().clamp(1, 999);
      setState(() {
        _initialDistKm ??= hvKm; // seed progress bar before first API response
        _distKm = hvKm;          // live straight-line; API overrides when ready
        _etaMin = estEta;
      });
    }

    _rebuildSelfMarker();

    if (_followMode && _mapController != null) {
      _mapController?.animateCamera(CameraUpdate.newCameraPosition(
        CameraPosition(target: myPos, zoom: 16, tilt: 20),
      ));
    }

    // Draw route line and refresh accurate road distance/ETA every 50 m.
    // Works even when patientLat/Lng are null — _fetchRoute falls back to address.
    if (_status == _JobStatus.assigned || _status == _JobStatus.enRoute) {
      final patientPos = widget.patientLat != null && widget.patientLng != null
          ? LatLng(widget.patientLat!, widget.patientLng!)
          : null;
      if (_lastRouteFetchPos == null ||
          _haversineKm(myPos, _lastRouteFetchPos!) * 1000 > 50) {
        _fetchRoute(myPos, patientPos);
        _lastRouteFetchPos = myPos;
      }
    }

    // Always broadcast to the tracking room
    SocketService.instance.emitLocation(
      trackingId: widget.bookingId.toString(),
      bookingId: widget.bookingId,
      lat: pos.latitude,
      lng: pos.longitude,
      accuracy: pos.accuracy,
      speed: pos.speed,
      bearing: pos.heading,
    );
  }

  // ── Directions API ───────────────────────────────────────────────────────────

  // dest may be null when customer skipped the map pin — fall back to text address.
  Future<void> _fetchRoute(LatLng origin, LatLng? dest) async {
    try {
      final apiKey = AppConstants.googleMapsApiKey;
      if (apiKey.isEmpty) {
        debugPrint('Google Maps API key is missing');
        return;
      }

      final destination = dest != null
          ? '${dest.latitude},${dest.longitude}'
          : Uri.encodeComponent(widget.patientAddress);
      if (destination.isEmpty) return;

      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=$destination'
        '&mode=driving'
        '&key=$apiKey',
      );
      
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || !mounted || _isDisposing) return;
      
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = body['routes'] as List?;
      if (routes == null || routes.isEmpty) return;

      final encoded =
          (routes[0]['overview_polyline'] as Map)['points'] as String?;
      if (encoded == null) return;
      
      final points = _decodePolyline(encoded);

      final legs = (routes[0]['legs'] as List?)?.first as Map?;
      if (legs != null) {
        final distM = (legs['distance'] as Map?)?['value'] as int?;
        final durS = (legs['duration'] as Map?)?['value'] as int?;
        if (distM != null && durS != null && mounted && !_isDisposing) {
          final newDist = distM / 1000;
          // Road distance → display only. Progress bar uses haversine (_distKm)
          // so both numerator and denominator are straight-line, preventing the
          // road/haversine mismatch that clamped _journeyProgress to 0.
          setState(() {
            _roadDistKm = newDist;
            _etaMin = (durS / 60).ceil();
            // When patient coords are absent, haversine can't compute distance.
            // Use the road distance the API already returns to drive the
            // progress bar and ETA badge (same data, different purpose).
            if (widget.patientLat == null) {
              _initialDistKm ??= newDist; // seed once on first successful fetch
              _distKm = newDist;          // updated on every 50-m re-fetch
            }
          });
        }
      }

      if (!mounted || _isDisposing) return;
      setState(() {
        _polylines
          ..removeWhere((p) => p.polylineId.value == 'route')
          ..add(Polyline(
            polylineId: const PolylineId('route'),
            points: points,
            color: Colors.black87,
            width: 5,
            geodesic: true,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ));
      });
    } catch (e) {
      debugPrint('Error fetching route: $e');
    }
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
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(idx++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

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
        math.atan2(
            math.sqrt(aa.toDouble()), math.sqrt(1 - aa.toDouble()));
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String get _etaText {
    if (_distKm == null || _etaMin == null) return '—';
    if (_distKm! < 0.05) return '< 1';
    return _etaMin! <= 1 ? '< 1' : '$_etaMin';
  }

  String get _distText {
    final d = _roadDistKm ?? _distKm;
    if (d == null) return '—';
    if (d < 1.0) return '${(d * 1000).round()} m';
    return '${d.toStringAsFixed(1)} km';
  }

  double get _journeyProgress {
    if (_status == _JobStatus.arrived || _status == _JobStatus.handedOver) {
      return 1.0;
    }
    if (_initialDistKm == null || _initialDistKm! == 0 || _distKm == null) {
      return 0;
    }
    return (1 - (_distKm! / _initialDistKm!)).clamp(0.0, 1.0);
  }

  bool get _isEnRoute => _status == _JobStatus.enRoute;
  bool get _isArrived => _status == _JobStatus.arrived;

  String get _initial =>
      widget.patientName.isNotEmpty ? widget.patientName[0].toUpperCase() : 'P';

  LatLng get _initialCamera => widget.patientLat != null && widget.patientLng != null
      ? LatLng(widget.patientLat!, widget.patientLng!)
      : const LatLng(13.0827, 80.2707);

  // ── Status transitions ───────────────────────────────────────────────────────

  void _setEnRoute() {
    setState(() {
      _status = _JobStatus.enRoute;
      _lastRouteFetchPos = null;
      _initialDistKm = null;
      _roadDistKm = null;
    });
    SocketService.instance.emitEnRoute(bookingId: widget.bookingId);
    ForegroundService.instance.updateText('En route to ${widget.patientName}');
    HapticFeedback.mediumImpact();
    if (_myPosition != null) {
      final myPos = LatLng(_myPosition!.latitude, _myPosition!.longitude);
      final patientPos = widget.patientLat != null && widget.patientLng != null
          ? LatLng(widget.patientLat!, widget.patientLng!)
          : null;
      _fetchRoute(myPos, patientPos);
      _lastRouteFetchPos = myPos;
    }
  }

  void _setArrived() {
    setState(() {
      _status = _JobStatus.arrived;
      _distKm = null;
      _roadDistKm = null;
      _etaMin = null;
      _polylines.clear();
      _initialDistKm = null;
    });
    SocketService.instance.emitArrived(bookingId: widget.bookingId);
    ForegroundService.instance.updateText('Arrived at ${widget.patientName}');
    HapticFeedback.mediumImpact();
  }

  void _startCollection() {
    SocketService.instance.emitCollectionStarted(bookingId: widget.bookingId);
    ForegroundService.instance.updateText('Collecting from ${widget.patientName}');
    HapticFeedback.mediumImpact();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TechnicianBookingDetailScreen(
          booking: TechnicianBooking(
            id: widget.bookingId.toString(),
            customerName: widget.patientName,
            customerPhone: widget.patientMobile,
            address: widget.patientAddress,
            city: '',
            pincode: '',
            date: DateTime.now(),
            timeSlot: '',
            testNames: const [],
            mode: 'Home Collection',
            status: 'Collection Started',
            isVip: false,
            docRequired: false,
            docVerified: false,
            serviceChargePaid: 0,
            testsTotal: 0,
            assignedAt: DateTime.now(),
          ),
          cameFromActiveJob: true,
        ),
      ),
    ).then((result) {
      if (!mounted) return;
      if (result == kExitToDashboard) {
        // Technician left mid-journey, not a real completion — cascade the
        // same signal upward instead of running the handed-over choreography.
        Navigator.of(context).pop(kExitToDashboard);
        return;
      }
      if (result == true) {
        // sample_collected and handed_to_lab are already emitted step-by-step
        // inside TechnicianBookingDetailScreen — nothing to emit here.
        ForegroundService.instance.updateText('Ready for booking requests');
        setState(() => _status = _JobStatus.handedOver);
        HapticFeedback.heavyImpact();
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (!mounted) return;
          Navigator.of(context).pop(true);
        });
      }
    });
  }

  void _openInMaps() {
    final Uri url;
    if (widget.patientLat != null && widget.patientLng != null) {
      url = Uri.parse(
          'https://www.google.com/maps/dir/?api=1'
          '&destination=${widget.patientLat},${widget.patientLng}'
          '&travelmode=driving');
    } else if (widget.patientAddress.isNotEmpty) {
      final encoded = Uri.encodeComponent(widget.patientAddress);
      url = Uri.parse(
          'https://www.google.com/maps/dir/?api=1'
          '&destination=$encoded'
          '&travelmode=driving');
    } else {
      return;
    }
    launchUrl(url, mode: LaunchMode.externalApplication).catchError((_) {
      final fallback = widget.patientLat != null && widget.patientLng != null
          ? 'https://maps.google.com/?q=${widget.patientLat},${widget.patientLng}'
          : 'https://maps.google.com/?q=${Uri.encodeComponent(widget.patientAddress)}';
      launchUrl(Uri.parse(fallback), mode: LaunchMode.externalApplication);
      return false;
    });
  }

  void _reCenter() {
    setState(() => _followMode = true);
    if (_myPosition != null && _mapController != null) {
      _mapController?.animateCamera(CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(_myPosition!.latitude, _myPosition!.longitude),
          zoom: 16,
          tilt: 20,
        ),
      ));
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        body: _permissionDenied
            ? _buildPermissionError()
            : Stack(
                children: [
                  // Map
                  GoogleMap(
                    initialCameraPosition:
                        CameraPosition(target: _initialCamera, zoom: 14),
                    markers: _markers,
                    polylines: _polylines,
                    myLocationEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                    onMapCreated: (c) {
                      _mapController = c;
                      _isMapReady = true;
                      _rebuildPatientMarker();
                    },
                    onCameraMoveStarted: () {
                      if (mounted && _followMode) setState(() => _followMode = false);
                    },
                  ),

                  // Top bar: back + status pill
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: Row(
                          children: [
                            _fab(
                              icon: Icons.chevron_left_rounded,
                              onTap: () => Navigator.of(context).maybePop(),
                            ),
                            const SizedBox(width: 10),
                            if (_isEnRoute || _isArrived)
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
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: _isArrived
                                              ? AppColors.brandGreen
                                              : const Color(0xFFF57C00),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _isArrived
                                            ? 'Arrived at patient'
                                            : 'En route to patient',
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: _isArrived
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

                  // No-coordinates warning banner
                  if (widget.patientLat == null && _isEnRoute)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 64,
                      left: 12,
                      right: 56,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3CD),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: const Color(0xFFFFCC02).withValues(alpha: 0.7)),
                        ),
                        child: const Row(children: [
                          Icon(Icons.location_off_outlined,
                              size: 13, color: Color(0xFF856404)),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'No GPS pin — tap Navigate for address-based route',
                              style:
                                  TextStyle(fontSize: 11, color: Color(0xFF856404)),
                            ),
                          ),
                        ]),
                      ),
                    ),

                  // ETA badge
                  if (_distKm != null && _isEnRoute)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 68,
                      left: 12,
                      child: AnimatedOpacity(
                        opacity: _isEnRoute ? 1 : 0.5,
                        duration: const Duration(milliseconds: 300),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.12),
                                  blurRadius: 10)
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _etaText,
                                    style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.textPrimary,
                                        height: 1.1),
                                  ),
                                  const Text('min ETA',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textHint)),
                                ],
                              ),
                              Container(
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                width: 1,
                                height: 28,
                                color: AppColors.divider,
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _distText,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.brandGreen,
                                        height: 1.1),
                                  ),
                                  const Text('away',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.textHint)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),

                  // Speed chip
                  if (_speedKmh != null && _isEnRoute)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 68,
                      right: 12,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1565C0),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                                color: const Color(0xFF1565C0).withValues(alpha: 0.3),
                                blurRadius: 8)
                          ],
                        ),
                        child: Text(
                          '${_speedKmh!.toStringAsFixed(0)} km/h',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),

                  // FABs
                  Positioned(
                    bottom: 230,
                    right: 14,
                    child: Column(
                      children: [
                        _fab(
                          icon: Icons.my_location_rounded,
                          active: _followMode,
                          onTap: _reCenter,
                        ),
                        const SizedBox(height: 10),
                        _fab(
                          icon: Icons.navigation_rounded,
                          color: AppColors.brandGreen,
                          onTap: (widget.patientLat != null || widget.patientAddress.isNotEmpty)
                              ? _openInMaps
                              : null,
                        ),
                      ],
                    ),
                  ),

                  // Completed banner
                  if (_status == _JobStatus.handedOver)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black38,
                        child: Center(
                          child: Container(
                            margin: const EdgeInsets.all(24),
                            padding: const EdgeInsets.all(28),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 20)
                              ],
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: const BoxDecoration(
                                      color: AppColors.brandGreenSurface,
                                      shape: BoxShape.circle),
                                  child: const Icon(Icons.check_circle_rounded,
                                      color: AppColors.brandGreen, size: 40),
                                ),
                                const SizedBox(height: 16),
                                const Text('Sample Handed to Lab!',
                                    style: TextStyle(
                                        fontSize: 20, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 6),
                                const Text('All done for this booking.',
                                    style: TextStyle(
                                        color: AppColors.textSecondary,
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Bottom card
                  if (_status != _JobStatus.handedOver)
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
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Handle
                            Center(
                              child: Container(
                                width: 40,
                                height: 4,
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                    color: AppColors.divider,
                                    borderRadius: BorderRadius.circular(2)),
                              ),
                            ),

                            // Patient row
                            Row(
                              children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: const BoxDecoration(
                                    color: _navy,
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    _initial,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
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
                                        widget.patientName,
                                        style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.textPrimary),
                                      ),
                                      if (widget.patientMobile.isNotEmpty)
                                        Text(
                                          widget.patientMobile,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppColors.textSecondary),
                                        ),
                                    ],
                                  ),
                                ),
                                if (_isEnRoute)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFDCFCE7),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _PulsingDot(),
                                        SizedBox(width: 5),
                                        Text('En route',
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF166534),
                                                fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                  )
                                else if (_isArrived)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: AppColors.brandGreenSurface,
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: const Text('Arrived',
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.brandGreen)),
                                  ),
                              ],
                            ),

                            // Journey progress bar
                            if (_isEnRoute && _initialDistKm != null) ...[
                              const SizedBox(height: 14),
                              const Row(
                                children: [
                                  Text('Me',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: AppColors.textHint,
                                          fontWeight: FontWeight.w500)),
                                  Spacer(),
                                  Text('Patient',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: AppColors.textHint,
                                          fontWeight: FontWeight.w500)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _journeyProgress,
                                  minHeight: 6,
                                  backgroundColor: AppColors.divider,
                                  valueColor: const AlwaysStoppedAnimation<Color>(
                                      AppColors.brandGreen),
                                ),
                              ),
                            ],

                            const SizedBox(height: 14),

                            // Collection location card
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: AppColors.background,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: AppColors.divider),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: AppColors.brandGreenSurface,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(Icons.home_rounded,
                                        color: AppColors.brandGreen, size: 16),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('COLLECTION',
                                            style: TextStyle(
                                                fontSize: 9,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.textHint,
                                                letterSpacing: 0.5)),
                                        Text(
                                          widget.patientAddress,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: AppColors.textPrimary),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 14),

                            // Navigate + action buttons
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _openInMaps,
                                    icon: const Icon(Icons.navigation_rounded,
                                        size: 16),
                                    label: const Text('Navigate'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _navy,
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding:
                                          const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                      textStyle: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: _actionOnPress(),
                                    icon: Icon(_actionIcon(), size: 16),
                                    label: Text(_actionLabel()),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _actionColor(),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      padding:
                                          const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12)),
                                      textStyle: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700),
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
              ),
      ),
    );
  }

  Widget _buildPermissionError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.location_off,
              size: 80,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 24),
            const Text(
              'Location Access Required',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Please enable location permissions in settings to track your journey.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                openAppSettings();
              },
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
              },
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }

  // ── FAB helper ───────────────────────────────────────────────────────────────

  Widget _fab({
    required IconData icon,
    bool active = false,
    Color? color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: active ? _navy : Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.13), blurRadius: 8)
          ],
        ),
        child: Icon(icon,
            size: 20,
            color: active ? Colors.white : (color ?? AppColors.textPrimary)),
      ),
    );
  }

  // ── Action button helpers ────────────────────────────────────────────────────

  VoidCallback? _actionOnPress() {
    switch (_status) {
      case _JobStatus.assigned:
        return _setEnRoute;
      case _JobStatus.enRoute:
        return _setArrived;
      case _JobStatus.arrived:
        return _startCollection;
      case _JobStatus.handedOver:
        return null;
    }
  }

  String _actionLabel() {
    switch (_status) {
      case _JobStatus.assigned:
        return 'Start Journey';
      case _JobStatus.enRoute:
        return 'Mark Arrived';
      case _JobStatus.arrived:
        return 'Start Collection';
      case _JobStatus.handedOver:
        return 'Done';
    }
  }

  IconData _actionIcon() {
    switch (_status) {
      case _JobStatus.assigned:
        return Icons.directions_bike_rounded;
      case _JobStatus.enRoute:
        return Icons.location_on_rounded;
      case _JobStatus.arrived:
        return Icons.science_rounded;
      case _JobStatus.handedOver:
        return Icons.check_circle_outline;
    }
  }

  Color _actionColor() {
    switch (_status) {
      case _JobStatus.assigned:
        return AppColors.brandGreen;
      case _JobStatus.enRoute:
        return const Color(0xFFF57C00);
      case _JobStatus.arrived:
        return AppColors.brandGreen;
      case _JobStatus.handedOver:
        return AppColors.brandGreen;
    }
  }
}

// ── Animated pulsing green dot ────────────────────────────────────────────────

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.4, end: 1.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _anim,
        child: Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
              color: Color(0xFF16A34A), shape: BoxShape.circle),
        ),
      );
}