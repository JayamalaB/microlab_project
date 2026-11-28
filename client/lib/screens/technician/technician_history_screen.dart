import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models/technician_booking.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/utils/app_messages.dart';
import 'package:microlab/widgets/skeleton_loader.dart';
import 'package:microlab/widgets/tech/tech_widgets.dart';

class TechnicianHistoryScreen extends StatefulWidget {
  final String mobile;
  final bool embedded;
  const TechnicianHistoryScreen(
      {super.key, required this.mobile, this.embedded = false});

  @override
  State<TechnicianHistoryScreen> createState() =>
      _TechnicianHistoryScreenState();
}

class _TechnicianHistoryScreenState extends State<TechnicianHistoryScreen> {
  List<TechnicianBooking> _history = [];
  bool _loading = true;
  String? _error;
  int _activeTab = 0; // 0 = Completed, 1 = Rescheduled, 2 = Cancelled
  DateTime? _dateFilter; // one exact day (header ≡ button); overrides _range
  String _range = 'All Time';

  static const _ranges = ['All Time', 'Today', 'This Week', 'Last Week', 'This Month', 'Last Month'];

  // "Completed" = Handed to Lab (server HISTORY_DONE_STATUSES); completed /
  // all_collected are finished jobs from older app builds.
  static const _completedStatuses = {
    'handed_to_lab', 'handed_to_lab_pending', 'completed', 'all_collected',
  };

  // Quick period filter. Weeks run Monday–Sunday.
  bool _inRange(DateTime d) {
    if (_range == 'All Time') return true;
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day   = DateTime(d.year, d.month, d.day);
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    switch (_range) {
      case 'Today':
        return day == today;
      case 'This Week':
        return !day.isBefore(weekStart) && !day.isAfter(today);
      case 'Last Week':
        final lastStart = weekStart.subtract(const Duration(days: 7));
        return !day.isBefore(lastStart) && day.isBefore(weekStart);
      case 'This Month':
        return d.year == now.year && d.month == now.month;
      case 'Last Month':
        final last = DateTime(now.year, now.month - 1); // handles January
        return d.year == last.year && d.month == last.month;
    }
    return true;
  }

  bool _matchesFilter(TechnicianBooking b) =>
      _dateFilter != null ? _sameDay(b.date, _dateFilter!) : _inRange(b.date);

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatDateShort(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${months[d.month]} ${d.year}';
  }

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

