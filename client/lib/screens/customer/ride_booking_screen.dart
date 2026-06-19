import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';
import 'patient_ride_tracking_screen.dart';

// ── State machine phases ───────────────────────────────────────────────────────
enum _RideBookingPhase { form, waiting, accepted, declined }

// ── Preset hospital list ───────────────────────────────────────────────────────
const List<String> _kHospitals = [
  'Apollo Hospital',
  'Fortis Hospital',
  'AIIMS',
  'MIOT Hospital',
  'Vijaya Hospital',
  'Kauvery Hospital',
  'Sri Ramachandra Hospital',
  'Gleneagles Global Health City',
  'Government General Hospital',
  'Other',
];

class RideBookingScreen extends StatefulWidget {
  final int patientId;
  final String patientName;
  final String patientMobile;
  final String patientAddress;
  final double? savedLat;
  final double? savedLng;

  const RideBookingScreen({
    super.key,
    required this.patientId,
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    this.savedLat,
    this.savedLng,
  });

  @override
  State<RideBookingScreen> createState() => _RideBookingScreenState();
}

class _RideBookingScreenState extends State<RideBookingScreen> {
  _RideBookingPhase _phase = _RideBookingPhase.form;

  // Form state
  bool _useGpsPickup = false;
  String _selectedHospital = '';
  bool _useOtherHospital = false;
  final _otherHospitalCtrl = TextEditingController();
  double? _gpsLat, _gpsLng;
  String _gpsAddress = '';
  bool _fetchingGps = false;

  // Booking state
  String? _bookingId;
  Timer? _fallbackTimer;
  StreamSubscription<BookingAcceptedEvent>? _acceptedSub;
  StreamSubscription<int>? _timeoutSub;

  @override
  void dispose() {
    _otherHospitalCtrl.dispose();
    _fallbackTimer?.cancel();
    _acceptedSub?.cancel();
    _timeoutSub?.cancel();
    super.dispose();
  }

