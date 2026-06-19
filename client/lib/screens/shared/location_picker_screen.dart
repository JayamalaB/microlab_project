import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:microlab/theme/app_theme.dart';

class PickedLocation {
  final double lat;
  final double lng;
  const PickedLocation(this.lat, this.lng);
}

class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  GoogleMapController? _mapController;
  LatLng? _picked;
  bool _loading = true;

  static const LatLng _defaultChennai = LatLng(13.0827, 80.2707);

  @override
  void initState() {
    super.initState();
    _fetchGPS();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _fetchGPS() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        debugPrint('[LocationPicker] Permission denied forever, using default');
        setState(() { _picked = _defaultChennai; _loading = false; });
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      debugPrint('[LocationPicker] GPS fetched: ${pos.latitude}, ${pos.longitude}');
      if (!mounted) return;
      setState(() {
        _picked = LatLng(pos.latitude, pos.longitude);
        _loading = false;
      });
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(_picked!, 16),
      );
    } catch (e) {
      debugPrint('[LocationPicker] GPS error: $e');
      if (mounted) setState(() { _picked = _defaultChennai; _loading = false; });
    }
  }

  void _onMapTap(LatLng pos) {
    debugPrint('[LocationPicker] Tapped: ${pos.latitude}, ${pos.longitude}');
    setState(() => _picked = pos);
  }

  void _onMarkerDragEnd(LatLng pos) {
    debugPrint('[LocationPicker] Pin dragged to: ${pos.latitude}, ${pos.longitude}');
    setState(() => _picked = pos);
  }

  void _confirm() {
    if (_picked == null) return;
    debugPrint('[LocationPicker] CONFIRMED: ${_picked!.latitude}, ${_picked!.longitude}');
    Navigator.pop(context, PickedLocation(_picked!.latitude, _picked!.longitude));
  }

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      body: Stack(
        children: [
          // ── Map ────────────────────────────────────────────────────────
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _picked ?? _defaultChennai,
              zoom: 16,
            ),
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            markers: _picked != null
                ? {
                    Marker(
                      markerId: const MarkerId('picked'),
                      position: _picked!,
                      draggable: true,
                      onDragEnd: _onMarkerDragEnd,
                      icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueGreen),
                    ),
                  }
                : {},
            onMapCreated: (c) {
              _mapController = c;
              if (_picked != null) {
                c.animateCamera(CameraUpdate.newLatLngZoom(_picked!, 16));
              }
            },
            onTap: _onMapTap,
          ),

          // ── Loading overlay ────────────────────────────────────────────
          if (_loading)
            Container(
              color: Colors.black26,
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.brandGreen),
              ),
            ),

          // ── Top bar ────────────────────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _CircleBtn(
                    icon: Icons.arrow_back_ios_new_rounded,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(color: Colors.black12, blurRadius: 8)
                        ],
                      ),
                      child: const Text(
                        'Tap map or drag pin to adjust location',
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── My-location re-center button ───────────────────────────────
          Positioned(
            right: 16,
            bottom: 150,
            child: _CircleBtn(
              icon: Icons.my_location_rounded,
              onTap: _fetchGPS,
            ),
          ),

          // ── Bottom confirm card ────────────────────────────────────────
          if (!_loading)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(20)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 12,
                        offset: Offset(0, -2))
                  ],
                ),
                padding: EdgeInsets.fromLTRB(
                    20, 16, 20, safeBottom + 16),
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
                    const SizedBox(height: 14),

                    // Coords row
                    if (_picked != null)
                      Row(
                        children: [
                          const Icon(Icons.location_on_rounded,
                              color: AppColors.brandGreen, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Lat: ${_picked!.latitude.toStringAsFixed(6)}'
                              '  ·  Lng: ${_picked!.longitude.toStringAsFixed(6)}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),

                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _picked != null ? _confirm : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text(
                          'Confirm Location',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.onTap});

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
                  color: Colors.black.withOpacity(0.12), blurRadius: 8)
            ],
          ),
          child: Icon(icon, size: 16, color: AppColors.textPrimary),
        ),
      );
}
