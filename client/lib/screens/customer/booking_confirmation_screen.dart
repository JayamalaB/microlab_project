import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';
import 'tracking_map_screen.dart';

class BookingConfirmationScreen extends StatefulWidget {
  final int bookingId;
  final int patientId;
  final String patientName;
  final String patientMobile;
  final String patientAddress;
  final double? patientLat;
  final double? patientLng;
  final String hospital;

  const BookingConfirmationScreen({
    super.key,
    required this.bookingId,
    required this.patientId,
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    this.patientLat,
    this.patientLng,
    required this.hospital,
  });

  @override
  State<BookingConfirmationScreen> createState() =>
      _BookingConfirmationScreenState();
}

class _BookingConfirmationScreenState
    extends State<BookingConfirmationScreen> with TickerProviderStateMixin {
  late final AnimationController _dotCtrl;
  late final AnimationController _pulseCtrl;

  StreamSubscription<BookingAcceptedEvent>? _acceptedSub;
  StreamSubscription<int>? _timeoutSub;

  Timer? _searchTimer;
  int _secondsSearched = 0;
  bool _timedOut = false;
  bool _accepted = false;

  @override
  void initState() {
    super.initState();

    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    // Register patient socket and emit booking request
    SocketService.instance.registerPatientSocket(
      patientId: widget.patientId,
      bookingId: widget.bookingId,
    );
    SocketService.instance.emitBookingRequest(
      bookingId:      widget.bookingId,
      patientId:      widget.patientId,
      patientName:    widget.patientName,
      patientMobile:  widget.patientMobile,
      patientAddress: widget.patientAddress,
      patientLat:     widget.patientLat,
      patientLng:     widget.patientLng,
      hospital:       widget.hospital,
    );

    _acceptedSub = SocketService.instance.onBookingAccepted.listen((event) {
      if (event.bookingId != widget.bookingId || !mounted) return;
      _onAccepted(event);
    });

    _timeoutSub = SocketService.instance.onBookingTimeout.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      if (mounted) setState(() => _timedOut = true);
    });

    _searchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsSearched++);
      if (_secondsSearched >= AppConstants.bookingSearchTimeoutSeconds) {
        _searchTimer?.cancel();
        if (mounted) setState(() => _timedOut = true);
      }
    });
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    _pulseCtrl.dispose();
    _acceptedSub?.cancel();
    _timeoutSub?.cancel();
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onAccepted(BookingAcceptedEvent event) {
    if (_accepted) return;
    setState(() => _accepted = true);
    _searchTimer?.cancel();
    HapticFeedback.mediumImpact();

    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, anim, __) => TrackingMapScreen(
            bookingId:      widget.bookingId,
            patientId:      widget.patientId,
            trackingId:     event.trackingId,
            technicianId:   event.technicianId,
            technicianName: event.technicianName,
            patientLat:     widget.patientLat,
            patientLng:     widget.patientLng,
            patientAddress: widget.patientAddress,
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    });
  }

  void _cancel() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cancel Search?',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: const Text(
          'Stop looking for a technician and go back?',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('No',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Yes, Cancel',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.white,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 16),

                // Back / cancel
                Row(
                  children: [
                    GestureDetector(
                      onTap: _cancel,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.divider),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.close_rounded,
                            size: 18, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),

                const Spacer(),

                // ── Accepted state ────────────────────────────────────────
                if (_accepted) ...[
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
                  const Text('Technician Found!',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 8),
                  const Text('Opening tracking map…',
                      style: TextStyle(
                          fontSize: 14, color: AppColors.textSecondary)),
                ]

                // ── Timeout state ─────────────────────────────────────────
                else if (_timedOut) ...[
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFFD32F2F).withValues(alpha: 0.2))),
                    child: const Icon(Icons.person_off_outlined,
                        color: Color(0xFFD32F2F), size: 40),
                  ),
                  const SizedBox(height: 24),
                  const Text('No Technician Available',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 8),
                  const Text(
                    'All nearby technicians are busy.\nPlease try again later.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 14, color: AppColors.textSecondary,
                        height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Go Back',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]

                // ── Searching state ───────────────────────────────────────
                else ...[
                  // Pulsing ring
                  AnimatedBuilder(
                    animation: _pulseCtrl,
                    builder: (_, __) => Container(
                      width: 120 + 20 * _pulseCtrl.value,
                      height: 120 + 20 * _pulseCtrl.value,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.brandGreen
                            .withValues(alpha: 0.05 * (1 - _pulseCtrl.value)),
                      ),
                      child: Center(
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.brandGreenSurface,
                          ),
                          child: const Icon(Icons.search_rounded,
                              color: AppColors.brandGreen, size: 44),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  const Text('Finding Technician…',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),

                  const SizedBox(height: 10),

                  // Animated dots subtitle
                  AnimatedBuilder(
                    animation: _dotCtrl,
                    builder: (_, __) {
                      final dots = '.' * ((_dotCtrl.value * 3).floor() + 1);
                      return Text(
                        'Searching nearby technicians$dots',
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textSecondary),
                      );
                    },
                  ),

                  const SizedBox(height: 32),

                  // 3 pulsing indicator dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(3, (i) {
                      final delay = i / 3;
                      return AnimatedBuilder(
                        animation: _dotCtrl,
                        builder: (_, __) {
                          final v = ((_dotCtrl.value + delay) % 1.0);
                          final scale = 0.6 + 0.4 * (v < 0.5 ? v * 2 : (1 - v) * 2);
                          return Container(
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: 12 * scale,
                            height: 12 * scale,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.brandGreen
                                  .withValues(alpha: 0.3 + 0.7 * scale),
                            ),
                          );
                        },
                      );
                    }),
                  ),

                  const SizedBox(height: 40),

                  // Booking details summary card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Column(
                      children: [
                        _SummaryRow(Icons.tag_rounded,
                            'Booking ID', '#${widget.bookingId}'),
                        const SizedBox(height: 8),
                        _SummaryRow(Icons.home_outlined,
                            'Pickup', widget.patientAddress),
                        const SizedBox(height: 8),
                        _SummaryRow(Icons.local_hospital_outlined,
                            'Destination', widget.hospital),
                      ],
                    ),
                  ),
                ],

                const Spacer(),

                // Cancel button (only during search)
                if (!_accepted && !_timedOut) ...[
                  TextButton(
                    onPressed: _cancel,
                    child: const Text('Cancel Search',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _SummaryRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: AppColors.brandGreen),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary)),
          ),
        ],
      );
}
