import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/customer_refresh_notifier.dart';
import 'package:microlab/services/socket_service.dart';

// ─── Reports screen ───────────────────────────────────────────────────────────

class ReportsScreen extends StatefulWidget {
  final bool embedded;
  final ValueNotifier<int>? refreshTrigger;
  const ReportsScreen({super.key, this.embedded = false, this.refreshTrigger});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> with WidgetsBindingObserver {
  List<BookingModel> _bookings = [];
  bool _isLoading = true;
  String? _error;

  StreamSubscription<ReportReadyEvent>? _reportSub;
  StreamSubscription<bool>? _connectedSub;

  @override
  void initState() {
    super.initState();
    _loadReports();
    widget.refreshTrigger?.addListener(_loadReports);
    WidgetsBinding.instance.addObserver(this);
    CustomerRefreshNotifier.instance.addListener(_onFcmRefresh);
    _reportSub    = SocketService.instance.onReportReady.listen((_) => _loadReports());
    _connectedSub = SocketService.instance.onConnected.listen((_) => _loadReports());
  }

  @override
  void dispose() {
    widget.refreshTrigger?.removeListener(_loadReports);
    WidgetsBinding.instance.removeObserver(this);
    CustomerRefreshNotifier.instance.removeListener(_onFcmRefresh);
    _reportSub?.cancel();
    _connectedSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadReports();
  }

  void _onFcmRefresh() {
    if (CustomerRefreshNotifier.instance.lastEvent == CustomerRefreshEvent.reportReady) {
      _loadReports();
    }
  }

  Future<void> _loadReports() async {
    try {
      final raw = await ApiService.getMyBookings();
      final reportable = raw.where((b) =>
        b['report_url'] != null ||
        ((b['released_results_count'] as num?) ?? 0) > 0
      ).toList();
      final bookings = reportable.map(_fromApi).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      if (mounted) setState(() { _bookings = bookings; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _isLoading = false; });
    }
  }

  static BookingModel _fromApi(Map<String, dynamic> b) {
    final rawItems = (b['test_items'] as String? ?? '')
        .split('|||').where((s) => s.isNotEmpty).toList();
    final tests = rawItems.map((raw) {
      final parts = raw.split(':::');
      final productId = parts.isNotEmpty ? parts[0] : '0';
      final name      = parts.length > 1 ? parts[1] : 'Unknown';
      final price     = parts.length > 2 ? (double.tryParse(parts[2]) ?? 0.0) : 0.0;
      final type      = parts.length > 3 ? parts[3] : 'test';
      return TestModel(
        id: productId, name: name,
        type: type == 'package' ? 'package' : 'single',
        category: '', description: '', hasOffer: false,
        originalPrice: price, finalPrice: price,
        docRequired: false, reportStatus: '',
      );
    }).toList();
    final total      = double.tryParse(b['total_amount']?.toString() ?? '') ?? 0.0;
    final itemsTotal = double.tryParse(b['items_total']?.toString() ?? '') ?? total;
    final amountPaid = double.tryParse(b['amount_paid']?.toString() ?? '') ?? 0.0;
    final bookingType = b['booking_type'] as String? ?? 'lab_visit';
    final mode = bookingType == 'home_collection' ? 'Home Collection' : 'Lab Visit';
    DateTime date;
    final collDate = b['collection_date'] as String?;
    if (collDate != null && collDate.isNotEmpty) {
      date = DateTime.tryParse(collDate) ?? DateTime.now();
    } else {
      date = DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime.now();
    }
    final member = MemberModel(
      id: b['patient_id']?.toString() ?? '0',
      name: b['patient_name'] as String? ?? 'Patient',
      mobile: b['patient_mobile'] as String? ?? '',
      gender: '', location: '', address: '',
    );
    final slotLabel = (b['slot_label'] as String?) ?? (b['slot_time_formatted'] as String?);
    return BookingModel(
      id:           b['booking_ref'] as String? ?? b['booking_id_num'].toString(),
      bookingIdNum: b['booking_id_num'] != null ? (b['booking_id_num'] as num).toInt() : null,
      member: member, tests: tests, mode: mode,
      address:      b['collection_address'] as String?,
      pincode:      b['collection_pincode']?.toString(),
      city:         b['collection_city'] as String?,
      date: date, timeSlot: slotLabel ?? 'Not specified',
      paymentType:  amountPaid >= total && total > 0 ? 'full' : 'pay_later',
      serviceCharge: (total - itemsTotal).clamp(0, double.infinity),
      testsTotal: itemsTotal, grandTotal: total, paidAmount: amountPaid,
      status:       _mapStatus(b['booking_status'] as String? ?? 'pending'),
      createdAt:    DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime.now(),
      docRequired: false, docVerified: false,
      reportUrl:    b['report_url'] as String?,
    );
  }

  static String _mapStatus(String raw) {
    switch (raw) {
      case 'scheduled':  return 'Scheduled';
      case 'confirmed':  return 'Confirmed';
      case 'collected':  return 'Sample Collected';
      case 'completed':  return 'Completed';
      case 'cancelled':  return 'Cancelled';
      default:           return 'Pending';
    }
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  void _openReport(BuildContext context, BookingModel booking) {
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => _ReportDetailPage(booking: booking),
    ));
  }

