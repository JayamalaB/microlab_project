import 'dart:async';
import 'package:flutter/material.dart';
import 'package:microlab/models.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';
import 'support_chatbot.dart';

class OrderDetailsScreen extends StatefulWidget {
  final BookingModel booking;

  const OrderDetailsScreen({super.key, required this.booking});

  @override
  State<OrderDetailsScreen> createState() => _OrderDetailsScreenState();
}

class _OrderDetailsScreenState extends State<OrderDetailsScreen> with WidgetsBindingObserver {
  late String? _collectionStatus;
  late String? _technicianName;
  late String? _technicianPhoto;
  late bool    _hasReport;
  bool _refreshing = false;

  StreamSubscription<dynamic>? _acceptedSub;
  StreamSubscription<dynamic>? _enRouteSub;
  StreamSubscription<dynamic>? _arrivedSub;
  StreamSubscription<dynamic>? _collectedSub;
  StreamSubscription<dynamic>? _connectedSub;

  @override
  void initState() {
    super.initState();
    _collectionStatus = widget.booking.collectionStatus;
    _technicianName   = widget.booking.technicianName;
    _technicianPhoto  = widget.booking.technicianPhoto;
    _hasReport        = widget.booking.hasReport;
    WidgetsBinding.instance.addObserver(this);
    _acceptedSub  = SocketService.instance.onBookingAccepted.listen((_) => _refresh());
    _enRouteSub   = SocketService.instance.onTechnicianEnRoute.listen((_) => _refresh());
    _arrivedSub   = SocketService.instance.onTechnicianArrived.listen((_) => _refresh());
    _collectedSub = SocketService.instance.onCollectionCompleted.listen((_) => _refresh());
    _connectedSub = SocketService.instance.onConnected.listen((_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _acceptedSub?.cancel();
    _enRouteSub?.cancel();
    _arrivedSub?.cancel();
    _collectedSub?.cancel();
    _connectedSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = widget.booking.bookingIdNum;
    if (id == null || _refreshing) return;
    setState(() => _refreshing = true);
    try {
      final data = await ApiService.fetchBookingStatus(id);
      if (!mounted || data == null) return;
      setState(() {
        _collectionStatus = data['collection_status'] as String? ?? _collectionStatus;
        _technicianName   = data['tech_name']         as String? ?? _technicianName;
        _technicianPhoto  = data['tech_photo']         as String? ?? _technicianPhoto;
        _hasReport        = data['has_report'] as bool? ?? _hasReport;
      });
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  // Returns 1–8: the highest stage currently reached.
  int get _activeStage {
    final cs = _collectionStatus ?? '';
    final bs = widget.booking.status;

    if (_hasReport) return 8;
    if (const {'handed_to_lab', 'handed_to_lab_pending'}.contains(cs) ||
        const {'Completed', 'Sample Collected', 'Handed to Lab', 'Handed to Lab Pending'}.contains(bs)) return 7;
    if (const {'otp_verified', 'sample_collected'}.contains(cs)) return 5;
    if (const {'arrived', 'collection_started'}.contains(cs)) return 4;
    if (cs == 'en_route') return 3;
    if (cs.isNotEmpty ||
        const {'Technician Allocated', 'Technician Arrived', 'In Progress'}.contains(bs)) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final active = _activeStage;

    return CustomerThemeScope(
      child: Scaffold(
        backgroundColor: CxColors.page,
        appBar: AppBar(
          backgroundColor: AppColors.brandGreen,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('Order Details',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          actions: [
            _refreshing
                ? const Padding(
                    padding: EdgeInsets.only(right: 16),
                    child: Center(child: SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))),
                  )
                : IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                    tooltip: 'Refresh',
                    onPressed: _refresh,
                  ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _refresh,
          color: AppColors.brandGreen,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.lg, CxSpace.gutter, 48),
            children: [
              // ── Booking reference ──────────────────────────────
              if (b.referenceNo != null) ...[
                Text('Booking Id: ${b.referenceNo}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700, color: CxColors.textPrimary)),
                const SizedBox(height: CxSpace.lg),
              ],

              // ── Status + timeline card ─────────────────────────
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: CxRadius.lgAll,
                  border: Border.all(color: CxColors.border),
                  boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 2))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Status row
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: Row(
                        children: [
                          _StatusPill(status: b.status),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => showSupportChatbot(context,
                                patientId: b.member.id),
                            icon: const Icon(Icons.support_agent_outlined, size: 16),
                            label: const Text('Need Help'),
                            style: TextButton.styleFrom(
                              foregroundColor: CxColors.textSecondary,
                              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              minimumSize: const Size(0, 32),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Timeline
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                      child: _Timeline(
                        activeStage: active,
                        technicianName: _technicianName,
                        technicianPhoto: _technicianPhoto,
                      ),
                    ),
                  ],
                ),
              ),

            ],
          ),
        ),
      ),
    );
  }
}

