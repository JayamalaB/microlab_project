import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models/technician_booking.dart';
import 'package:microlab/services/api_service.dart';

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

  @override
  void initState() {
    super.initState();
    _loadHistory();
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

      final res = await http.get(
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
          _history = rows.map((r) {
            final map    = r as Map<String, dynamic>;
            final rawStatus = map['collection_status'] as String? ?? '';
            const completedStatuses = {
              'completed', 'all_collected', 'collected',
              'handed_to_lab', 'handed_to_lab_pending', 'sample_collected', 'collection_started',
            };
            final status = completedStatuses.contains(rawStatus)
                ? 'Completed'
                : 'Cancelled';
            final dateStr = (map['collection_date'] ?? map['assigned_at'] ?? map['collected_at']) as String?;
            // Parse as UTC then convert to local so IST dates don't shift back one day
            final date    = dateStr != null
                ? (DateTime.tryParse(dateStr)?.toLocal() ?? DateTime.now())
                : DateTime.now();

            return TechnicianBooking(
              id:                 'BK${map['booking_id'] ?? ''}',
              customerName:       map['patient_name']       as String? ?? 'Patient',
              customerPhone:      map['patient_mobile']     as String? ?? '',
              address:            map['collection_address'] as String? ?? '',
              city:               map['city']               as String? ?? '',
              pincode:            map['postal_code']        as String? ?? '',
              date:               date,
              timeSlot:           (map['slot_time_formatted'] as String?) ??
                                  (map['slot_label']          as String?) ?? '—',
              testNames:          const ['Home Collection'],
              mode:               'Home Collection',
              status:             status,
              serviceChargePaid:  0,
              testsTotal:         double.tryParse(map['amount_paid']?.toString() ?? '') ?? 0,
              assignedAt:         date,
            );
          }).toList();
          _loading = false;
        });
      } else {
        debugPrint('🔴 [HISTORY] non-200 status=${res.statusCode} body=${res.body.substring(0, res.body.length.clamp(0, 200))}');
        setState(() { _loading = false; _error = 'Failed to load history. (${res.statusCode})'; });
      }
    } catch (e) {
      debugPrint('🔴 [HISTORY] EXCEPTION type=${e.runtimeType} msg=$e');
      if (mounted) setState(() { _loading = false; _error = 'Error: ${e.runtimeType} — $e'; });
    }
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final completed = _history.where((b) => b.status == 'Completed').toList();
    final cancelled = _history.where((b) => b.status == 'Cancelled').toList();

    Widget body;
    if (_loading) {
      body = const Center(
        child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen)),
      );
    } else if (_error != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 36, color: AppColors.textHint),
            const SizedBox(height: 12),
            Text(_error!,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            TextButton(onPressed: _loadHistory, child: const Text('Retry')),
          ],
        ),
      );
    } else {
      body = DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Container(
              color: AppColors.brandGreen,
              child: TabBar(
                indicatorColor: Colors.white,
                indicatorWeight: 3,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white60,
                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                tabs: [
                  Tab(text: 'Completed (${completed.length})'),
                  Tab(text: 'Cancelled (${cancelled.length})'),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: AppColors.background,
                child: TabBarView(
                  children: [
                    _BookingList(bookings: completed, formatDate: _formatDate, onRefresh: _loadHistory),
                    _BookingList(bookings: cancelled, formatDate: _formatDate, onRefresh: _loadHistory),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (widget.embedded) {
      return Column(
        children: [
          Container(
            color: AppColors.brandGreen,
            padding: EdgeInsets.fromLTRB(
                16, MediaQuery.of(context).padding.top + 14, 16, _loading || _error != null ? 14 : 0),
            child: Row(
              children: [
                const Text('History',
                    style: TextStyle(
                        color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (!_loading)
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 20),
                    onPressed: _loadHistory,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('History',
            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          if (!_loading)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
              onPressed: _loadHistory,
            ),
        ],
      ),
      body: body,
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
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: 400,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64, height: 64,
                    decoration: const BoxDecoration(
                        color: AppColors.brandGreenSurface, shape: BoxShape.circle),
                    child: const Icon(Icons.history_outlined, size: 30, color: AppColors.brandGreen),
                  ),
                  const SizedBox(height: 14),
                  const Text('No records yet',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      color: AppColors.brandGreen,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
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
        title: const Text('Collection Photo', style: TextStyle(color: Colors.white, fontSize: 15)),
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

  double get _testsTotal => _items.isEmpty
      ? b.testsTotal
      : _items.fold(0.0, (s, i) => s + (double.tryParse(i['price']?.toString() ?? '0') ?? 0));

  @override
  Widget build(BuildContext context) {
    final isCompleted = b.status == 'Completed';
    final statusColor = isCompleted ? AppColors.brandGreen : const Color(0xFFD32F2F);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
      child: Column(
        children: [
          // Handle
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40, height: 4,
              decoration: BoxDecoration(
                  color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Booking Details',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  Text(b.id,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                ),
                child: Text(b.status,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: statusColor)),
              ),
            ]),
          ),
          const Divider(height: 1),

          // Scrollable content
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // Appointment
                  _HDetailSection(title: 'Appointment', rows: [
                    _HDetailRow(Icons.person_outline, 'Customer', b.customerName),
                    _HDetailRow(Icons.event_outlined, 'Date', _fmt(b.date)),
                    _HDetailRow(Icons.schedule_outlined, 'Time', b.timeSlot),
                    _HDetailRow(Icons.home_outlined, 'Mode', b.mode),
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
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary, letterSpacing: 0.3),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: _itemsLoading
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(AppColors.brandGreen)),
                            ),
                          )
                        : _items.isEmpty
                            ? const Text('No test details available',
                                style: TextStyle(fontSize: 12, color: AppColors.textHint))
                            : Column(
                                children: _items.map((item) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  child: Row(children: [
                                    const Icon(Icons.science_outlined,
                                        size: 14, color: AppColors.brandGreen),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(item['name']?.toString() ?? '',
                                          style: const TextStyle(
                                              fontSize: 12, color: AppColors.textPrimary)),
                                    ),
                                    Text(
                                      '₹${(double.tryParse(item['price']?.toString() ?? '0') ?? 0).toInt()}',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textPrimary),
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
                  const Text(
                    'Collection Photo',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary, letterSpacing: 0.3),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: _collectionProofLoading
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation(AppColors.brandGreen)),
                            ),
                          )
                        : _collectionProofUrl == null
                            ? const Text('No collection photo captured',
                                style: TextStyle(fontSize: 12, color: AppColors.textHint))
                            : GestureDetector(
                                onTap: _viewCollectionProof,
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
                                    child: Text('Proof photo captured — tap to view',
                                        style: TextStyle(fontSize: 12, color: AppColors.textPrimary)),
                                  ),
                                  const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.textHint),
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
    );
  }
}

// ─── History Card ─────────────────────────────────────────────────────────────

class _HistoryCard extends StatelessWidget {
  final TechnicianBooking booking;
  final String Function(DateTime) formatDate;

  const _HistoryCard({required this.booking, required this.formatDate});

  @override
  Widget build(BuildContext context) {
    final isCompleted  = booking.status == 'Completed';
    final statusColor  = isCompleted ? AppColors.brandGreen : const Color(0xFFD32F2F);
    final totalCollected = booking.serviceChargePaid + booking.testsTotal;

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
            // Status strip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: statusColor.withValues(alpha: 0.07),
              child: Row(children: [
                Icon(
                  isCompleted ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 13, color: statusColor,
                ),
                const SizedBox(width: 6),
                Text(booking.status,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: statusColor)),
                const Spacer(),
                Text(booking.id,
                    style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name
                  Text(booking.customerName,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  const SizedBox(height: 8),

                  // Date
                  Row(children: [
                    const Icon(Icons.event_outlined, size: 12, color: AppColors.textHint),
                    const SizedBox(width: 5),
                    Text(formatDate(booking.date),
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
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

                  const SizedBox(height: 8),

                  // Tests
                  Wrap(spacing: 6, runSpacing: 4,
                    children: booking.testNames.take(2).map((t) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(t,
                          style: const TextStyle(fontSize: 11, color: AppColors.brandGreen)),
                    )).toList(),
                  ),

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
          ],
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
        Text(title,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: AppColors.textSecondary, letterSpacing: 0.3)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            children: rows.map((r) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(r.icon, size: 14, color: AppColors.brandGreen),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Text(r.label,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ),
                Expanded(
                  flex: 3,
                  child: Text(r.value,
                      style: TextStyle(
                          fontSize: 12,
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
