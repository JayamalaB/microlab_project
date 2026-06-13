import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';

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
  final List<LatLng> _trail = [];
  final Set<Marker> _markers = {};

  bool _arrived = false;
  bool _completed = false;

  StreamSubscription<LocationUpdate>? _locationSub;
  StreamSubscription<int>? _arrivedSub;
  StreamSubscription<int>? _completedSub;

  @override
  void initState() {
    super.initState();

    // Join tracking room — server will replay last known location immediately
    SocketService.instance.joinTracking(widget.trackingId);

    _locationSub =
        SocketService.instance.onLocationUpdate.listen((update) {
      if (update.trackingId != widget.trackingId) return;
      _onLocationUpdate(update);
    });

    _arrivedSub =
        SocketService.instance.onTechnicianArrived.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      setState(() => _arrived = true);
      HapticFeedback.mediumImpact();
    });

    _completedSub =
        SocketService.instance.onCollectionCompleted.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      setState(() => _completed = true);
      HapticFeedback.heavyImpact();
    });

    // Patient location marker
    if (widget.patientLat != null) {
      _markers.add(Marker(
        markerId: const MarkerId('patient'),
        position: LatLng(widget.patientLat!, widget.patientLng!),
        infoWindow: const InfoWindow(title: 'Your Location'),
        icon:
            BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
    }
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    _arrivedSub?.cancel();
    _completedSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  void _onLocationUpdate(LocationUpdate update) {
    if (!mounted) return;
    final pos = LatLng(update.lat, update.lng);
    setState(() {
      _techLocation = pos;
      _trail.add(pos);

      _markers.removeWhere((m) => m.markerId.value == 'tech');
      _markers.add(Marker(
        markerId: const MarkerId('tech'),
        position: pos,
        infoWindow: InfoWindow(title: widget.technicianName),
        icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen),
        rotation: update.bearing ?? 0,
        flat: true,
      ));
    });

    _mapController?.animateCamera(
      CameraUpdate.newLatLng(pos),
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
              polylines: _trail.length >= 2
                  ? {
                      Polyline(
                        polylineId: const PolylineId('trail'),
                        points: List<LatLng>.from(_trail),
                        color: const Color(0xFF4A90D9).withValues(alpha: 0.55),
                        width: 3,
                        patterns: [PatternItem.dot, PatternItem.gap(10)],
                        geodesic: true,
                        jointType: JointType.round,
                      ),
                    }
                  : {},
              myLocationEnabled: false,
              onMapCreated: (c) => _mapController = c,
            ),

            // ── Top bar ──────────────────────────────────────────────────
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
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
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
                            decoration: const BoxDecoration(
                              color: AppColors.brandGreen,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text('Live Tracking',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Arrived banner ───────────────────────────────────────────
            if (_arrived && !_completed)
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
                  child: Row(
                    children: [
                      const Icon(Icons.location_on_rounded,
                          color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('Technician has arrived!',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                      ),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Completed overlay ────────────────────────────────────────
            if (_completed)
              Positioned.fill(
                child: Container(
                  color: Colors.black54,
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.all(24),
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
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
                          const SizedBox(height: 20),
                          const Text('Collection Complete!',
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary)),
                          const SizedBox(height: 8),
                          const Text(
                            'Your samples have been collected.\nResults will be ready soon.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 14,
                                color: AppColors.textSecondary,
                                height: 1.5),
                          ),
                          const SizedBox(height: 28),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () => Navigator.of(context)
                                  .popUntil((r) => r.isFirst),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(14)),
                              ),
                              child: const Text('Back to Home',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // ── Bottom info card ─────────────────────────────────────────
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
                          // Technician avatar
                          Container(
                            width: 44,
                            height: 44,
                            decoration: const BoxDecoration(
                              color: AppColors.brandGreenSurface,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.person_rounded,
                                color: AppColors.brandGreen, size: 24),
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
                                      : _techLocation != null
                                          ? 'On the way to you'
                                          : 'Locating technician…',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _arrived
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

                          // Live badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.brandGreenSurface,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: const BoxDecoration(
                                    color: AppColors.brandGreen,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Text('Live',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.brandGreen,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),
                      const Divider(height: 1),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          const Icon(Icons.home_outlined,
                              size: 13, color: AppColors.textHint),
                          const SizedBox(width: 6),
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
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleButton({required this.icon, required this.onTap});

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
          child: Icon(icon, size: 16, color: AppColors.textPrimary),
        ),
      );
}