// ─── Status pill ──────────────────────────────────────────────────────────────

class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});

  Color get _color {
    switch (status) {
      case 'Cancelled':  return CxColors.error;
      case 'Completed':  return AppColors.brandGreen;
      case 'Handed to Lab':
      case 'Sample Collected': return AppColors.brandGreen;
      default:           return const Color(0xFFB8A000);
    }
  }

  Color get _bg => _color.withValues(alpha: 0.12);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: _bg, borderRadius: CxRadius.pill),
        child: Text(status,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _color)),
      );
}

// ─── Timeline ─────────────────────────────────────────────────────────────────

const _kStageLabels = [
  'Home Visit Scheduled',
  'Technician Assigned',
  'Technician Started',
  'Technician Reached',
  'Sample Collected',
  'Sample Delivered to Lab',
  'Sample Under Process',
  'Report Generated',
];

const _kStageIcons = [
  Icons.event_available_outlined,
  Icons.person_outlined,
  Icons.directions_bike_outlined,
  Icons.location_on_outlined,
  Icons.science_outlined,
  Icons.local_shipping_outlined,
  Icons.biotech_outlined,
  Icons.description_outlined,
];

class _Timeline extends StatelessWidget {
  final int activeStage;      // 1–8
  final String? technicianName;
  final String? technicianPhoto;

  const _Timeline({
    required this.activeStage,
    this.technicianName,
    this.technicianPhoto,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (int i = 0; i < 8; i++) ...[
          _StageRow(
            stageNum: i + 1,
            label: _kStageLabels[i],
            icon: _kStageIcons[i],
            subtitle: (i + 1 == 2 && technicianName != null && technicianName!.isNotEmpty)
                ? technicianName
                : null,
            technicianPhoto: (i + 1 == 2) ? technicianPhoto : null,
            state: i + 1 < activeStage
                ? _StageState.done
                : i + 1 == activeStage
                    ? _StageState.current
                    : _StageState.pending,
            isLast: i == 7,
          ),
        ],
      ],
    );
  }
}

enum _StageState { done, current, pending }

class _StageRow extends StatelessWidget {
  final int stageNum;
  final String label;
  final IconData icon;
  final String? subtitle;
  final String? technicianPhoto;
  final _StageState state;
  final bool isLast;

  const _StageRow({
    required this.stageNum,
    required this.label,
    required this.icon,
    this.subtitle,
    this.technicianPhoto,
    required this.state,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final isDone    = state == _StageState.done;
    final isCurrent = state == _StageState.current;
    final isPending = state == _StageState.pending;

    final dotColor  = isPending ? CxColors.border : AppColors.brandGreen;
    final lineColor = isDone ? AppColors.brandGreen : CxColors.border;
    final labelStyle = isPending
        ? const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: CxColors.textHint)
        : const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: CxColors.textPrimary);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Left column: dot + dashed line
        SizedBox(
          width: 28,
          child: Column(
            children: [
              // Dot / avatar
              isCurrent && technicianPhoto != null && technicianPhoto!.isNotEmpty
                  ? CircleAvatar(
                      radius: 14,
                      backgroundImage: NetworkImage(technicianPhoto!),
                      backgroundColor: AppColors.brandGreenSurface,
                    )
                  : Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: isDone
                            ? AppColors.brandGreen
                            : isCurrent
                                ? AppColors.brandGreenSurface
                                : CxColors.page,
                        shape: BoxShape.circle,
                        border: Border.all(color: dotColor, width: isDone ? 0 : 2),
                      ),
                      child: Icon(
                        isDone ? Icons.check_rounded : icon,
                        size: 14,
                        color: isDone
                            ? Colors.white
                            : isCurrent
                                ? AppColors.brandGreen
                                : CxColors.border,
                      ),
                    ),

              // Dashed connector
              if (!isLast)
                _DashedLine(color: lineColor, height: subtitle != null ? 56 : 40),
            ],
          ),
        ),

        const SizedBox(width: 14),

        // Right column: label + subtitle
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : (subtitle != null ? 28 : 12)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                Text(label, style: labelStyle),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!,
                      style: const TextStyle(
                          fontSize: 12, color: CxColors.textSecondary, fontWeight: FontWeight.w500)),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Dashed vertical line ─────────────────────────────────────────────────────

class _DashedLine extends StatelessWidget {
  final Color color;
  final double height;
  const _DashedLine({required this.color, required this.height});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 2,
        height: height,
        child: CustomPaint(painter: _DashedLinePainter(color: color)),
      );
}

class _DashedLinePainter extends CustomPainter {
  final Color color;
  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 2..strokeCap = StrokeCap.round;
    const dash = 5.0;
    const gap  = 4.0;
    double y = 0;
    while (y < size.height) {
      canvas.drawLine(Offset(1, y), Offset(1, (y + dash).clamp(0, size.height)), paint);
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedLinePainter old) => old.color != color;
}
