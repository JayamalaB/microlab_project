import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';

enum _JobStatus { assigned, enRoute, arrived, completed }

class TechnicianActiveJobScreen extends StatefulWidget {
  final int bookingId;
  final String patientName;
  final String patientMobile;
  final String patientAddress;
  final double? patientLat;
  final double? patientLng;
  final String hospital;

  const TechnicianActiveJobScreen({
    super.key,
    required this.bookingId,
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    this.patientLat,
    this.patientLng,
    required this.hospital,
  });

  @override
  State<TechnicianActiveJobScreen> createState() =>
      _TechnicianActiveJobScreenState();
}

class _TechnicianActiveJobScreenState extends State<TechnicianActiveJobScreen> {
  _JobStatus _status = _JobStatus.assigned;

  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  final List<LatLng> _myTrail = [];

  Timer? _locationTimer;
  Timer? _idleTimer;
  Position? _myPosition;
  StreamSubscription<Position>? _posSub;

  final String _trackingId = '';

  @override
  void initState() {
    super.initState();
    _requestLocationAndStart();
    if (widget.patientLat != null) {
      _markers.add(Marker(
        markerId: const MarkerId('patient'),
        position: LatLng(widget.patientLat!, widget.patientLng!),
        infoWindow: InfoWindow(title: widget.patientName),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
    }
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    _idleTimer?.cancel();
    _posSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _requestLocationAndStart() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) return;

    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen(_onNewPosition);
  }

  void _onNewPosition(Position pos) {
    if (!mounted) return;
    setState(() {
      _myPosition = pos;
      _myTrail.add(LatLng(pos.latitude, pos.longitude));
      _markers.removeWhere((m) => m.markerId.value == 'me');
      _markers.add(Marker(
        markerId: const MarkerId('me'),
        position: LatLng(pos.latitude, pos.longitude),
        infoWindow: const InfoWindow(title: 'You'),
        icon:
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        rotation: pos.heading,
        flat: true,
      ));
    });

    _mapController?.animateCamera(
      CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
    );

    // Ping during active job (en_route or arrived)
    if (_status == _JobStatus.enRoute || _status == _JobStatus.arrived) {
      SocketService.instance.emitLocation(
        trackingId: widget.bookingId.toString(),
        bookingId:  widget.bookingId,
        lat:        pos.latitude,
        lng:        pos.longitude,
        accuracy:   pos.accuracy,
        speed:      pos.speed,
        bearing:    pos.heading,
      );
    } else {
      // Idle ping
      SocketService.instance.emitIdleLocation(
        lat: pos.latitude,
        lng: pos.longitude,
      );
    }
  }

  void _setEnRoute() {
    setState(() => _status = _JobStatus.enRoute);
    SocketService.instance.emitEnRoute(bookingId: widget.bookingId);
    HapticFeedback.mediumImpact();
  }

  void _setArrived() {
    setState(() => _status = _JobStatus.arrived);
    SocketService.instance.emitArrived(bookingId: widget.bookingId);
    HapticFeedback.mediumImpact();
  }

  void _completeJob() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Complete Collection?',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: Text(
          'Confirm sample collected from ${widget.patientName}.',
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
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
              SocketService.instance
                  .emitCollectionCompleted(bookingId: widget.bookingId);
              setState(() => _status = _JobStatus.completed);
              HapticFeedback.heavyImpact();
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) Navigator.of(context).pop();
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandGreen,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _callPatient() {
    if (widget.patientMobile.isEmpty) return;
    launchUrl(Uri.parse('tel:+91${widget.patientMobile}'));
  }

  void _openInMaps() {
    if (widget.patientLat == null) return;
    launchUrl(
      Uri.parse(
          'https://maps.google.com/?q=${widget.patientLat},${widget.patientLng}&z=17'),
      mode: LaunchMode.externalApplication,
    );
  }