  Widget _buildBody(BuildContext context, List<BookingModel> reports) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.red),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(
                fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                setState(() { _isLoading = true; _error = null; });
                _loadReports();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (reports.isEmpty) {
      return RefreshIndicator(
        onRefresh: () async => _loadReports(),
        color: AppColors.brandGreen,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.receipt_long_outlined, size: 48, color: AppColors.brandGreenLight),
                  SizedBox(height: 16),
                  Text('No reports yet',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  SizedBox(height: 8),
                  Text('Reports for completed tests appear here.',
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _loadReports(),
      color: AppColors.brandGreen,
      child: ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: reports.length,
      itemBuilder: (_, i) {
        final b = reports[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: AppColors.brandGreenSurface,
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline,
                          size: 14, color: AppColors.brandGreen),
                      const SizedBox(width: 6),
                      const Text('Report Ready',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.brandGreen)),
                      const Spacer(),
                      Text(b.id,
                          style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(b.member.name,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary)),
                          ),
                          Text(_formatDate(b.date),
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.textSecondary)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6, runSpacing: 4,
                        children: b.tests.map((t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: t.type == 'package'
                                ? AppColors.brandGreenSurface
                                : const Color(0xFFEEF4FB),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(t.name,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: t.type == 'package'
                                      ? AppColors.brandGreen
                                      : const Color(0xFF1565C0))),
                        )).toList(),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _openReport(context, b),
                          icon: const Icon(Icons.description_outlined, size: 16),
                          label: const Text('View Reports'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.brandGreen,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        children: [
          Container(
            color: AppColors.brandGreen,
            padding: EdgeInsets.fromLTRB(
                16, MediaQuery.of(context).padding.top + 14, 16, 14),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: Text('Reports & Results',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600)),
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: AppColors.background,
              child: _buildBody(context, _bookings),
            ),
          ),
        ],
      );
    }
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Reports & Results',
            style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
      ),
      body: _buildBody(context, _bookings),
    );
  }
}

// ─── Report detail page ───────────────────────────────────────────────────────

class _ReportDetailPage extends StatefulWidget {
  final BookingModel booking;
  const _ReportDetailPage({required this.booking});

  @override
  State<_ReportDetailPage> createState() => _ReportDetailPageState();
}

class _ReportDetailPageState extends State<_ReportDetailPage> {
  List<Map<String, dynamic>> _results = [];
  bool _resultsLoading = true;
  // per-report busy: index -> 'share' | 'download' | null
  final Map<int, String?> _busy = {};

  @override
  void initState() {
    super.initState();
    _loadResults();
  }

