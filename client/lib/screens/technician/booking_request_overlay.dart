import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';

// ─── Show helper ──────────────────────────────────────────────────────────────
Future<bool> showBookingRequestOverlay(
  BuildContext context,
  SocketBooking booking,
  int requestNumber,
) {
  return Navigator.of(context).push<bool>(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black87,
      pageBuilder: (_, __, ___) => BookingRequestOverlay(booking: booking, requestNumber: requestNumber),
      transitionsBuilder: (_, anim, __, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
            .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
      transitionDuration: const Duration(milliseconds: 350),
    ),
  ).then((v) => v ?? false);
}

// ─── Overlay screen ────────────────────────────────────────────────────────────

class BookingRequestOverlay extends StatefulWidget {
  final SocketBooking booking;
  final int requestNumber;
  const BookingRequestOverlay({super.key, required this.booking, required this.requestNumber});

  @override
  State<BookingRequestOverlay> createState() => _BookingRequestOverlayState();
}

class _BookingRequestOverlayState extends State<BookingRequestOverlay>
    with TickerProviderStateMixin {
  static const Color _primary = Color(0xFF1A3A6B);
  static const Color _orange  = Color(0xFFF59E0B);

  late final AnimationController _pulseCtrl;
  final AudioPlayer _audioPlayer = AudioPlayer();

  Timer? _timer;
  Timer? _hapticTimer;
  Timer? _beepTimer;
  int  _secondsLeft = AppConstants.bookingRequestTimeoutSeconds;
  bool _responding  = false;
  // Idempotency gate — prevents double-pop when the client 40s timer and the
  // server's booking_cancelled event arrive within the same event-loop frame.
  // Both call _dismiss(); the second must be a no-op because mounted stays
  // true for the entire 350ms pop animation, so a !mounted guard alone is
  // insufficient and the second pop removes the dashboard → black screen.
  bool _dismissed = false;

  // Socket subscriptions owned by the overlay so it manages its own lifecycle.
  // The dashboard must NOT also listen to booking_cancelled — dual-dismiss
  // causes a race where both Navigator.pop() paths fire simultaneously and the
  // second pop removes the dashboard, leaving a black screen.
  StreamSubscription<int>?          _cancelSub;
  StreamSubscription<SocketBooking>? _retrySub;

  // Driver location (fetched on init for static map + ETA)
  LatLng? _myLocation;

  // ETA / distance from Directions API
  String _distText    = '—';
  String _etaText     = '—';
  bool   _loadingEta  = true;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _playBeep();
    _beepTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_responding) _playBeep();
    });

    _startCountdown();

    _hapticTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && !_responding) HapticFeedback.mediumImpact();
    });

    // The overlay owns its own dismissal — never rely on the dashboard's
    // booking_cancelled listener which would create a dual-pop race condition.
    _cancelSub = SocketService.instance.onBookingCancelled.listen((id) {
      if (id != widget.booking.bookingId || !mounted || _responding) return;
      _dismiss();
    });

    // When the server retries the same booking (same bookingId sent again),
    // reset the countdown so it stays synchronised with the server's 40-second
    // window. Without this, the counter keeps running from attempt 1 and may
    // auto-close while the server is still waiting for a response on attempt 2.
    _retrySub = SocketService.instance.onBookingRequest.listen((b) {
      if (b.bookingId != widget.booking.bookingId || !mounted || _responding) return;
      _resetCountdown();
    });

    _initLocationAndEta();
  }

  Future<void> _playBeep() async {
    try {
      await _audioPlayer.stop();
      await _audioPlayer.play(AssetSource('sounds/beeb_sound.mp3'));
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _hapticTimer?.cancel();
    _beepTimer?.cancel();
    _cancelSub?.cancel();
    _retrySub?.cancel();
    _audioPlayer.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ── Fetch driver location + road ETA ─────────────────────────────────────────

  Future<void> _initLocationAndEta() async {
    // 1. Get driver position
    LatLng? drvLoc;
    try {
      Position? pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                  accuracy: LocationAccuracy.medium))
          .timeout(const Duration(seconds: 6));
      drvLoc = LatLng(pos.latitude, pos.longitude);
    } catch (_) {}

    if (!mounted) return;
    if (drvLoc != null) setState(() => _myLocation = drvLoc);

    final patLat = widget.booking.patientLat;
    final patLng = widget.booking.patientLng;

    if (drvLoc == null || patLat == null || patLng == null) {
      // No GPS — show straight-line if at least patient coords exist
      if (patLat != null && drvLoc != null) {
        final d = _haversineKm(
            drvLoc.latitude, drvLoc.longitude, patLat, patLng!);
        final mins = ((d / 25) * 60).ceil();
        if (mounted) {
          setState(() {
            _distText   = d < 1 ? '${(d * 1000).round()} m' : '${d.toStringAsFixed(1)} km';
            _etaText    = mins <= 1 ? '< 1 min' : '$mins min';
            _loadingEta = false;
          });
        }
      } else {
        if (mounted) setState(() => _loadingEta = false);
      }
      return;
    }

    // 2. Straight-line estimate first (instant)
    final rawD = _haversineKm(
        drvLoc.latitude, drvLoc.longitude, patLat, patLng);
    final rawMins = ((rawD / 25) * 60).ceil();
    if (mounted) {
      setState(() {
        _distText = rawD < 1
            ? '${(rawD * 1000).round()} m'
            : '${rawD.toStringAsFixed(1)} km';
        _etaText  = rawMins <= 1 ? '< 1 min' : '$rawMins min';
      });
    }

    // 3. Refine with Directions API (road distance + real ETA)
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${drvLoc.latitude},${drvLoc.longitude}'
        '&destination=$patLat,$patLng'
        '&mode=driving'
        '&key=${AppConstants.googleMapsApiKey}',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 7));
      if (res.statusCode == 200) {
        final body   = jsonDecode(res.body) as Map<String, dynamic>;
        final routes = body['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final leg     = routes[0]['legs'][0] as Map<String, dynamic>;
          final roadM   = leg['distance']['value'] as int;
          final roadSec = leg['duration']['value'] as int;
          final mins    = (roadSec / 60).round();
          if (mounted) {
            setState(() {
              _distText = roadM < 1000
                  ? '$roadM m'
                  : '${(roadM / 1000).toStringAsFixed(1)} km';
              _etaText  = mins <= 1 ? '< 1 min' : '$mins min';
            });
          }
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _loadingEta = false);
  }

  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.pow(math.sin(dLon / 2), 2);
    return R * 2 * math.atan2(math.sqrt(a.toDouble()), math.sqrt(1 - a.toDouble()));
  }

  // ── Static map URL: shows driver (blue D) + patient (green P) + path ─────────

  String _staticMapUrl() {
    final patLat = widget.booking.patientLat;
    final patLng = widget.booking.patientLng;
    if (patLat == null || patLng == null) return '';

    const key = AppConstants.googleMapsApiKey;

    if (_myLocation != null) {
      final dLat = _myLocation!.latitude;
      final dLng = _myLocation!.longitude;
      return 'https://maps.googleapis.com/maps/api/staticmap'
          '?size=600x220&scale=2'
          '&markers=color:blue%7Clabel:D%7C$dLat,$dLng'
          '&markers=color:green%7Clabel:P%7C$patLat,$patLng'
          '&path=color:0x1A3A6Bcc%7Cweight:4%7C$dLat,$dLng%7C$patLat,$patLng'
          '&key=$key';
    }

    // Fallback: patient only
    return 'https://maps.googleapis.com/maps/api/staticmap'
        '?size=600x220&scale=2'
        '&markers=color:green%7Clabel:P%7C$patLat,$patLng'
        '&center=$patLat,$patLng&zoom=14'
        '&key=$key';
  }

  // ── Countdown helpers ─────────────────────────────────────────────────────────

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        t.cancel();
        _dismiss();
      }
    });
  }

  // Called when the server retries the same booking (same bookingId resent).
  // Resets the on-screen countdown to the full timeout so the tech always has
  // a fresh 40-second window — matching the server's per-attempt timer exactly.
  void _resetCountdown() {
    setState(() => _secondsLeft = AppConstants.bookingRequestTimeoutSeconds);
    _startCountdown();
  }

  // Single dismiss path for all non-accept exits:
  //   • client countdown hits zero
  //   • server sends booking_cancelled for this booking
  // Having ONE path prevents the dual-pop race that left a black screen.
  void _dismiss() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    Navigator.of(context).pop(false);
  }

  // ── Actions ───────────────────────────────────────────────────────────────────

  void _accept() {
    if (_responding) return;
    setState(() => _responding = true);
    _timer?.cancel();
    HapticFeedback.mediumImpact();
    SocketService.instance.emitBookingAccepted(
      bookingId:      widget.booking.bookingId,
      technicianId:   SocketService.instance.userId,
      technicianName: SocketService.instance.userName,
      sessionId:      SocketService.instance.sessionId,
    );
    Navigator.of(context).pop(true);
  }

  void _reject() {
    if (_responding) return;
    setState(() => _responding = true);
    _timer?.cancel();
    HapticFeedback.mediumImpact();
    SocketService.instance.emitBookingRejected(
      bookingId:    widget.booking.bookingId,
      technicianId: SocketService.instance.userId,
    );
    Navigator.of(context).pop(false);
  }

  void _call() {
    final phone = widget.booking.patientMobile;
    if (phone.isEmpty) return;
    launchUrl(Uri.parse('tel:+91$phone'));
  }

  void _openInMaps() {
    final lat = widget.booking.patientLat;
    final lng = widget.booking.patientLng;
    if (lat == null || lng == null) return;
    launchUrl(
      Uri.parse('https://maps.google.com/?q=$lat,$lng&z=17'),
      mode: LaunchMode.externalApplication,
    );
  }

  // ── Ring color ────────────────────────────────────────────────────────────────

  Color get _ringColor {
    if (_secondsLeft > 20) return AppColors.brandGreen;
    if (_secondsLeft > 10) return _orange;
    return const Color(0xFFD32F2F);
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final safeTop    = MediaQuery.of(context).padding.top;
    final hasMap     = widget.booking.patientLat != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          SizedBox(height: safeTop + 20),

          // ── Header row ─────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                // Pulsing science icon
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, __) => Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.brandGreen.withValues(
                          alpha: 0.6 + 0.4 * _pulseCtrl.value),
                    ),
                    child: const Icon(Icons.science_rounded,
                        color: Colors.white, size: 28),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('New Booking Request',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('Request #${widget.requestNumber}  ·  Home Collection',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(width: 14),

                // Countdown ring (CircularProgressIndicator style)
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: _secondsLeft /
                            AppConstants.bookingRequestTimeoutSeconds,
                        strokeWidth: 4,
                        backgroundColor: Colors.white24,
                        color: _ringColor,
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$_secondsLeft',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: _ringColor),
                          ),
                          Text('sec',
                              style: TextStyle(
                                  fontSize: 8,
                                  color: _ringColor.withValues(alpha: 0.7))),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Main white card ────────────────────────────────────────────────
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SingleChildScrollView(
                padding:
                    EdgeInsets.fromLTRB(20, 16, 20, safeBottom + 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // Drag handle
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                            color: AppColors.divider,
                            borderRadius: BorderRadius.circular(2)),
                      ),
                    ),

                    // ── Static map (driver D + patient P + path) ─────────────
                    if (hasMap) ...[
                      GestureDetector(
                        onTap: _openInMaps,
                        child: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.network(
                                _staticMapUrl(),
                                height: 150,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                loadingBuilder: (_, child, prog) =>
                                    prog == null
                                        ? child
                                        : Container(
                                            height: 150,
                                            decoration: BoxDecoration(
                                              color: AppColors.background,
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            child: const Center(
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2)),
                                          ),
                                errorBuilder: (_, __, ___) => Container(
                                  height: 150,
                                  decoration: BoxDecoration(
                                    color: AppColors.brandGreenSurface,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: const Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.map_outlined,
                                            color: AppColors.brandGreen,
                                            size: 32),
                                        SizedBox(height: 6),
                                        Text('Map unavailable',
                                            style: TextStyle(
                                                color: AppColors.textHint,
                                                fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            // "Tap to open" hint
                            Positioned(
                              bottom: 8,
                              right: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.open_in_full_rounded,
                                        color: Colors.white, size: 11),
                                    SizedBox(width: 4),
                                    Text('Tap to open',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 10)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Open in Maps button (below map)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _openInMaps,
                              icon: const Icon(Icons.map_outlined, size: 15),
                              label: const Text('Open in Maps',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600)),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF1565C0),
                                side: const BorderSide(
                                    color: Color(0xFF1565C0), width: 1),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 9),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                          if (widget.booking.patientMobile.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _call,
                                icon: const Icon(Icons.phone_rounded,
                                    size: 15),
                                label: const Text('Call Patient',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.brandGreen,
                                  side: BorderSide(
                                      color: AppColors.brandGreen
                                          .withValues(alpha: 0.5),
                                      width: 1),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 9),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(10)),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 14),
                    ],

                    // ── ETA + Distance card (horizontal) ─────────────────────
                    if (!_loadingEta && _distText != '—') ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEEF4FB),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_etaText,
                                    style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        color: _primary,
                                        height: 1.1)),
                                const Text('ETA',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textHint)),
                              ],
                            ),
                            Container(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 14),
                              width: 1,
                              height: 32,
                              color: AppColors.divider,
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_distText,
                                    style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.brandGreen,
                                        height: 1.1)),
                                const Text('away',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textHint)),
                              ],
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColors.brandGreenSurface,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Text('Road estimate',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: AppColors.brandGreen,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // ── Patient info rows ─────────────────────────────────────
                    _DetailRow(
                      icon: Icons.person_rounded,
                      label: 'Patient',
                      value: widget.booking.patientName.isEmpty
                          ? 'Unknown'
                          : widget.booking.patientName,
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      icon: Icons.phone_rounded,
                      label: 'Mobile',
                      value: widget.booking.patientMobile.isEmpty
                          ? '—'
                          : '+91 ${widget.booking.patientMobile}',
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      icon: Icons.home_rounded,
                      label: 'Address',
                      value: widget.booking.patientAddress.isEmpty
                          ? 'Address not provided'
                          : widget.booking.patientAddress,
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      icon: Icons.science_outlined,
                      label: 'Type',
                      value: widget.booking.hospital.isEmpty
                          ? 'Home Collection'
                          : widget.booking.hospital,
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      icon: Icons.location_city_rounded,
                      label: 'Branch',
                      value: widget.booking.branchName?.isNotEmpty == true
                          ? widget.booking.branchName!
                          : widget.booking.branchId != null
                              ? 'Branch #${widget.booking.branchId}'
                              : 'Unassigned',
                      highlight: true,
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      icon: Icons.tag_rounded,
                      label: 'Booking ID',
                      value: '#${widget.booking.bookingId}',
                    ),

                    const SizedBox(height: 20),

                    // ── Accept / Decline buttons ──────────────────────────────
                    Row(
                      children: [
                        // Decline
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _responding ? null : _reject,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            label: const Text('Decline'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFD32F2F),
                              side: const BorderSide(
                                  color: Color(0xFFD32F2F), width: 1.5),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              textStyle: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Accept (2× wider)
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: _responding ? null : _accept,
                            icon: _responding
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white))
                                : const Icon(Icons.check_rounded, size: 18),
                            label: Text(
                                _responding ? 'Accepting…' : 'Accept Booking'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.brandGreen,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              textStyle: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Detail row ───────────────────────────────────────────────────────────────

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   value;
  final bool     highlight;
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: highlight
                  ? AppColors.brandGreen.withValues(alpha: 0.12)
                  : AppColors.brandGreenSurface,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16,
                color: highlight ? AppColors.brandGreen : AppColors.brandGreen),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 74,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(value,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: highlight
                          ? AppColors.brandGreen
                          : AppColors.textPrimary)),
            ),
          ),
        ],
      );
}