  Future<void> _loadHistory() async {
    setState(() { _loading = true; _error = null; });
    try {
      final prefs  = await SharedPreferences.getInstance();
      final techId = prefs.getInt('user_id') ?? 0;
      final token  = prefs.getString('auth_token') ?? '';

      debugPrint('🔵 [HISTORY] techId=$techId token=${token.isEmpty ? "EMPTY" : token.substring(0, token.length.clamp(0, 12))}...');

      if (techId == 0) {
        debugPrint('🔴 [HISTORY] techId=0 → session expired');
        setState(() { _loading = false; _error = 'Session expired. Please login again.'; });
        return;
      }

      final url = '${AppConstants.serverUrl}/api/technicians/$techId/history';
      debugPrint('🔵 [HISTORY] GET $url');

      final res = await ApiService.authClient.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      debugPrint('🔵 [HISTORY] status=${res.statusCode} bodyLen=${res.body.length}');
      debugPrint('🔵 [HISTORY] body=${res.body.substring(0, res.body.length.clamp(0, 300))}');

      if (!mounted) return;

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final rows = body['data'] as List<dynamic>? ?? [];
        debugPrint('✅ [HISTORY] rows=${rows.length}');

        setState(() {
          _history = rows.where((r) {
            // Same rule as the server and the Profile Summary: only finished
            // (handed to lab or later), rescheduled and cancelled jobs.
            // Anything else (an in-progress job from an older server) is not
            // history — it is on the Dashboard.
            final s = (r as Map<String, dynamic>)['collection_status'] as String? ?? '';
            return _completedStatuses.contains(s) || s == 'rescheduled' || s == 'cancelled';
          }).map((r) {
            final map    = r as Map<String, dynamic>;
            final rawStatus = map['collection_status'] as String? ?? '';
            final status = _completedStatuses.contains(rawStatus)
                ? 'Completed'
                : rawStatus == 'rescheduled'
                    ? 'Rescheduled'
                    : 'Cancelled';
            // Rescheduled rows: where the customer moved it to ("YYYY-MM-DD").
            final newDateStr = map['new_date'] as String?;
            final movedAt    = map['rescheduled_at'] as String?;
            final dateStr = (map['collection_date'] ?? map['assigned_at'] ?? map['collected_at']) as String?;
            // Parse as UTC then convert to local so IST dates don't shift back one day
            final date    = dateStr != null
                ? (DateTime.tryParse(dateStr)?.toLocal() ?? DateTime.now())
                : DateTime.now();

            return TechnicianBooking(
              id:                 'BK${map['booking_id'] ?? ''}',
              referenceNo:        map['reference_no']       as String?,
              collectionNotes:    map['collection_notes']   as String?,
              customerName:       (map['patient_name']       as String? ?? 'Patient').toUpperCase(),
              customerPhone:      map['patient_mobile']     as String? ?? '',
              address:            map['collection_address'] as String? ?? '',
              city:               map['city']               as String? ?? '',
              pincode:            map['postal_code']        as String? ?? '',
              date:               date,
              timeSlot:           (map['slot_time_formatted'] as String?) ??
                                  (map['slot_label']          as String?) ?? '—',
              testNames:          const [],
              mode:               'Home Collection',
              status:             status,
              serviceChargePaid:  0,
              testsTotal:         double.tryParse(map['amount_paid']?.toString() ?? '') ?? 0,
              assignedAt:         date,
              rescheduledToDate:  newDateStr != null ? DateTime.tryParse(newDateStr) : null,
              rescheduledToSlot:  map['new_slot_label'] as String?,
              rescheduledAt:      movedAt != null ? DateTime.tryParse(movedAt)?.toLocal() : null,
              rescheduledBy:      map['rescheduled_by'] as String?,
            );
          }).toList();
          _loading = false;
        });
      } else {
        debugPrint('🔴 [HISTORY] non-200 status=${res.statusCode} body=${res.body.substring(0, res.body.length.clamp(0, 200))}');
        setState(() { _loading = false; _error = 'We couldn\'t load your job history. Please try again.'; });
      }
    } catch (e) {
      debugPrint('🔴 [HISTORY] EXCEPTION type=${e.runtimeType} msg=$e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'We couldn\'t load your job history. ${AppMessages.friendlyError(e)}';
        });
      }
    }
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    var completed = _history.where((b) => b.status == 'Completed').toList();
    var rescheduled = _history.where((b) => b.status == 'Rescheduled').toList();
    var cancelled = _history.where((b) => b.status == 'Cancelled').toList();
    completed   = completed.where(_matchesFilter).toList();
    rescheduled = rescheduled.where(_matchesFilter).toList();
    cancelled   = cancelled.where(_matchesFilter).toList();
    // Tab order: 0 Completed · 1 Rescheduled · 2 Cancelled.
    final tabLists = [completed, rescheduled, cancelled];

    Widget body;
    if (_loading) {
      body = const _HistoryListSkeleton();
    } else if (_error != null) {
      body = TechErrorState(
        title: "Couldn't load history",
        message: _error!,
        retryLabel: 'Retry',
        onRetry: _loadHistory,
      );
    } else {
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: TechRadius.lgAll,
                    border: Border.all(color: TechColors.border),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: _HistoryTabButton(
                        label: 'Completed',
                        count: completed.length,
                        icon: Icons.check_circle_outline_rounded,
                        selected: _activeTab == 0,
                        onTap: () => setState(() => _activeTab = 0),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _HistoryTabButton(
                        label: 'Rescheduled',
                        count: rescheduled.length,
                        icon: Icons.update_rounded,
                        selected: _activeTab == 1,
                        onTap: () => setState(() => _activeTab = 1),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _HistoryTabButton(
                        label: 'Cancelled',
                        count: cancelled.length,
                        icon: Icons.cancel_outlined,
                        selected: _activeTab == 2,
                        onTap: () => setState(() => _activeTab = 2),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          // Period chips (same look as the customer My Bookings filter). A day
          // picked with the header ≡ button shows first as its own chip and
          // overrides the period until cleared; tapping a period clears it.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(children: [
              if (_dateFilter != null)
                _PeriodChip(
                  label: _formatDateShort(_dateFilter!),
                  icon: Icons.event_outlined,
                  selected: true,
                  trailingClose: true,
                  onTap: () => setState(() => _dateFilter = null),
                ),
              for (final r in _ranges)
                _PeriodChip(
                  label: r,
                  selected: _dateFilter == null && _range == r,
                  onTap: () => setState(() { _range = r; _dateFilter = null; }),
                ),
            ]),
          ),
          Expanded(
            child: ColoredBox(
              color: AppColors.background,
              child: _BookingList(
                bookings: tabLists[_activeTab.clamp(0, 2)],
                formatDate: _formatDate,
                onRefresh: _loadHistory,
              ),
            ),
          ),
        ],
      );
    }

    if (widget.embedded) {
      return Column(
        children: [
          Container(
            color: AppColors.brandGreen,
            padding: EdgeInsets.fromLTRB(
                16, MediaQuery.of(context).padding.top + 14, 16, 16),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.history_rounded, color: Colors.white, size: 19),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('History',
                          style: TextStyle(
                              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                      SizedBox(height: 2),
                      Text('Completed, Rescheduled & Cancelled',
                          style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                    ],
                  ),
                ),
                if (!_loading)
                  Material(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: TechRadius.mdAll,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _pickDateFilter,
                      child: Tooltip(
                        message: 'Filter by date',
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(Icons.filter_list_rounded,
                              color: _dateFilter != null ? Colors.white : Colors.white70, size: 22),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      );
    }

    return TechThemeScope(
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('History',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          if (!_loading)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
              tooltip: 'Reload history',
              onPressed: _loadHistory,
            ),
        ],
      ),
      body: body,
      ),
    );
  }
}

