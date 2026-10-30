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
import 'package:microlab/utils/app_messages.dart';

// ─── Reports screen ───────────────────────────────────────────────────────────

class ReportsScreen extends StatefulWidget {
  final bool embedded;
  final ValueNotifier<int>? refreshTrigger;
  final VoidCallback? onViewBookings;
  const ReportsScreen({super.key, this.embedded = false, this.refreshTrigger, this.onViewBookings});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> with WidgetsBindingObserver {
  List<BookingModel> _bookings = [];
  bool _isLoading = true;
  String? _error;
  DateTime? _dateFilter;

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
        ((b['released_results_count'] as num?) ?? 0) > 0 ||
        ((b['asmx_report_count'] as num?) ?? 0) > 0
      ).toList();
      final bookings = reportable.map(_fromApi).toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      if (mounted) setState(() { _bookings = bookings; _isLoading = false; });
    } catch (e) {
      debugPrint('[Reports] load failed: $e');
      if (mounted) {
        setState(() {
          _error = 'We couldn\'t load your reports. ${AppMessages.friendlyError(e)}';
          _isLoading = false;
        });
      }
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
    final additionalCharge = double.tryParse(b['additional_charge_amount']?.toString() ?? '') ?? 0.0;
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
      serviceCharge: (total - itemsTotal - additionalCharge).clamp(0, double.infinity),
      additionalCharge: additionalCharge,
      additionalChargeReason: b['additional_charge_reason'] as String?,
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

  String _formatDateShort(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${months[d.month]} ${d.year}';
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _pickDateFilter() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dateFilter ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      helpText: 'FILTER BY DATE',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.brandGreen, onPrimary: Colors.white, surface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _dateFilter = picked);
  }

  Widget _buildFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          if (_dateFilter != null)
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _dateFilter = null),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreenSurface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.event_outlined, size: 14, color: AppColors.brandGreen),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(_formatDateShort(_dateFilter!),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.close_rounded, size: 15, color: AppColors.brandGreen),
                    ],
                  ),
                ),
              ),
            )
          else
            const Spacer(),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _pickDateFilter,
            child: Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.divider),
              ),
              child: Icon(Icons.filter_list_rounded,
                  size: 19,
                  color: _dateFilter != null ? AppColors.brandGreen : AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoMatchState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.event_busy_rounded, size: 40, color: AppColors.textHint),
            const SizedBox(height: 14),
            const Text('No reports for this date',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _dateFilter = null),
              child: const Text('Clear filter', style: TextStyle(color: AppColors.brandGreen)),
            ),
          ],
        ),
      ),
    );
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
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 88,
                      height: 88,
                      decoration: const BoxDecoration(
                          color: AppColors.brandGreenSurface, shape: BoxShape.circle),
                      child: const Icon(Icons.receipt_long_outlined,
                          size: 38, color: AppColors.brandGreen),
                    ),
                    const SizedBox(height: 18),
                    const Text('No reports yet',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    const SizedBox(height: 8),
                    const Text('Reports for completed tests will appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.4)),
                    const SizedBox(height: 4),
                    const Text('Your test results will be available here once processed.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: AppColors.textHint, height: 1.4)),
                    const SizedBox(height: 22),
                    OutlinedButton.icon(
                      onPressed: widget.onViewBookings,
                      icon: const Icon(Icons.calendar_month_outlined, size: 17),
                      label: const Text('View My Bookings'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.brandGreen,
                        side: const BorderSide(color: AppColors.brandGreen, width: 1.4),
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final filtered = _dateFilter == null
        ? reports
        : reports.where((b) => _sameDay(b.date, _dateFilter!)).toList();

    return RefreshIndicator(
      onRefresh: () async => _loadReports(),
      color: AppColors.brandGreen,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildFilterRow()),
          if (filtered.isEmpty)
            SliverFillRemaining(hasScrollBody: false, child: _buildNoMatchState())
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => _buildReportCard(context, filtered[i]),
                  childCount: filtered.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildReportCard(BuildContext context, BookingModel b) {
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
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        children: [
          Container(
            color: AppColors.brandGreen,
            width: double.infinity,
            height: MediaQuery.of(context).padding.top + 56,
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            child: const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('Reports & Results',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700)),
              ),
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
          _results = data.where((r) =>
            r['report_url'] != null || r['source'] == 'asmx'
          ).toList();
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
      debugPrint('[Reports] share failed: $e');
      if (!mounted) return;
      AppMessages.error(context, 'We couldn\'t share the report. ${AppMessages.friendlyError(e)}');
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
      debugPrint('[Reports] download failed: $e');
      if (!mounted) return;
      AppMessages.error(context, 'We couldn\'t download the report. ${AppMessages.friendlyError(e)}');
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
                  colors: [AppColors.brandGreen, AppColors.brandGreenMid],
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