  // ── Get GPS location and reverse-geocode ─────────────────────────────────────
  Future<void> _fetchGpsLocation() async {
    setState(() => _fetchingGps = true);
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied. Enable in Settings.')),
          );
        }
        setState(() => _fetchingGps = false);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      String addr = 'GPS: ${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}';
      try {
        final placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          addr = [p.street, p.locality, p.administrativeArea]
              .where((s) => s != null && s.isNotEmpty)
              .join(', ');
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _gpsLat = pos.latitude;
        _gpsLng = pos.longitude;
        _gpsAddress = addr;
        _useGpsPickup = true;
        _fetchingGps = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _fetchingGps = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not get location: $e')),
      );
    }
  }

  // ── Effective pickup coords ───────────────────────────────────────────────────
  double? get _pickupLat => _useGpsPickup ? (_gpsLat ?? widget.savedLat) : widget.savedLat;
  double? get _pickupLng => _useGpsPickup ? (_gpsLng ?? widget.savedLng) : widget.savedLng;
  String get _pickupAddress =>
      _useGpsPickup ? (_gpsAddress.isNotEmpty ? _gpsAddress : widget.patientAddress)
                    : widget.patientAddress;

  // ── Hospital name to send ─────────────────────────────────────────────────────
  String get _hospital =>
      _useOtherHospital ? _otherHospitalCtrl.text.trim() : _selectedHospital;

  // ── Validation ────────────────────────────────────────────────────────────────
  // GPS mode requires a lat/lng. Living Address mode allows text-only (no GPS).
  bool get _canBook {
    final hasHospital = _hospital.isNotEmpty;
    final hasPickup = _pickupLat != null ||
        (!_useGpsPickup && widget.patientAddress.isNotEmpty);
    return hasHospital && hasPickup;
  }

  // ── Book ride ─────────────────────────────────────────────────────────────────
  void _bookRide() {
    if (!_canBook) return;

    final id = 'BKG-${1000 + Random().nextInt(8999)}';
    _bookingId = id;

    // Connect socket for customer role
    if (!SocketService.instance.isConnected) {
      SocketService.instance.connect(
        userId: widget.patientId,
        role: 'customer',
        name: widget.patientName,
      );
    }

    // Register patient socket so backend can reach us
    SocketService.instance.registerPatientSocket(
      patientId: widget.patientId,
      bookingId: _numericId(id),
    );

    // Emit transport booking request
    SocketService.instance.emitRideBookingRequest(
      bookingId: id,
      patientId: widget.patientId,
      patientName: widget.patientName,
      patientMobile: widget.patientMobile,
      patientAddress: _pickupAddress,
      patientLat: _pickupLat,
      patientLng: _pickupLng,
      hospital: _hospital,
    );

    setState(() => _phase = _RideBookingPhase.waiting);

    // 400s fallback — server worst-case is ~378s
    _fallbackTimer = Timer(
      Duration(seconds: AppConstants.bookingSearchTimeoutSeconds),
      () {
        if (mounted && _phase == _RideBookingPhase.waiting) {
          setState(() => _phase = _RideBookingPhase.declined);
        }
      },
    );

    _acceptedSub = SocketService.instance.onBookingAccepted.listen((event) {
      if (!mounted) return;
      _fallbackTimer?.cancel();
      _acceptedSub?.cancel();
      _timeoutSub?.cancel();

      // CRITICAL: disconnect this socket BEFORE navigating
      // Two concurrent sockets from same device cause "offline" appearance
      SocketService.instance.disconnect();

      // Persist ride info so dashboard can show "Track Driver" button
      SocketService.instance.setActiveRide(ActiveRideInfo(
        bookingId: int.tryParse(_bookingId!) ?? 0,
        patientId: widget.patientId,
        patientName: widget.patientName,
        trackingId: event.trackingId,
        driverId: event.technicianId,
        driverName: event.technicianName,
        patientLat: _pickupLat,
        patientLng: _pickupLng,
        patientAddress: _pickupAddress,
        hospital: _hospital,
      ));

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => PatientRideTrackingScreen(
            bookingId: _bookingId!,
            patientId: widget.patientId,
            patientName: widget.patientName,
            trackingId: event.trackingId,
            driverId: event.technicianId,
            driverName: event.technicianName,
            patientLat: _pickupLat,
            patientLng: _pickupLng,
            patientAddress: _pickupAddress,
            hospital: _hospital,
          ),
        ),
      );
    });

    _timeoutSub = SocketService.instance.onBookingTimeout.listen((_) {
      if (!mounted || _phase != _RideBookingPhase.waiting) return;
      _fallbackTimer?.cancel();
      setState(() => _phase = _RideBookingPhase.declined);
    });
  }

  // Convert 'BKG-1234' → 1234 for integer-based socket registrations
  int _numericId(String id) =>
      int.tryParse(id.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

  void _cancelRequest() {
    _fallbackTimer?.cancel();
    _acceptedSub?.cancel();
    _timeoutSub?.cancel();
    SocketService.instance.disconnect();
    setState(() {
      _phase = _RideBookingPhase.form;
      _bookingId = null;
    });
  }

  void _resetToForm() {
    setState(() {
      _phase = _RideBookingPhase.form;
      _bookingId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          color: AppColors.textPrimary,
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _phase == _RideBookingPhase.waiting ? 'Finding Driver…' : 'Book Medical Ride',
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: switch (_phase) {
          _RideBookingPhase.form     => _buildForm(),
          _RideBookingPhase.waiting  => _buildWaiting(),
          _RideBookingPhase.accepted => const SizedBox.shrink(),
          _RideBookingPhase.declined => _buildDeclined(),
        },
      ),
    );
  }

  // ── FORM PHASE ───────────────────────────────────────────────────────────────
  Widget _buildForm() {
    return SingleChildScrollView(
      key: const ValueKey('form'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Patient info card
          _SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.person_rounded,
                          color: AppColors.brandGreen, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.patientName,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary)),
                          Text(widget.patientMobile,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.home_outlined,
                        size: 15, color: AppColors.textHint),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(widget.patientAddress,
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                              height: 1.4)),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          const _Label('Pickup Location'),
          const SizedBox(height: 10),

          // Pickup selector
          _SectionCard(
            child: Column(
              children: [
                _PickupOption(
                  icon: Icons.home_rounded,
                  label: 'Living Address',
                  subtitle: widget.patientAddress,
                  selected: !_useGpsPickup,
                  onTap: () => setState(() => _useGpsPickup = false),
                ),
                const Divider(height: 20),
                _PickupOption(
                  icon: Icons.my_location_rounded,
                  label: 'Live Location (GPS pin)',
                  subtitle: _gpsAddress.isNotEmpty
                      ? _gpsAddress
                      : 'Tap to get your current location',
                  selected: _useGpsPickup,
                  loading: _fetchingGps,
                  onTap: _fetchingGps
                      ? null
                      : () {
                          if (_gpsLat != null) {
                            setState(() => _useGpsPickup = true);
                          } else {
                            _fetchGpsLocation();
                          }
                        },
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          const _Label('Destination Hospital'),
          const SizedBox(height: 10),

          // Hospital dropdown
          _SectionCard(
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  value: _selectedHospital.isEmpty ? null : _selectedHospital,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Select hospital',
                    hintStyle: TextStyle(color: AppColors.textHint, fontSize: 14),
                    contentPadding: EdgeInsets.zero,
                  ),
                  items: _kHospitals
                      .map((h) => DropdownMenuItem(value: h, child: Text(h)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _selectedHospital = v ?? '';
                    _useOtherHospital = v == 'Other';
                    if (!_useOtherHospital) _otherHospitalCtrl.clear();
                  }),
                ),
                if (_useOtherHospital) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _otherHospitalCtrl,
                    decoration: InputDecoration(
                      hintText: 'Enter hospital name',
                      hintStyle: const TextStyle(
                          color: AppColors.textHint, fontSize: 14),
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider),
                      ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 32),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _canBook ? _bookRide : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                disabledBackgroundColor: AppColors.divider,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Book Ride Now',
                  style:
                      TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // ── WAITING PHASE ────────────────────────────────────────────────────────────
  Widget _buildWaiting() {
    return Center(
      key: const ValueKey('waiting'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PulseRing(),
            const SizedBox(height: 32),
            const Text('Finding a driver…',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            const Text(
              'Checking nearby drivers — this may take a minute…',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5),
            ),
            const SizedBox(height: 24),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: const LinearProgressIndicator(
                backgroundColor: AppColors.divider,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
              ),
            ),
            const SizedBox(height: 32),
            // 3-driver queue indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final isActive = i == 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isActive
                              ? AppColors.brandGreen
                              : AppColors.divider,
                          border: isActive
                              ? Border.all(
                                  color: AppColors.brandGreenLight,
                                  width: 2)
                              : null,
                        ),
                        child: Center(
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: isActive
                                  ? Colors.white
                                  : AppColors.textHint,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Driver ${i + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          color: isActive
                              ? AppColors.brandGreen
                              : AppColors.textHint,
                          fontWeight: isActive
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
            const SizedBox(height: 32),
            TextButton(
              onPressed: _cancelRequest,
              child: const Text('Cancel request',
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }

  // ── DECLINED PHASE ───────────────────────────────────────────────────────────
  Widget _buildDeclined() {
    return Center(
      key: const ValueKey('declined'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: Color(0xFFFFEBEE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cancel_rounded,
                  color: Color(0xFFD32F2F), size: 44),
            ),
            const SizedBox(height: 24),
            const Text('No driver available',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            const Text(
              'All nearby drivers are unavailable right now.\nPlease try again in a few minutes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: 200,
              child: ElevatedButton(
                onPressed: _resetToForm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Try Again',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Animated pulse ring ───────────────────────────────────────────────────────

class _PulseRing extends StatefulWidget {
  const _PulseRing();
  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing> with TickerProviderStateMixin {
  late final AnimationController _c1, _c2;
  late final Animation<double> _scale1, _opacity1, _scale2, _opacity2;

  @override
  void initState() {
    super.initState();
    _c1 = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
    _c2 = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..forward(from: 0.6)
      ..repeat();
    _scale1   = Tween(begin: 0.4, end: 1.6).animate(CurvedAnimation(parent: _c1, curve: Curves.easeOut));
    _opacity1 = Tween(begin: 0.9, end: 0.0).animate(CurvedAnimation(parent: _c1, curve: Curves.easeOut));
    _scale2   = Tween(begin: 0.4, end: 1.6).animate(CurvedAnimation(parent: _c2, curve: Curves.easeOut));
    _opacity2 = Tween(begin: 0.9, end: 0.0).animate(CurvedAnimation(parent: _c2, curve: Curves.easeOut));
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
            _ring(_c1, _scale1, _opacity1),
            _ring(_c2, _scale2, _opacity2),
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.brandGreen,
                shape: BoxShape.circle,
              ),
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
                border: Border.all(color: AppColors.brandGreen, width: 2.5),
              ),
            ),
          ),
        ),
      );
}

// ── Reusable small widgets ────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
            letterSpacing: 0.3),
      );
}

class _SectionCard extends StatelessWidget {
  final Widget child;
  const _SectionCard({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
                color: Colors.black12, blurRadius: 8, offset: Offset(0, 2))
          ],
        ),
        child: child,
      );
}

class _PickupOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool selected;
  final bool loading;
  final VoidCallback? onTap;

  const _PickupOption({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.selected,
    this.loading = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.brandGreenSurface
                      : AppColors.background,
                  shape: BoxShape.circle,
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              AppColors.brandGreen),
                        ),
                      )
                    : Icon(icon,
                        color: selected
                            ? AppColors.brandGreen
                            : AppColors.textHint,
                        size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? AppColors.textPrimary
                                : AppColors.textSecondary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textHint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle_rounded,
                    color: AppColors.brandGreen, size: 20),
            ],
          ),
        ),
      );
}