  LatLng get _initialCamera => widget.patientLat != null
      ? LatLng(widget.patientLat!, widget.patientLng!)
      : const LatLng(13.0827, 80.2707);

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        body: Stack(
          children: [
            // ── Map ──────────────────────────────────────────────────────
            GoogleMap(
              initialCameraPosition:
                  CameraPosition(target: _initialCamera, zoom: 14),
              markers: _markers,
              polylines: _myTrail.length >= 2
                  ? {
                      Polyline(
                        polylineId: const PolylineId('trail'),
                        points: List<LatLng>.from(_myTrail),
                        color: AppColors.brandGreen.withValues(alpha: 0.6),
                        width: 4,
                        patterns: [PatternItem.dot, PatternItem.gap(8)],
                      ),
                    }
                  : {},
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              onMapCreated: (c) => _mapController = c,
            ),

            // ── Top bar ──────────────────────────────────────────────────
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _TopButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      onTap: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    _TopButton(
                      icon: Icons.phone_rounded,
                      onTap: _callPatient,
                    ),
                    const SizedBox(width: 8),
                    _TopButton(
                      icon: Icons.map_outlined,
                      onTap: _openInMaps,
                    ),
                  ],
                ),
              ),
            ),

            // ── Completed banner ─────────────────────────────────────────
            if (_status == _JobStatus.completed)
              Center(
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                            color: AppColors.brandGreenSurface,
                            shape: BoxShape.circle),
                        child: const Icon(Icons.check_circle_rounded,
                            color: AppColors.brandGreen, size: 36),
                      ),
                      const SizedBox(height: 16),
                      const Text('Collection Complete!',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      const Text('Returning to dashboard…',
                          style: TextStyle(
                              color: AppColors.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
              ),

            // ── Bottom job card ───────────────────────────────────────────
            if (_status != _JobStatus.completed)
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
                      const SizedBox(height: 16),

                      // Status pill
                      _StatusPill(status: _status),
                      const SizedBox(height: 12),

                      // Patient name
                      Text(
                        widget.patientName,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.home_outlined,
                              size: 13, color: AppColors.textHint),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              widget.patientAddress,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Action button
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _actionOnPress(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _actionColor(),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(_actionIcon(), size: 18),
                              const SizedBox(width: 8),
                              Text(_actionLabel(),
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ],
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

  VoidCallback? _actionOnPress() {
    switch (_status) {
      case _JobStatus.assigned: return _setEnRoute;
      case _JobStatus.enRoute:  return _setArrived;
      case _JobStatus.arrived:  return _completeJob;
      case _JobStatus.completed: return null;
    }
  }

  String _actionLabel() {
    switch (_status) {
      case _JobStatus.assigned:  return 'Start Journey';
      case _JobStatus.enRoute:   return 'Mark Arrived';
      case _JobStatus.arrived:   return 'Complete Collection';
      case _JobStatus.completed: return 'Done';
    }
  }

  IconData _actionIcon() {
    switch (_status) {
      case _JobStatus.assigned:  return Icons.directions_bike_rounded;
      case _JobStatus.enRoute:   return Icons.location_on_rounded;
      case _JobStatus.arrived:   return Icons.science_outlined;
      case _JobStatus.completed: return Icons.check_circle_outline;
    }
  }

  Color _actionColor() {
    switch (_status) {
      case _JobStatus.assigned:  return AppColors.blue;
      case _JobStatus.enRoute:   return const Color(0xFF6A1B9A);
      case _JobStatus.arrived:   return AppColors.brandGreen;
      case _JobStatus.completed: return AppColors.brandGreen;
    }
  }
}

class _StatusPill extends StatelessWidget {
  final _JobStatus status;
  const _StatusPill({required this.status});

  String get _label {
    switch (status) {
      case _JobStatus.assigned:  return 'Assigned — Head to patient';
      case _JobStatus.enRoute:   return 'En Route';
      case _JobStatus.arrived:   return 'Arrived — Ready to collect';
      case _JobStatus.completed: return 'Completed';
    }
  }

  Color get _color {
    switch (status) {
      case _JobStatus.assigned:  return AppColors.blue;
      case _JobStatus.enRoute:   return const Color(0xFF6A1B9A);
      case _JobStatus.arrived:   return AppColors.brandGreen;
      case _JobStatus.completed: return AppColors.brandGreen;
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _color.withValues(alpha: 0.3)),
        ),
        child: Text(_label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _color)),
      );
}

class _TopButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _TopButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8)
            ],
          ),
          child: Icon(icon, size: 18, color: AppColors.textPrimary),
        ),
      );
}