  Future<void> _loadResults({bool silent = false}) async {
    final id = widget.booking.bookingIdNum;
    if (id == null) { setState(() => _resultsLoading = false); return; }
    if (!silent) setState(() => _resultsLoading = true);
    try {
      final data = await ApiService.getBookingResults(id);
      if (mounted) {
        setState(() {
          _results = data.where((r) => r['report_url'] != null).toList();
          _resultsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _resultsLoading = false);
    }
  }

  BookingModel get booking => widget.booking;

  String _fmt(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  String _fmtShort(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${months[d.month]} ${d.year}';
  }

  int _age(DateTime dob) {
    final now = DateTime.now();
    int age = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) { age--; }
    return age;
  }

  Future<Uint8List> _fetchBytes(int resultId) =>
      ApiService.getReportProxy(booking.bookingIdNum!, resultId);

  Future<void> _shareReport(int i, Map<String, dynamic> r) async {
    if (_busy[i] != null) return;
    setState(() => _busy[i] = 'share');
    try {
      final resultId = r['result_id'] as int;
      final name = '${(r['test_name'] as String? ?? 'Report').replaceAll(' ', '_')}_${booking.id}.pdf';
      final bytes = await _fetchBytes(resultId);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile.fromData(bytes, mimeType: 'application/pdf', name: name)],
        subject: 'MicroLab Report – ${booking.id}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not share: $e'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } finally {
      if (mounted) setState(() => _busy[i] = null);
    }
  }

  Future<void> _downloadReport(int i, Map<String, dynamic> r) async {
    if (_busy[i] != null) return;
    setState(() => _busy[i] = 'download');
    try {
      final resultId = r['result_id'] as int;
      final name = '${(r['test_name'] as String? ?? 'Report').replaceAll(' ', '_')}_${booking.id}.pdf';
      final bytes = await _fetchBytes(resultId);
      if (!mounted) return;
      if (kIsWeb) {
        await Printing.sharePdf(bytes: bytes, filename: name);
      } else {
        final dir  = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(bytes);
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not download: $e'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } finally {
      if (mounted) setState(() => _busy[i] = null);
    }
  }

  Widget _buildReportCard(int i, Map<String, dynamic> r) {
    final name        = r['test_name'] as String? ?? 'Report ${i + 1}';
    final releasedAt  = r['released_at'] as String?;
    final releasedDate = releasedAt != null ? DateTime.tryParse(releasedAt) : null;
    final isBusy      = _busy[i] != null;
    final busyAction  = _busy[i];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.brandGreenSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.description_outlined,
                    size: 18, color: AppColors.brandGreen),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                    if (releasedDate != null) ...[
                      const SizedBox(height: 2),
                      Text('Released: ${_fmtShort(releasedDate)}',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary)),
                    ],
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: isBusy ? null : () => _shareReport(i, r),
                  icon: busyAction == 'share'
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.share_outlined, size: 15),
                  label: const Text('Share'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.brandGreen,
                    side: const BorderSide(
                        color: AppColors.brandGreen, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: isBusy ? null : () => _downloadReport(i, r),
                  icon: busyAction == 'download'
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.download_outlined, size: 15),
                  label: const Text('Download'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    disabledBackgroundColor:
                        AppColors.brandGreen.withValues(alpha: 0.5),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = booking.member;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Lab Report',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            Text(booking.id,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () => _loadResults(silent: true),
        color: AppColors.brandGreen,
        child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Lab header card ─────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.brandGreen, Color(0xFF2E7D32)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.biotech_rounded,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('MicroLab Diagnostics',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700)),
                        Text('NABL Accredited · ISO 15189:2022',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ]),
                  const SizedBox(height: 14),
                  const Divider(color: Colors.white24, height: 1),
                  const SizedBox(height: 12),
                  Row(children: [
                    _ReportMeta(label: 'Report ID', value: booking.id),
                    const SizedBox(width: 20),
                    _ReportMeta(label: 'Collected', value: _fmtShort(booking.date)),
                    if (booking.reportReadyDate != null) ...[
                      const SizedBox(width: 20),
                      _ReportMeta(
                          label: 'Reported',
                          value: _fmtShort(booking.reportReadyDate!)),
                    ],
                  ]),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Patient info card ───────────────────────
            _SectionCard(
              title: 'Patient Information',
              icon: Icons.person_outline_rounded,
              child: Column(
                children: [
                  _ReportRow(label: 'Name', value: m.name, bold: true),
                  _ReportRow(
                      label: 'Gender / Age',
                      value: [
                        if (m.gender.isNotEmpty) m.gender,
                        if (m.dob != null) '${_age(m.dob!)} yrs',
                      ].join(' · ')),
                  if (m.dob != null)
                    _ReportRow(label: 'Date of Birth', value: _fmtShort(m.dob!)),
                  _ReportRow(label: 'Mobile', value: '+91 ${m.mobile}'),
                  if (m.address.isNotEmpty)
                    _ReportRow(label: 'Address', value: m.address, last: true),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── Collection info card ────────────────────
            _SectionCard(
              title: 'Collection Details',
              icon: Icons.local_hospital_outlined,
              child: Column(
                children: [
                  _ReportRow(label: 'Mode', value: booking.mode),
                  _ReportRow(
                      label: 'Date & Time',
                      value: '${_fmt(booking.date)}  ·  ${booking.timeSlot}'),
                  _ReportRow(
                      label: 'Tests',
                      value: booking.tests.map((t) => t.name).join(', '),
                      last: true),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Reports section ─────────────────────────
            const Text('Reports',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 10),

            if (_resultsLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_results.isEmpty)
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.divider),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.hourglass_empty_rounded,
                        size: 32, color: AppColors.textHint),
                    SizedBox(height: 8),
                    Text('Reports not available yet',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.textSecondary)),
                  ],
                ),
              )
            else
              Column(
                children: _results.asMap().entries
                    .map((e) => _buildReportCard(e.key, e.value))
                    .toList(),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

// ─── Shared detail widgets ────────────────────────────────────────────────────

class _ReportMeta extends StatelessWidget {
  final String label;
  final String value;
  const _ReportMeta({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 9, color: Colors.white60, letterSpacing: 0.3)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.white)),
        ],
      );
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _SectionCard(
      {required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Row(children: [
                Icon(icon, size: 14, color: AppColors.brandGreen),
                const SizedBox(width: 6),
                Text(title,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.brandGreen)),
              ]),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1, color: AppColors.divider),
            Padding(padding: const EdgeInsets.all(14), child: child),
          ],
        ),
      );
}

class _ReportRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final bool last;
  const _ReportRow(
      {required this.label,
      required this.value,
      this.bold = false,
      this.last = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: last ? 0 : 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ),
            const Text(':  ',
                style: TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            Expanded(
              child: Text(value,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight:
                          bold ? FontWeight.w700 : FontWeight.w500,
                      color: AppColors.textPrimary)),
            ),
          ],
        ),
      );
}