// ─── Booking List ─────────────────────────────────────────────────────────────

class _BookingList extends StatelessWidget {
  final List<TechnicianBooking> bookings;
  final String Function(DateTime) formatDate;
  final VoidCallback onRefresh;

  const _BookingList(
      {required this.bookings, required this.formatDate, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (bookings.isEmpty) {
      return RefreshIndicator(
        onRefresh: () async => onRefresh(),
        color: AppColors.brandGreen,
        child: const SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: 400,
            child: TechEmptyState(
              icon: Icons.history_outlined,
              title: 'No records yet',
              message: 'Pull down to refresh.',
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      color: AppColors.brandGreen,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(TechSpace.lg, TechSpace.lg, TechSpace.lg, 32),
        itemCount: bookings.length,
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => _TechHistoryDetailSheet(booking: bookings[i]),
          ),
          child: _HistoryCard(booking: bookings[i], formatDate: formatDate),
        ),
      ),
    );
  }
}

// ─── History Detail Sheet ─────────────────────────────────────────────────────

class _TechHistoryDetailSheet extends StatefulWidget {
  final TechnicianBooking booking;
  const _TechHistoryDetailSheet({required this.booking});

  @override
  State<_TechHistoryDetailSheet> createState() => _TechHistoryDetailSheetState();
}

class _TechHistoryDetailSheetState extends State<_TechHistoryDetailSheet> {
  List<Map<String, dynamic>> _items = [];
  bool _itemsLoading = true;
  // Sample-collection proof photo — same source (ip_booking_documents,
  // file_description='collection_proof') and API call as the live Manage
  // Booking screen's "Sample Collection Photo" section; this just displays
  // it read-only here for a past booking.
  String? _collectionProofUrl;
  bool _collectionProofLoading = true;

