import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';

enum TripState {
  enrouteToPickup,
  arrived,
  enrouteToDestination,
  completed
}

class PatientRideTrackingScreen extends StatefulWidget {
  final String bookingId;
  final int patientId;
  final String patientName;
  final String trackingId;
  final int driverId;
  final String driverName;
  final double? patientLat;
  final double? patientLng;
  final String patientAddress;
  final String hospital;
  final double? hospitalLat;
  final double? hospitalLng;

  const PatientRideTrackingScreen({
    super.key,
    required this.bookingId,
    required this.patientId,
    required this.patientName,
    required this.trackingId,
    required this.driverId,
    required this.driverName,
    required this.patientLat,
    required this.patientLng,
    required this.patientAddress,
    required this.hospital,
    this.hospitalLat,
    this.hospitalLng,
  });

  @override
  State<PatientRideTrackingScreen> createState() =>
      _PatientRideTrackingScreenState();
}

class _PatientRideTrackingScreenState
    extends State<PatientRideTrackingScreen> {
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};

  LatLng? _driverPos;
  bool _arrived = false;
  bool _completed = false;
  bool _followDriver = true;
  bool _programmaticMove = false;
  bool _hasFirstUpdate = false;
  bool _locationPermissionGranted = false;
  TripState _tripState = TripState.enrouteToPickup;

  double? _initialDistKm;
  double? _distKm;
  int? _etaMinutes;
  DateTime? _etaTime;

  LatLng? _lastRouteFetchPos;
  Timer? _animationTimer;
  Timer? _etaUpdateTimer;

  BitmapDescriptor? _taxiIcon;
  BitmapDescriptor? _pinIcon;
  BitmapDescriptor? _hospitalIcon;

  StreamSubscription<LocationUpdate>? _locationSub;
  StreamSubscription<int>? _arrivedSub;
  StreamSubscription<int>? _completedSub;
  StreamSubscription<bool>? _connectedSub;

  LatLng get _patientLatLng => widget.patientLat != null
      ? LatLng(widget.patientLat!, widget.patientLng!)
      : const LatLng(13.0827, 80.2707);

  LatLng get _destinationLatLng => _tripState == TripState.enrouteToDestination
      ? (widget.hospitalLat != null && widget.hospitalLng != null
          ? LatLng(widget.hospitalLat!, widget.hospitalLng!)
          : _patientLatLng)
      : _patientLatLng;

  String get _driverInitial =>
      widget.driverName.isNotEmpty ? widget.driverName[0].toUpperCase() : 'D';

  String get _etaText {
    if (_distKm == null || _etaMinutes == null) return '—';
    if (_distKm! < 0.05) return '< 1';
    return _etaMinutes! <= 1 ? '< 1' : '$_etaMinutes';
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

  String get _etaTimeString {
    if (_etaTime == null) return '';
    final now = DateTime.now();
    final diff = _etaTime!.difference(now);
    if (diff.inMinutes <= 0) return 'Arriving soon';
    return 'Arriving at ${_formatTime(_etaTime!)}';
  }

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _buildMarkerIcons();
    _setupSocket();
    _startEtaUpdateTimer();
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _arrivedSub?.cancel();
    _completedSub?.cancel();
    _connectedSub?.cancel();
    _animationTimer?.cancel();
    _etaUpdateTimer?.cancel();
    
    if (widget.trackingId.isNotEmpty) {
      SocketService.instance.clearActiveRide();
    }
    
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _checkPermissions() async {
    final status = await Permission.location.status;
    if (status.isGranted) {
      setState(() => _locationPermissionGranted = true);
    } else if (status.isDenied) {
      final result = await Permission.location.request();
      setState(() => _locationPermissionGranted = result.isGranted);
    } else if (status.isPermanentlyDenied) {
      _showPermissionDialog();
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Location Permission Required'),
        content: const Text(
          'Please enable location permission in settings to track your ride.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => openAppSettings(),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  void _startEtaUpdateTimer() {
    _etaUpdateTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted && _etaTime != null) {
        setState(() {});
      }
    });
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _buildMarkerIcons() async {
    _taxiIcon = await _renderIcon(
      icon: Icons.local_taxi_rounded,
      bgColor: const Color(0xFFFFC107),
      iconColor: Colors.white,
      logicalSize: 44,
    );
    _pinIcon = await _renderIcon(
      icon: Icons.person_pin_circle_rounded,
      bgColor: AppColors.brandGreen,
      iconColor: Colors.white,
      logicalSize: 34,
    );
    _hospitalIcon = await _renderIcon(
      icon: Icons.local_hospital_rounded,
      bgColor: const Color(0xFFD32F2F),
      iconColor: Colors.white,
      logicalSize: 34,
    );
    _placePatientMarker();
    _placeHospitalMarker();
  }

  Future<BitmapDescriptor> _renderIcon({
    required IconData icon,
    required Color bgColor,
    required Color iconColor,
    required double logicalSize,
  }) async {
    final px = (logicalSize * 2).toInt();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder, 
      Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble())
    );
    
    canvas.drawCircle(
      Offset(px / 2, px / 2), 
      px / 2 - 2, 
      Paint()..color = bgColor
    );
    canvas.drawCircle(
      Offset(px / 2, px / 2),
      px / 2 - 2,
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
    
    if (data == null) {
      return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueYellow);
    }
    
    // ignore: deprecated_member_use
    return BitmapDescriptor.bytes(data.buffer.asUint8List(), width: logicalSize);
  }

  void _placePatientMarker() {
    if (!mounted) return;
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'patient');
      _markers.add(Marker(
        markerId: const MarkerId('patient'),
        position: _patientLatLng,
        icon: _pinIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        infoWindow: const InfoWindow(title: 'Your Pickup Location'),
        zIndex: 1,
      ));
    });
  }

  void _placeHospitalMarker() {
    if (!mounted || widget.hospitalLat == null || widget.hospitalLng == null) 
      return;
    
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'hospital');
      _markers.add(Marker(
        markerId: const MarkerId('hospital'),
        position: LatLng(widget.hospitalLat!, widget.hospitalLng!),
        icon: _hospitalIcon ??
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        infoWindow: InfoWindow(title: widget.hospital),
        zIndex: 1,
      ));
    });
  }

  void _setupSocket() {
    if (!SocketService.instance.isConnected) {
      SocketService.instance.connect(
        userId: widget.patientId,
        role: 'customer',
        name: widget.patientName,
      );
    }

    _connectedSub = SocketService.instance.onConnected.listen((connected) {
      if (!connected || !mounted) return;
      if (widget.trackingId.isNotEmpty) {
        SocketService.instance.joinTracking(widget.trackingId);
      }
      SocketService.instance.registerPatientSocket(
        patientId: widget.patientId,
        bookingId: _numericId(widget.bookingId),
      );
    });

    if (SocketService.instance.isConnected) {
      if (widget.trackingId.isNotEmpty) {
        SocketService.instance.joinTracking(widget.trackingId);
      }
      SocketService.instance.registerPatientSocket(
        patientId: widget.patientId,
        bookingId: _numericId(widget.bookingId),
      );
    }

    _locationSub = SocketService.instance.onLocationUpdate.listen((update) {
      if (update.trackingId != widget.trackingId || !mounted) return;
      _onLocationUpdate(update);
    });

    _arrivedSub = SocketService.instance.onDriverArrived.listen((id) {
      if (!mounted || id != _numericId(widget.bookingId)) return;
      _onDriverArrived();
    });

    _completedSub = SocketService.instance.onTripCompleted.listen((id) {
      if (!mounted || id != _numericId(widget.bookingId)) return;
      _onTripCompleted();
    });
  }

  int _numericId(String id) =>
      int.tryParse(id.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  void _onDriverArrived() {
    setState(() {
      _arrived = true;
      _tripState = TripState.arrived;
    });
    
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 300), HapticFeedback.heavyImpact);
    Future.delayed(const Duration(milliseconds: 600), HapticFeedback.heavyImpact);
    
    _showArrivalNotification();
  }

  void _showArrivalNotification() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.notifications_active, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${widget.driverName} has arrived at your location!',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        backgroundColor: AppColors.brandGreen,
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onTripCompleted() {
    SocketService.instance.clearActiveRide();
    setState(() {
      _completed = true;
      _tripState = TripState.completed;
    });
    HapticFeedback.heavyImpact();
    
    _showCompletionDialog();
  }

  void _showCompletionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Column(
          children: [
            Icon(Icons.check_circle, color: AppColors.brandGreen, size: 60),
            SizedBox(height: 16),
            Text('Trip Completed!'),
          ],
        ),
        content: Text(
          'You have been dropped at ${widget.hospital}.\nThank you for riding with us!',
          textAlign: TextAlign.center,
          style: const TextStyle(height: 1.5),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Back to Home'),
          ),
        ],
      ),
    );
  }

  // Simulate trip start after pickup (in a real app, this would come from socket)
  void _startTripToHospital() {
    if (_tripState == TripState.arrived) {
      setState(() {
        _tripState = TripState.enrouteToDestination;
        _arrived = false;
        _distKm = null;
        _etaMinutes = null;
        _initialDistKm = null;
        _lastRouteFetchPos = null;
      });
      
      // Fetch route from current driver position to hospital
      if (_driverPos != null && _destinationLatLng != _patientLatLng) {
        _fetchRoute(_driverPos!, _destinationLatLng);
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Trip started! Heading to hospital.'),
          backgroundColor: Colors.blue,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _onLocationUpdate(LocationUpdate update) {
    if (!mounted) return;
    
    final newPos = LatLng(update.lat, update.lng);
    final from = _driverPos ?? newPos;

    if (!_hasFirstUpdate) setState(() => _hasFirstUpdate = true);

    if (_tripState == TripState.enrouteToPickup) {
      final d = _haversineKm(newPos, _patientLatLng);
      _initialDistKm ??= d;
      final speedKmh = (update.speed != null && update.speed! > 0.5)
          ? update.speed! * 3.6
          : 40.0;
      final eta = ((d / speedKmh) * 60).ceil().clamp(1, 999);
      
      setState(() {
        _distKm = d;
        _etaMinutes = eta;
        _etaTime = DateTime.now().add(Duration(minutes: eta));
      });
      
      // If driver is very close to patient, suggest starting trip
      if (d < 0.05 && _tripState == TripState.enrouteToPickup) {
        _showStartTripButton();
      }
    } else if (_tripState == TripState.enrouteToDestination) {
      final d = _haversineKm(newPos, _destinationLatLng);
      final speedKmh = (update.speed != null && update.speed! > 0.5)
          ? update.speed! * 3.6
          : 40.0;
      final eta = ((d / speedKmh) * 60).ceil().clamp(1, 999);
      
      setState(() {
        _distKm = d;
        _etaMinutes = eta;
        _etaTime = DateTime.now().add(Duration(minutes: eta));
      });
    }

    // Fetch route if driver has moved significantly (30 meters)
    if (_lastRouteFetchPos == null ||
        _haversineKm(newPos, _lastRouteFetchPos!) * 1000 > 30) {
      _fetchRoute(newPos, _destinationLatLng);
      _lastRouteFetchPos = newPos;
    }

    _animateDriverMarker(from, newPos, update.bearing ?? 0);
  }

  void _showStartTripButton() {
    if (_tripState != TripState.enrouteToPickup) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Driver has arrived! Ready to start the trip?'),
        action: SnackBarAction(
          label: 'Start Trip',
          onPressed: _startTripToHospital,
          textColor: Colors.white,
        ),
        backgroundColor: AppColors.brandGreen,
        duration: const Duration(seconds: 10),
      ),
    );
  }

  void _animateDriverMarker(LatLng from, LatLng to, double bearing) {
    _animationTimer?.cancel();
    
    const steps = 30;
    const stepDelay = Duration(milliseconds: 48);
    
    for (int i = 1; i <= steps; i++) {
      _animationTimer = Timer(stepDelay * i, () {
        if (!mounted) return;
        
        final t = i / steps;
        final pos = LatLng(
          from.latitude + (to.latitude - from.latitude) * t,
          from.longitude + (to.longitude - from.longitude) * t,
        );
        
        setState(() {
          _driverPos = pos;
          _markers.removeWhere((m) => m.markerId.value == 'driver');
          _markers.add(Marker(
            markerId: const MarkerId('driver'),
            position: pos,
            icon: _taxiIcon ??
                BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueYellow),
            infoWindow: InfoWindow(title: widget.driverName),
            rotation: bearing,
            flat: true,
            zIndex: 2,
          ));
        });
        
        if (i == steps && _followDriver && 
            _tripState != TripState.completed && 
            _tripState != TripState.arrived) {
          _programmaticMove = true;
          _mapController?.animateCamera(CameraUpdate.newLatLng(pos));
        }
      });
    }
  }

  Future<void> _fetchRoute(LatLng origin, LatLng dest) async {
    try {
      final apiKey = AppConstants.googleMapsApiKey;
      if (apiKey.isEmpty) {
        debugPrint('Google Maps API key is missing');
        return;
      }
      
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${dest.latitude},${dest.longitude}'
        '&mode=driving'
        '&key=$apiKey',
      );
      
      final res = await http.get(url).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200 || !mounted) return;
      
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = json['routes'] as List?;
      if (routes == null || routes.isEmpty) return;
      
      final encoded = (routes[0]['overview_polyline'] as Map<String, dynamic>)['points'] as String;
      final points = _decodePolyline(encoded);
      
      if (!mounted) return;
      
      final routeColor = _tripState == TripState.enrouteToDestination
          ? const Color(0xFF1A2340)
          : const Color(0xFF1565C0);
      
      setState(() {
        _polylines
          ..removeWhere((p) => p.polylineId.value == 'route')
          ..add(Polyline(
            polylineId: const PolylineId('route'),
            points: points,
            color: routeColor,
            width: 5,
            geodesic: true,
            jointType: JointType.round,
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
      
      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;
      
      shift = 0;
      result = 0;
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
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final aa = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return R * 2 * math.atan2(math.sqrt(aa.toDouble()), math.sqrt(1 - aa.toDouble()));
  }

  Future<void> _navigateToDestination() async {
    final destination = _tripState == TripState.enrouteToDestination
        ? widget.hospital
        : widget.patientAddress;
    
    final query = Uri.encodeComponent(destination);
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$query');
    
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _shareTripStatus() {
    final status = _tripState == TripState.enrouteToPickup
        ? 'Driver is on the way to pickup'
        : _tripState == TripState.enrouteToDestination
        ? 'On the way to hospital'
        : _tripState == TripState.arrived
        ? 'Driver has arrived'
        : 'Trip completed';
    
    final shareText = '''
🚗 Ride Status Update:
Booking ID: ${widget.bookingId}
Status: $status
Driver: ${widget.driverName}
Destination: ${widget.hospital}
''';
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Trip info copied to clipboard: $status'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        body: Stack(
          children: [
            // Full-screen map
            GoogleMap(
              initialCameraPosition:
                  CameraPosition(target: _patientLatLng, zoom: 14),
              markers: _markers,
              polylines: _polylines,
              myLocationEnabled: _locationPermissionGranted,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              onMapCreated: (c) => _mapController = c,
              onCameraMove: (_) {
                if (_programmaticMove) {
                  _programmaticMove = false;
                  return;
                }
                if (_followDriver) setState(() => _followDriver = false);
              },
            ),

            // Connection status indicator
            if (!SocketService.instance.isConnected)
              Positioned(
                top: MediaQuery.of(context).padding.top + 60,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade600,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Reconnecting to tracking service...',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Top status overlay
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
                        onTap: () => Navigator.of(context).pop(),
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
                                  color: _arrived || _tripState == TripState.enrouteToDestination
                                      ? AppColors.brandGreen
                                      : const Color(0xFFF57C00),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _getStatusText(),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _arrived || _tripState == TripState.enrouteToDestination
                                      ? AppColors.brandGreen
                                      : const Color(0xFFF57C00),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _shareTripStatus,
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
                          child: const Icon(Icons.share_rounded,
                              size: 20, color: AppColors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ETA / distance chips
            if (_hasFirstUpdate && _distKm != null && !_arrived && _tripState != TripState.completed)
              Positioned(
                top: MediaQuery.of(context).padding.top + 68,
                left: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MapChip(
                      mainText: _etaText,
                      unit: 'min',
                      label: _etaTimeString.isNotEmpty ? _etaTimeString : 'ETA',
                      mainColor: AppColors.textPrimary,
                    ),
                    const SizedBox(height: 6),
                    _MapChip(
                      mainText: _distText,
                      unit: _distUnit,
                      label: _tripState == TripState.enrouteToDestination ? 'to hospital' : 'away',
                      mainColor: AppColors.brandGreen,
                    ),
                  ],
                ),
              ),

            // Start trip button (when driver has arrived)
            if (_tripState == TripState.arrived && !_completed)
              Positioned(
                bottom: 200,
                left: 20,
                right: 20,
                child: ElevatedButton.icon(
                  onPressed: _startTripToHospital,
                  icon: const Icon(Icons.play_arrow_rounded, size: 24),
                  label: const Text(
                    'Start Trip to Hospital',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 4,
                  ),
                ),
              ),

            // Re-center button
            if (!_completed && !_followDriver && _driverPos != null && _tripState != TripState.arrived)
              Positioned(
                right: 16,
                bottom: 280,
                child: GestureDetector(
                  onTap: () {
                    setState(() => _followDriver = true);
                    _programmaticMove = true;
                    _mapController
                        ?.animateCamera(CameraUpdate.newLatLng(_driverPos!));
                  },
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2))
                      ],
                    ),
                    child: const Icon(Icons.my_location_rounded,
                        size: 22, color: Color(0xFF1565C0)),
                  ),
                ),
              ),

            // Bottom info card
            if (!_completed)
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
                          decoration: BoxDecoration(
                              color: AppColors.divider,
                              borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Driver row
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
                                _driverInitial,
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
                                  widget.driverName,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.textPrimary),
                                ),
                                Text(
                                  _getDriverStatusText(),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _arrived || _tripState == TripState.enrouteToDestination
                                        ? AppColors.brandGreen
                                        : AppColors.textSecondary,
                                    fontWeight: _arrived
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: _arrived
                                  ? AppColors.brandGreenSurface
                                  : _tripState == TripState.enrouteToDestination
                                  ? AppColors.brandGreenSurface
                                  : const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              _getStatusBadgeText(),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: _arrived || _tripState == TripState.enrouteToDestination
                                    ? AppColors.brandGreen
                                    : const Color(0xFFF57C00),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      // Destination card
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
                                color: _tripState == TripState.enrouteToDestination
                                    ? const Color(0xFFFFEBEE)
                                    : const Color(0xFFE8F5E9),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                _tripState == TripState.enrouteToDestination
                                    ? Icons.local_hospital_rounded
                                    : Icons.home_rounded,
                                color: _tripState == TripState.enrouteToDestination
                                    ? const Color(0xFFD32F2F)
                                    : AppColors.brandGreen,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _tripState == TripState.enrouteToDestination
                                    ? widget.hospital
                                    : widget.patientAddress,
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              _tripState == TripState.enrouteToDestination
                                  ? 'Destination'
                                  : 'Pickup',
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.textHint),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Navigate button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _navigateToDestination,
                          icon: const Icon(Icons.navigation_rounded, size: 16),
                          label: Text(
                            _tripState == TripState.enrouteToDestination
                                ? 'Navigate to Hospital'
                                : 'Navigate to Pickup',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A2340),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            textStyle: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                          ),
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

  String _getStatusText() {
    if (_arrived) return 'Driver has arrived!';
    if (_tripState == TripState.enrouteToDestination) return 'On the way to hospital';
    if (_tripState == TripState.enrouteToPickup) return 'Driver en route to you';
    return 'Loading...';
  }

  String _getDriverStatusText() {
    if (_arrived) return 'Arrived at your location';
    if (_tripState == TripState.enrouteToDestination) return 'Heading to hospital';
    if (_hasFirstUpdate) return 'On the way to you';
    return 'Locating driver…';
  }

  String _getStatusBadgeText() {
    if (_arrived) return 'Arrived';
    if (_tripState == TripState.enrouteToDestination) return 'En route';
    return 'En route';
  }
}

// Map chip widget
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