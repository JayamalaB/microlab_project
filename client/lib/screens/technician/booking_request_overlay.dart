import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';

// ─── Show helper ──────────────────────────────────────────────────────────────
// Call this from TechnicianDashboard when booking_request arrives.
// Returns true if accepted, false if declined/timed-out.
Future<bool> showBookingRequestOverlay(
  BuildContext context,
  SocketBooking booking,
) {
  return Navigator.of(context).push<bool>(
        PageRouteBuilder(
          opaque: false,
          barrierColor: Colors.black87,
          pageBuilder: (_, __, ___) =>
              BookingRequestOverlay(booking: booking),
          transitionsBuilder: (_, anim, __, child) => SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0, 1), end: Offset.zero)
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
  const BookingRequestOverlay({super.key, required this.booking});

  @override
  State<BookingRequestOverlay> createState() => _BookingRequestOverlayState();
}

class _BookingRequestOverlayState extends State<BookingRequestOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _ringCtrl;
  late final AnimationController _pulseCtrl;

  Timer? _timer;
  int _secondsLeft = AppConstants.bookingRequestTimeoutSeconds;
  bool _responding = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();

    _ringCtrl = AnimationController(
      vsync: this,
      duration:
          Duration(seconds: AppConstants.bookingRequestTimeoutSeconds),
    )..forward();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        t.cancel();
        _timeout();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ringCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _timeout() {
    // Silent dismiss — server handles retry logic, we do NOT emit rejected
    if (mounted) Navigator.of(context).pop(false);
  }

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

  Color get _ringColor {
    if (_secondsLeft > 20) return AppColors.brandGreen;
    if (_secondsLeft > 10) return const Color(0xFFE65100);
    return const Color(0xFFD32F2F);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _secondsLeft / AppConstants.bookingRequestTimeoutSeconds;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),

            // ── Header ─────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  AnimatedBuilder(
                    animation: _pulseCtrl,
                    builder: (_, __) => Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.white
                            .withValues(alpha: 0.4 + 0.6 * _pulseCtrl.value),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'New Booking Request',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Countdown ring ─────────────────────────────────────────────
            AnimatedBuilder(
              animation: _ringCtrl,
              builder: (_, __) => SizedBox(
                width: 120,
                height: 120,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(120, 120),
                      painter: _RingPainter(
                          progress: progress, color: _ringColor),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_secondsLeft',
                          style: TextStyle(
                            color: _ringColor,
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Text('sec',
                            style: TextStyle(
                                color: Colors.white60, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ── Main card ──────────────────────────────────────────────────
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Patient name + VIP + call button
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.booking.patientName,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                          if (widget.booking.patientMobile.isNotEmpty)
                            GestureDetector(
                              onTap: _call,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: AppColors.brandGreenSurface,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: AppColors.brandGreenLight),
                                ),
                                child: const Icon(Icons.phone_rounded,
                                    color: AppColors.brandGreen, size: 18),
                              ),
                            ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      // Address
                      _InfoTile(
                        icon: Icons.home_outlined,
                        label: 'Pickup Address',
                        value: widget.booking.patientAddress.isEmpty
                            ? 'Address not provided'
                            : widget.booking.patientAddress,
                      ),

                      const SizedBox(height: 10),

                      // Hospital / destination
                      _InfoTile(
                        icon: Icons.local_hospital_outlined,
                        label: 'Destination',
                        value: widget.booking.hospital,
                      ),

                      // GPS coordinates + Open Maps
                      if (widget.booking.patientLat != null) ...[
                        const SizedBox(height: 10),
                        GestureDetector(
                          onTap: _openInMaps,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: AppColors.blueSurface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppColors.blue.withValues(alpha: 0.2)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.map_outlined,
                                    size: 16, color: AppColors.blue),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${widget.booking.patientLat!.toStringAsFixed(5)}, '
                                    '${widget.booking.patientLng!.toStringAsFixed(5)}',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.blue,
                                        fontWeight: FontWeight.w500),
                                  ),
                                ),
                                const Text('Open Maps',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.blue,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(width: 4),
                                const Icon(Icons.open_in_new_rounded,
                                    size: 12, color: AppColors.blue),
                              ],
                            ),
                          ),
                        ),
                      ],

                      const SizedBox(height: 10),

                      // Booking ID
                      _InfoTile(
                        icon: Icons.tag_rounded,
                        label: 'Booking ID',
                        value: '#${widget.booking.bookingId}',
                      ),

                      const SizedBox(height: 24),

                      // Action buttons
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _responding ? null : _reject,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFD32F2F),
                                side: const BorderSide(
                                    color: Color(0xFFD32F2F), width: 1.5),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                              child: const Text('Decline',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: _responding ? null : _accept,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.brandGreen,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                              child: _responding
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white))
                                  : const Text('Accept Booking',
                                      style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ─── Countdown ring painter ────────────────────────────────────────────────────

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;

    // Background ring
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8,
    );

    // Progress arc
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

// ─── Shared info tile ─────────────────────────────────────────────────────────

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoTile(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.brandGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textHint)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary)),
              ],
            ),
          ),
        ],
      );
}
