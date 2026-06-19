import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/socket_service.dart';

enum _LabStage { pending, active, done }

class LabProgressScreen extends StatefulWidget {
  final int bookingId;
  final String patientName;

  const LabProgressScreen({
    super.key,
    required this.bookingId,
    required this.patientName,
  });

  @override
  State<LabProgressScreen> createState() => _LabProgressScreenState();
}

class _LabProgressScreenState extends State<LabProgressScreen> {
  // Stage indices: 0=collected, 1=received, 2=testing, 3=report_ready
  int _stage = 0; // 0 = just collected, progresses to 3
  String? _reportUrl;

  StreamSubscription<int>? _receivedSub;
  StreamSubscription<int>? _testingSub;
  StreamSubscription<ReportReadyEvent>? _reportSub;

  @override
  void initState() {
    super.initState();
    _fetchLabStatus();

    _receivedSub = SocketService.instance.onSampleReceived.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      setState(() => _stage = 1);
      HapticFeedback.lightImpact();
    });

    _testingSub = SocketService.instance.onTestInProgress.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      setState(() => _stage = 2);
      HapticFeedback.lightImpact();
    });

    _reportSub = SocketService.instance.onReportReady.listen((event) {
      if (event.bookingId != widget.bookingId || !mounted) return;
      setState(() {
        _stage = 3;
        _reportUrl = event.reportUrl;
      });
      HapticFeedback.heavyImpact();
    });
  }

  @override
  void dispose() {
    _receivedSub?.cancel();
    _testingSub?.cancel();
    _reportSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchLabStatus() async {
    debugPrint('\n🔍 [LAB PROGRESS] Fetching status for bookingId=${widget.bookingId}');
    try {
      final url = Uri.parse(
          '${AppConstants.serverUrl}/api/bookings/${widget.bookingId}');
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      debugPrint('   HTTP ${res.statusCode}: ${res.body}');
      if (!mounted || res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final booking = data['booking'] as Map<String, dynamic>?;
      if (booking == null) return;
      final status = booking['collection_status'] as String? ?? '';
      debugPrint('   collection_status from DB: "$status"');
      if (!mounted) return;
      setState(() {
        if (status == 'sample_received') {
          _stage = 1;
          debugPrint('   → Stage: 1 (sample_received)');
        } else if (status == 'test_in_progress') {
          _stage = 2;
          debugPrint('   → Stage: 2 (test_in_progress)');
        } else if (status == 'report_ready') {
          _stage = 3;
          _reportUrl = booking['report_url'] as String?;
          debugPrint('   → Stage: 3 (report_ready) reportUrl=$_reportUrl');
        } else {
          debugPrint('   → Stage: 0 (collected — awaiting lab intake)');
        }
      });
    } catch (e) {
      debugPrint('   ❌ _fetchLabStatus error: $e');
    }
  }

  _LabStage _stageFor(int step) {
    if (_stage > step) return _LabStage.done;
    if (_stage == step) return _LabStage.active;
    return _LabStage.pending;
  }

  void _downloadReport() {
    if (_reportUrl == null) return;
    launchUrl(Uri.parse(_reportUrl!), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: AppColors.textPrimary),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text('Lab Progress',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary)),
          centerTitle: true,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Booking header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black12,
                        blurRadius: 8,
                        offset: Offset(0, 2))
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: const BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.science_outlined,
                          color: AppColors.brandGreen, size: 24),
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
                          Text('Booking #${widget.bookingId}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: _stage == 3
                            ? AppColors.brandGreenSurface
                            : const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        _stage == 3 ? 'Complete' : 'In Progress',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _stage == 3
                                ? AppColors.brandGreen
                                : const Color(0xFFE65100)),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              const Text('Sample Journey',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 16),

              // Pipeline steps
              const _PipelineStep(
                icon: Icons.check_circle_outline_rounded,
                title: 'Sample Collected',
                subtitle: 'Technician collected your sample',
                stage: _LabStage.done,
                isFirst: true,
              ),
              _PipelineStep(
                icon: Icons.local_shipping_outlined,
                title: 'Received at Lab',
                subtitle: 'Sample arrived at the processing lab',
                stage: _stageFor(1),
              ),
              _PipelineStep(
                icon: Icons.biotech_outlined,
                title: 'Tests in Progress',
                subtitle: 'Analysing your sample',
                stage: _stageFor(2),
              ),
              _PipelineStep(
                icon: Icons.description_outlined,
                title: 'Report Ready',
                subtitle: 'Your results are available',
                stage: _stageFor(3),
                isLast: true,
              ),

              const SizedBox(height: 28),

              // Download button — only when report is ready
              if (_stage == 3)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _reportUrl != null ? _downloadReport : null,
                    icon: const Icon(Icons.download_rounded, size: 20),
                    label: const Text('Download Report',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),

              if (_stage < 3)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF8E1),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFFFE082)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 18, color: Color(0xFFE65100)),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'You\'ll receive a notification when your report is ready. This page updates automatically.',
                          style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFE65100),
                              height: 1.4),
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

// ─── Single pipeline step ─────────────────────────────────────────────────────

class _PipelineStep extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final _LabStage stage;
  final bool isFirst;
  final bool isLast;

  const _PipelineStep({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.stage,
    this.isFirst = false,
    this.isLast = false,
  });

  Color get _iconBg {
    switch (stage) {
      case _LabStage.done:
        return AppColors.brandGreen;
      case _LabStage.active:
        return const Color(0xFF1565C0);
      case _LabStage.pending:
        return AppColors.divider;
    }
  }

  Color get _lineColor => stage == _LabStage.done
      ? AppColors.brandGreen
      : AppColors.divider;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Timeline column
          SizedBox(
            width: 32,
            child: Column(
              children: [
                if (!isFirst)
                  Expanded(
                    child: Center(
                      child: Container(
                          width: 2,
                          color: _lineColor),
                    ),
                  ),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                      color: _iconBg, shape: BoxShape.circle),
                  child: stage == _LabStage.active
                      ? const Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white)),
                        )
                      : Icon(
                          stage == _LabStage.done
                              ? Icons.check_rounded
                              : icon,
                          size: 16,
                          color: stage == _LabStage.pending
                              ? AppColors.textHint
                              : Colors.white),
                ),
                if (!isLast)
                  Expanded(
                    child: Center(
                      child: Container(
                          width: 2,
                          color: AppColors.divider),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          // Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: stage == _LabStage.pending
                              ? AppColors.textHint
                              : AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11,
                          color: stage == _LabStage.pending
                              ? AppColors.textHint
                              : AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