  TechnicianBooking get b => widget.booking;

  int get _bookingId {
    final rawId = b.id.startsWith('BK') ? b.id.substring(2) : b.id;
    return int.tryParse(rawId) ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _fetchItems();
    _fetchCollectionProof();
  }

  Future<void> _fetchItems() async {
    final bookingId = _bookingId;
    if (bookingId == 0) {
      if (mounted) setState(() => _itemsLoading = false);
      return;
    }
    try {
      final items = await ApiService.getBookingItems(bookingId);
      if (mounted) setState(() { _items = items; _itemsLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _itemsLoading = false);
    }
  }

  Future<void> _fetchCollectionProof() async {
    final bookingId = _bookingId;
    if (bookingId == 0) {
      if (mounted) setState(() => _collectionProofLoading = false);
      return;
    }
    try {
      final doc = await ApiService.getCollectionProofPhoto(bookingId);
      if (mounted) {
        setState(() {
          _collectionProofUrl     = doc?['file_path'] as String?;
          _collectionProofLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _collectionProofLoading = false);
    }
  }

  void _viewCollectionProof() {
    final url = _collectionProofUrl;
    if (url == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Collection Photo', style: TextStyle(color: Colors.white, fontSize: 14)),
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5.0,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : const CircularProgressIndicator(color: Colors.white),
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image, color: Colors.white54, size: 48),
          ),
        ),
      ),
    )));
  }

  String _fmt(DateTime d) {
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const w = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${w[d.weekday - 1]}, ${d.day} ${m[d.month]} ${d.year}';
  }

  // "15 Nov, 09:12 PM"
  String _fmtStamp(DateTime d) {
    const m = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final h12 = ((d.hour + 11) % 12) + 1;
    final mm  = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${m[d.month]}, ${h12.toString().padLeft(2, '0')}:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  double get _testsTotal => _items.isEmpty
      ? b.testsTotal
      : _items.fold(0.0, (s, i) => s + (double.tryParse(i['price']?.toString() ?? '0') ?? 0));

  @override
  Widget build(BuildContext context) {
    final isCompleted = b.status == 'Completed';
    final isRescheduled = b.status == 'Rescheduled';
    final movedTo = _movedToLabel(b, _fmt);
    final when = b.timeSlot.isNotEmpty && b.timeSlot != '—' ? '${_fmt(b.date)} · ${b.timeSlot}' : _fmt(b.date);

    return TechThemeScope(
      child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: TechRadius.sheetTop,
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
        maxWidth: TechSize.sheetMaxWidth,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          const TechSheetHandleBar(),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(TechSpace.gutter, 0, TechSpace.gutter, TechSpace.md),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Booking Details', style: TechText.sheetTitle),
                  if (b.referenceNo != null)
                    Text(b.referenceNo!, style: TechText.bodySecondary),
                ]),
              ),
              TechStatusChip(
                label: b.status,
                icon: isCompleted
                    ? Icons.check_rounded
                    : isRescheduled ? Icons.update_rounded : Icons.close_rounded,
                tone: isCompleted
                    ? TechTone.success
                    : isRescheduled ? TechTone.info : TechTone.error,
              ),
            ]),
          ),
          const Divider(height: 1),

          // Scrollable content
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(TechSpace.gutter, TechSpace.lg, TechSpace.gutter,
                  MediaQuery.of(context).padding.bottom + 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // Appointment
                  _HDetailSection(title: 'Appointment', rows: [
                    _HDetailRow(Icons.person_outline, 'Customer', b.customerName),
                    if (isRescheduled) ...[
                      // The appointment this technician had, and where it went.
                      _HDetailRow(Icons.event_busy_outlined, 'Was', when),
                      if (movedTo != null)
                        _HDetailRow(Icons.arrow_forward_rounded, 'Moved to', movedTo),
                      if (b.rescheduledAt != null)
                        _HDetailRow(Icons.update_rounded, 'Rescheduled on', _fmtStamp(b.rescheduledAt!)),
                      if (_rescheduledByLabel(b).isNotEmpty)
                        _HDetailRow(Icons.person_pin_outlined, 'Rescheduled',
                            b.rescheduledBy == 'technician' ? 'By you' : 'By the customer'),
                    ] else ...[
                      _HDetailRow(Icons.event_outlined, 'Date', _fmt(b.date)),
                      _HDetailRow(Icons.schedule_outlined, 'Time', b.timeSlot),
                    ],
                    if (b.address.isNotEmpty)
                      _HDetailRow(Icons.home_outlined, 'Collection Address', b.address),
                    if (b.city.isNotEmpty || b.pincode.isNotEmpty)
                      _HDetailRow(Icons.location_on_outlined, 'Area',
                          [b.city, b.pincode].where((s) => s.isNotEmpty).join(', ')),
                  ]),

                  const SizedBox(height: 16),

                  // Tests & Packages
                  Text(
                    'Tests & Packages${_itemsLoading ? '' : ' (${_items.length})'}',
                    style: TechText.sectionTitle,
                  ),
                  const SizedBox(height: TechSpace.sm),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: TechRadius.mdAll,
                      border: Border.all(color: TechColors.border),
                    ),
                    child: _itemsLoading
                        ? const TechLoadingState()
                        : _items.isEmpty
                            ? const Text('No test details available', style: TechText.bodySecondary)
                            : Column(
                                children: _items.map((item) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: Row(children: [
                                    const Icon(Icons.science_outlined,
                                        size: 18, color: TechColors.brand),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(item['name']?.toString() ?? '',
                                          style: TechText.body),
                                    ),
                                    Text(
                                      '₹${(double.tryParse(item['price']?.toString() ?? '0') ?? 0).toInt()}',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: TechColors.textPrimary),
                                    ),
                                  ]),
                                )).toList(),
                              ),
                  ),

                  const SizedBox(height: 16),

                  // Collection Photo — read-only view of the proof photo
                  // captured (if any) during sample collection for this
                  // booking. Same data source as the live Manage Booking
                  // screen's "Sample Collection Photo" section.
                  const Text('Collection Photo', style: TechText.sectionTitle),
                  const SizedBox(height: TechSpace.sm),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: TechRadius.mdAll,
                      border: Border.all(color: TechColors.border),
                    ),
                    child: _collectionProofLoading
                        ? const TechLoadingState()
                        : _collectionProofUrl == null
                            ? const Text('No collection photo captured', style: TechText.bodySecondary)
                            : InkWell(
                                onTap: _viewCollectionProof,
                                borderRadius: TechRadius.smAll,
                                child: Row(children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      _collectionProofUrl!,
                                      width: 56, height: 56, fit: BoxFit.cover,
                                      loadingBuilder: (_, child, progress) => progress == null
                                          ? child
                                          : const SizedBox(
                                              width: 56, height: 56,
                                              child: Center(child: CircularProgressIndicator(
                                                  strokeWidth: 2, color: AppColors.brandGreen)),
                                            ),
                                      errorBuilder: (_, __, ___) => const SizedBox(
                                          width: 56, height: 56,
                                          child: Icon(Icons.broken_image, color: AppColors.textHint)),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Text('Proof photo captured — tap to view', style: TechText.body),
                                  ),
                                  const Icon(Icons.chevron_right_rounded, size: 22, color: TechColors.textHint),
                                ]),
                              ),
                  ),

                  const SizedBox(height: 16),

                  // Payment
                  _HDetailSection(title: 'Payment', rows: [
                    _HDetailRow(Icons.receipt_outlined, 'Tests Total',
                        '₹${_testsTotal.toInt()}'),
                    if (b.serviceChargePaid > 0)
                      _HDetailRow(Icons.delivery_dining_outlined, 'Service Charge',
                          '₹${b.serviceChargePaid.toInt()}'),
                    _HDetailRow(
                      Icons.check_circle_outline,
                      isCompleted ? 'Collected' : 'Amount',
                      '₹${b.testsTotal.toInt()}',
                      valueBold: true,
                      valueColor: isCompleted ? AppColors.brandGreen : null,
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

// ─── Skeleton loading state — shown while _loadHistory() is in flight ───────

class _HistoryListSkeleton extends StatelessWidget {
  const _HistoryListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      physics: const NeverScrollableScrollPhysics(),
      children: List.generate(4, (_) => const _HistoryCardSkeleton()),
    );
  }
}

class _HistoryCardSkeleton extends StatelessWidget {
  const _HistoryCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: TechSpace.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: TechRadius.lgAll,
        border: Border.all(color: TechColors.border),
      ),
      child: SkeletonShimmer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status strip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: AppColors.divider.withValues(alpha: 0.3),
              child: Row(
                children: [
                  SkeletonBox(width: 70, height: 11, borderRadius: BorderRadius.circular(4)),
                  const Spacer(),
                  SkeletonBox(width: 50, height: 10, borderRadius: BorderRadius.circular(4)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 140, height: 14, borderRadius: BorderRadius.circular(4)),
                  const SizedBox(height: 10),
                  SkeletonBox(width: 100, height: 11, borderRadius: BorderRadius.circular(4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Status look (card + details sheet) ──────────────────────────────────────

const _rescheduledBlue = Color(0xFF1565C0);

Color _historyStatusColor(String status) => switch (status) {
      'Completed'   => TechColors.success,
      'Rescheduled' => _rescheduledBlue,
      _             => TechColors.error,
    };

IconData _historyStatusIcon(String status) => switch (status) {
      'Completed'   => Icons.check_circle_outline,
      'Rescheduled' => Icons.update_rounded,
      _             => Icons.cancel_outlined,
    };

/// "by you" / "by customer" for a rescheduled row ('' when unknown).
String _rescheduledByLabel(TechnicianBooking b) => switch (b.rescheduledBy) {
      'technician' => 'by you',
      'customer'   => 'by customer',
      _            => '',
    };

/// "Wed, 18 Nov 2026 · 10:00 AM" for a rescheduled row, or null.
String? _movedToLabel(TechnicianBooking b, String Function(DateTime) formatDate) {
  final d = b.rescheduledToDate;
  if (d == null) return null;
  final slot = b.rescheduledToSlot?.trim() ?? '';
  return slot.isEmpty ? formatDate(d) : '${formatDate(d)} · $slot';
}

// ─── History Card ─────────────────────────────────────────────────────────────

class _HistoryCard extends StatelessWidget {
  final TechnicianBooking booking;
  final String Function(DateTime) formatDate;

  const _HistoryCard({required this.booking, required this.formatDate});

  @override
  Widget build(BuildContext context) {
    final isCompleted  = booking.status == 'Completed';
    final isRescheduled = booking.status == 'Rescheduled';
    final statusColor  = _historyStatusColor(booking.status);
    final totalCollected = booking.serviceChargePaid + booking.testsTotal;
    final movedTo = _movedToLabel(booking, formatDate);

    return Container(
      margin: const EdgeInsets.only(bottom: TechSpace.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: TechRadius.lgAll,
        border: Border.all(color: TechColors.border),
        boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: TechRadius.lgAll,
        child: Column(
          children: [
            // Status strip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: statusColor.withValues(alpha: 0.07),
              child: Row(children: [
                Icon(_historyStatusIcon(booking.status), size: 16, color: statusColor),
                const SizedBox(width: 6),
                Text(
                    isRescheduled && _rescheduledByLabel(booking).isNotEmpty
                        ? '${booking.status} ${_rescheduledByLabel(booking)}'
                        : booking.status,
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: statusColor)),
                const Spacer(),
                if (booking.referenceNo != null)
                  Text(booking.referenceNo!, style: TechText.caption),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.person_outline_rounded, color: AppColors.brandGreen, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Name
                        Text(booking.customerName,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700, color: TechColors.textPrimary)),
                        const SizedBox(height: 8),

                        // Date + time
                        Row(children: [
                          const Icon(Icons.event_outlined, size: 12, color: AppColors.textHint),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              booking.timeSlot.isNotEmpty && booking.timeSlot != '—'
                                  ? '${formatDate(booking.date)} · ${booking.timeSlot}'
                                  : formatDate(booking.date),
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 6),

                        // Address
                        if (booking.address.isNotEmpty)
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Icon(Icons.location_on_outlined, size: 12, color: AppColors.textHint),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                [booking.address, booking.city]
                                    .where((s) => s.isNotEmpty).join(', '),
                                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ]),

                        // Rescheduled: where the customer moved it to.
                        if (isRescheduled && movedTo != null) ...[
                          const SizedBox(height: 6),
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Icon(Icons.arrow_forward_rounded, size: 13, color: statusColor),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text('Moved to $movedTo',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w600, color: statusColor)),
                            ),
                          ]),
                        ],

                        // Amount collected
                        if (isCompleted && totalCollected > 0) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            const Icon(Icons.payments_outlined, size: 13, color: AppColors.brandGreen),
                            const SizedBox(width: 5),
                            Text('Collected: ₹${totalCollected.toInt()}',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.brandGreen, fontWeight: FontWeight.w600)),
                          ]),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.textHint, size: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Period filter chip ──────────────────────────────────────────────────────

class _PeriodChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool trailingClose;

  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.trailingClose = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? TechColors.brand : TechColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: trailingClose ? 'Clear date $label' : label,
        excludeSemantics: true,
        child: Material(
          color: selected ? TechColors.brandSurface : Colors.white,
          shape: StadiumBorder(side: BorderSide(color: selected ? TechColors.brand : TechColors.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 36),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: fg),
                    const SizedBox(width: 5),
                  ],
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: fg)),
                  if (trailingClose) ...[
                    const SizedBox(width: 5),
                    Icon(Icons.close_rounded, size: 15, color: fg),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── History segmented tab button ────────────────────────────────────────────

// Three tabs share the row, so the count sits on its own line under the
// label and the whole thing scales down (never clips) on narrow phones.
class _HistoryTabButton extends StatelessWidget {
  final String label;
  final int count;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _HistoryTabButton({
    required this.label,
    required this.count,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : TechColors.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label, $count',
      excludeSemantics: true,
      child: Material(
        color: selected ? TechColors.brand : Colors.transparent,
        borderRadius: TechRadius.mdAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 16, color: fg),
                  const SizedBox(width: 4),
                  Text('$count',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: fg)),
                ]),
                const SizedBox(height: 1),
                Text(label,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Detail sheet helpers ─────────────────────────────────────────────────────

class _HDetailSection extends StatelessWidget {
  final String title;
  final List<_HDetailRow> rows;
  const _HDetailSection({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TechText.sectionTitle),
        const SizedBox(height: TechSpace.sm),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: TechRadius.mdAll,
            border: Border.all(color: TechColors.border),
          ),
          child: Column(
            children: rows.map((r) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(r.icon, size: 18, color: TechColors.textHint),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Text(r.label, style: TechText.bodySecondary),
                ),
                Expanded(
                  flex: 3,
                  child: Text(r.value,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: r.valueBold ? FontWeight.w600 : FontWeight.w500,
                          color: r.valueColor ?? AppColors.textPrimary),
                      textAlign: TextAlign.end),
                ),
              ]),
            )).toList(),
          ),
        ),
      ],
    );
  }
}

class _HDetailRow {
  final IconData icon;
  final String label;
  final String value;
  final bool valueBold;
  final Color? valueColor;
  const _HDetailRow(this.icon, this.label, this.value,
      {this.valueBold = false, this.valueColor});
}
