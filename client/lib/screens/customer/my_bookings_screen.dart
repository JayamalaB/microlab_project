import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/customer_refresh_notifier.dart';
import 'package:microlab/services/razorpay_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'booking_widgets.dart';
import 'package:microlab/models.dart';
import 'tracking_map_screen.dart';

class MyBookingsScreen extends StatefulWidget {
  final BookingModel? initialBooking;
  final bool embedded;
  final ValueNotifier<int>? refreshTrigger;
  const MyBookingsScreen({super.key, this.initialBooking, this.embedded = false, this.refreshTrigger});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> with WidgetsBindingObserver {
  List<BookingModel> _bookings = [];
  bool _isLoading = true;
  String? _error;

  StreamSubscription<BookingAcceptedEvent>? _acceptedSub;
  StreamSubscription<int>? _enRouteSub;
  StreamSubscription<int>? _arrivedSub;
  StreamSubscription<int>? _collectedSub;
  StreamSubscription<bool>? _connectedSub;

  @override
  void initState() {
    super.initState();
    _loadBookings();
    widget.refreshTrigger?.addListener(_loadBookings);
    WidgetsBinding.instance.addObserver(this);
    CustomerRefreshNotifier.instance.addListener(_onFcmRefresh);
    _acceptedSub  = SocketService.instance.onBookingAccepted.listen((_) => _loadBookings());
    _enRouteSub   = SocketService.instance.onTechnicianEnRoute.listen((_) => _loadBookings());
    _arrivedSub   = SocketService.instance.onTechnicianArrived.listen((_) => _loadBookings());
    _collectedSub = SocketService.instance.onCollectionCompleted.listen((_) => _loadBookings());
    _connectedSub = SocketService.instance.onConnected.listen((_) => _loadBookings());
  }

  Future<void> _loadBookings() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final raw = await ApiService.getMyBookings();
      debugPrint('[MyBookings] raw rows: ${raw.length}');
      final mapped = <BookingModel>[];
      for (final row in raw) {
        try {
          mapped.add(_fromApi(row));
        } catch (e) {
          debugPrint('[MyBookings] _fromApi failed for row: $row\nError: $e');
        }
      }
      if (widget.initialBooking != null &&
          !mapped.any((b) => b.id == widget.initialBooking!.id)) {
        mapped.insert(0, widget.initialBooking!);
      }
      debugPrint('[MyBookings] mapped ${mapped.length} booking(s)');
      setState(() { _bookings = mapped; _isLoading = false; });
    } catch (e, st) {
      debugPrint('[MyBookings] _loadBookings error: $e\n$st');
      setState(() { _error = 'Could not load bookings'; _isLoading = false; });
    }
  }

  static String _mapStatus(String raw) {
    switch (raw) {
      case 'pending':    return 'Pending';
      case 'scheduled':  return 'Scheduled';
      case 'confirmed':  return 'Confirmed';
      case 'assigned':   return 'Technician Allocated';
      case 'arrived':    return 'Technician Arrived';
      case 'collected':  return 'Sample Collected';
      case 'submitted':  return 'Handed to Lab';
      case 'completed':  return 'Completed';
      case 'cancelled':  return 'Cancelled';
      default:           return raw.isNotEmpty
          ? raw[0].toUpperCase() + raw.substring(1)
          : 'Unknown';
    }
  }

  static List<String> _parsePresImages(dynamic raw) {
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw as String) as List;
      return list.map((e) => e.toString()).toList();
    } catch (_) { return []; }
  }

  static BookingModel _fromApi(Map<String, dynamic> b) {
    // test_items format: "productId:::Name:::price:::type|||..."
    final rawItems = (b['test_items'] as String? ?? '')
        .split('|||')
        .where((s) => s.isNotEmpty)
        .toList();
    final tests = rawItems.map((raw) {
      final parts = raw.split(':::');
      final productId = parts.isNotEmpty ? parts[0] : '0';
      final name      = parts.length > 1 ? parts[1] : 'Unknown';
      final price     = parts.length > 2 ? (double.tryParse(parts[2]) ?? 0.0) : 0.0;
      final type      = parts.length > 3 ? parts[3] : 'test';
      final preInstr  = parts.length > 4 && parts[4].isNotEmpty ? parts[4] : null;
      return TestModel(
        id: productId,
        name: name,
        type: type == 'package' ? 'package' : 'single',
        category: '',
        description: '',
        hasOffer: false,
        originalPrice: price,
        finalPrice: price,
        docRequired: false,
        reportStatus: '',
        preInstructions: preInstr,
      );
    }).toList();

    final total      = double.tryParse(b['total_amount']?.toString() ?? '') ?? 0.0;
    final itemsTotal = double.tryParse(b['items_total']?.toString() ?? '') ?? total;
    final amountPaid = double.tryParse(b['amount_paid']?.toString() ?? '') ?? 0.0;
    final amountDue  = double.tryParse(b['amount_due']?.toString() ?? '') ?? (total - amountPaid).clamp(0, double.infinity);

    final presImages = _parsePresImages(b['presc_image_url']);
    final presStatus = b['prescription_status'] as String?;

    final bookingType = b['booking_type'] as String? ?? 'lab_visit';
    final mode = bookingType == 'home_collection' ? 'Home Collection' : 'Lab Visit';

    DateTime date;
    final collDate = b['collection_date'] as String?;
    if (collDate != null && collDate.isNotEmpty) {
      date = DateTime.tryParse(collDate) ?? DateTime.now();
    } else {
      date = DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime.now();
    }

    BranchModel? branch;
    if (b['branch_id'] != null && b['branch_name'] != null) {
      branch = BranchModel(
        id: b['branch_id'].toString(),
        name: b['branch_name'] as String,
        address: b['branch_address'] as String? ?? '',
        location: b['branch_location'] as String?,
        pincode: b['branch_pincode']?.toString(),
      );
    }

    final member = MemberModel(
      id: b['patient_id']?.toString() ?? '0',
      name: b['patient_name'] as String? ?? 'Patient',
      mobile: b['patient_mobile'] as String? ?? '',
      gender: '',
      location: '',
      address: '',
    );

    final slotLabel = (b['slot_label'] as String?) ??
                      (b['slot_time_formatted'] as String?);

    return BookingModel(
      id:                  b['booking_ref'] as String? ?? b['booking_id_num'].toString(),
      bookingIdNum:        b['booking_id_num'] != null ? (b['booking_id_num'] as num).toInt() : null,
      member:              member,
      tests:               tests,
      mode:                mode,
      address:             b['collection_address'] as String?,
      pincode:             b['collection_pincode']?.toString(),
      city:                b['collection_city']    as String?,
      branch:              branch,
      date:                date,
      timeSlot:            slotLabel ?? 'Not specified',
      paymentType:         amountPaid >= total && total > 0 ? 'full' : 'pay_later',
      serviceCharge:       (total - itemsTotal).clamp(0, double.infinity),
      testsTotal:          itemsTotal,
      grandTotal:          total,
      paidAmount:          amountPaid,
      amountDue:           amountDue,
      paymentStatus:       b['payment_status'] as String?,
      status:              _mapStatus(b['booking_status'] as String? ?? 'pending'),
      createdAt:           DateTime.tryParse(b['created_at'] as String? ?? '') ?? DateTime.now(),
      docRequired:         presImages.isNotEmpty,
      docVerified:         presStatus == 'verified',
      prescriptionStatus:  presStatus,
      prescriptionImages:  presImages,
      collectionStatus:    b['collection_status'] as String?,
      visitGroupId:        b['visit_group_id']    as String?,
      technicianName:      b['tech_name']         as String?,
      technicianMobile:    b['tech_mobile']        as String?,
      technicianPhoto:     b['tech_photo']         as String?,
      technicianId:        b['technician_id'] != null ? (b['technician_id'] as num).toInt() : null,
      patientLat:          b['collection_latitude']  != null ? double.tryParse(b['collection_latitude'].toString())  : null,
      patientLng:          b['collection_longitude'] != null ? double.tryParse(b['collection_longitude'].toString()) : null,
      rating:              b['overall_rating'] != null ? (b['overall_rating'] as num).toInt() : null,
      feedbackComment:     b['feedback_comments'] as String?,
      reportUrl:           b['report_url'] as String?,
      refundAmount:        b['refund_amount'] != null ? double.tryParse(b['refund_amount'].toString()) : null,
      refundStatus:        b['refund_status'] as String?,
      rescheduleCount:     b['reschedule_count'] != null ? (b['reschedule_count'] as num).toInt() : 0,
      canReschedule:       b['can_reschedule'] as bool? ?? true,
    );
  }

  List<({MemberModel member, List<BookingModel> bookings})> get _patientGroups {
    final map = <String, List<BookingModel>>{};
    final members = <String, MemberModel>{};
    for (final b in _bookings) {
      final id = b.member.id;
      map.putIfAbsent(id, () => []).add(b);
      members.putIfAbsent(id, () => b.member);
    }
    final groups = map.entries
        .map((e) => (member: members[e.key]!, bookings: e.value))
        .toList()
      ..sort((a, b) => b.bookings.first.createdAt.compareTo(a.bookings.first.createdAt));
    return groups;
  }

  @override
  void dispose() {
    widget.refreshTrigger?.removeListener(_loadBookings);
    WidgetsBinding.instance.removeObserver(this);
    CustomerRefreshNotifier.instance.removeListener(_onFcmRefresh);
    _acceptedSub?.cancel();
    _enRouteSub?.cancel();
    _arrivedSub?.cancel();
    _collectedSub?.cancel();
    _connectedSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadBookings();
  }

  void _onFcmRefresh() {
    if (CustomerRefreshNotifier.instance.lastEvent ==
        CustomerRefreshEvent.bookingStatusChanged) {
      _loadBookings();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: double.infinity,
            color: AppColors.brandGreen,
            height: MediaQuery.of(context).padding.top + 56,
            padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
            child: const Align(
              alignment: Alignment.center,
              child: Text(
                'My Bookings',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('My Bookings',
            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const ColoredBox(
        color: Color(0xFFF4F6F8),
        child: Center(child: CircularProgressIndicator(color: AppColors.brandGreen)),
      );
    }
    if (_error != null) {
      return ColoredBox(
        color: const Color(0xFFF4F6F8),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 40, color: AppColors.textHint),
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _loadBookings,
                child: const Text('Retry', style: TextStyle(color: AppColors.brandGreen)),
              ),
            ],
          ),
        ),
      );
    }

    final groups = _patientGroups;
    if (groups.isEmpty) {
      return RefreshIndicator(
        onRefresh: () async => _loadBookings(),
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
                      width: 72, height: 72,
                      decoration: const BoxDecoration(
                          color: AppColors.brandGreenSurface, shape: BoxShape.circle),
                      child: const Icon(Icons.calendar_today_outlined,
                          size: 32, color: AppColors.brandGreen),
                    ),
                    const SizedBox(height: 16),
                    const Text('No bookings yet',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    const SizedBox(height: 8),
                    const Text(
                      'Your booked tests will appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _loadBookings(),
      color: AppColors.brandGreen,
      child: ColoredBox(
      color: const Color(0xFFF4F6F8),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: groups.length,
        itemBuilder: (_, i) {
          final g = groups[i];
          return _PatientCard(
            member: g.member,
            bookings: g.bookings,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => _PatientBookingsPage(
                    member: g.member,
                    initialBookings: g.bookings,
                  ),
                ),
              ).then((_) => _loadBookings());
            },
          );
        },
      ),
      ),
    );
  }
}

// ─── Patient Card ────────────────────────────────────────────────────────────

class _PatientCard extends StatelessWidget {
  final MemberModel member;
  final List<BookingModel> bookings;
  final VoidCallback onTap;

  const _PatientCard({required this.member, required this.bookings, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final upcoming = bookings.where((b) =>
        b.status == 'Pending' ||
        b.status == 'Confirmed' ||
        b.status == 'Technician Allocated' ||
        b.status == 'In Progress').length;
    final initial = member.name.isNotEmpty ? member.name[0].toUpperCase() : '?';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              color: AppColors.brandGreenSurface,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                initial,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.brandGreen,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  member.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${bookings.length} booking${bookings.length == 1 ? '' : 's'}'
                  '${upcoming > 0 ? ' · $upcoming upcoming' : ''}',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.textHint, size: 22),
        ]),
      ),
    );
  }
}

// ─── Patient Bookings Page ───────────────────────────────────────────────────

class _PatientBookingsPage extends StatefulWidget {
  final MemberModel member;
  final List<BookingModel> initialBookings;

  const _PatientBookingsPage({required this.member, required this.initialBookings});

  @override
  State<_PatientBookingsPage> createState() => _PatientBookingsPageState();
}

class _PatientBookingsPageState extends State<_PatientBookingsPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabCtrl;
  late List<BookingModel> _bookings;
  bool _reloading = false;

  StreamSubscription<BookingAcceptedEvent>? _acceptedSub;
  StreamSubscription<int>? _enRouteSub;
  StreamSubscription<int>? _arrivedSub;
  StreamSubscription<int>? _collectedSub;
  StreamSubscription<bool>? _connectedSub;
  Timer? _pollTimer;

  static const _tabs = ['All', 'Upcoming', 'Completed', 'Cancelled'];

  static const _activeStatuses = {'pending', 'confirmed', 'assigned', 'arrived'};

  @override
  void initState() {
    super.initState();
    _bookings = List.from(widget.initialBookings);
    _tabCtrl = TabController(length: _tabs.length, vsync: this);
    WidgetsBinding.instance.addObserver(this);
    _acceptedSub  = SocketService.instance.onBookingAccepted.listen((_) => _reload());
    _enRouteSub   = SocketService.instance.onTechnicianEnRoute.listen((_) => _reload());
    _arrivedSub   = SocketService.instance.onTechnicianArrived.listen((_) => _reload());
    _collectedSub = SocketService.instance.onCollectionCompleted.listen((_) => _reload());
    _connectedSub = SocketService.instance.onConnected.listen((_) => _reload());
    _reload();
    _startPollIfNeeded();
  }

  void _startPollIfNeeded() {
    _pollTimer?.cancel();
    final hasActive = _bookings.any((b) => _activeStatuses.contains(b.status.toLowerCase()));
    if (!hasActive) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _reload());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reload();
      _startPollIfNeeded();
    } else if (state == AppLifecycleState.paused) {
      _pollTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _acceptedSub?.cancel();
    _enRouteSub?.cancel();
    _arrivedSub?.cancel();
    _collectedSub?.cancel();
    _connectedSub?.cancel();
    _pollTimer?.cancel();
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _reloading = true);
    try {
      final raw = await ApiService.getMyBookings();
      final all = raw.map((r) => _MyBookingsScreenState._fromApi(r)).toList();
      if (mounted) {
        setState(() {
          _bookings = all.where((b) => b.member.id == widget.member.id).toList();
          _reloading = false;
        });
        _startPollIfNeeded();
      }
    } catch (_) {
      if (mounted) setState(() => _reloading = false);
    }
  }

  List<BookingModel> _filtered(String tab) {
    if (tab == 'All') return _bookings;
    if (tab == 'Upcoming') {
      return _bookings
          .where((b) =>
              b.status == 'Scheduled' ||
              b.status == 'Pending' ||
              b.status == 'Confirmed' ||
              b.status == 'Technician Allocated' ||
              b.status == 'In Progress')
          .toList();
    }
    if (tab == 'Completed') {
      return _bookings
          .where((b) => b.status == 'Completed' || b.status == 'Sample Collected')
          .toList();
    }
    if (tab == 'Cancelled') {
      return _bookings.where((b) => b.status == 'Cancelled').toList();
    }
    return _bookings;
  }

  void _showDetail(BookingModel booking) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BookingDetailSheet(
        booking: booking,
        onPaymentSuccess: _reload,
      ),
    );
  }

  Widget _emptyState(String tab) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreenSurface, shape: BoxShape.circle),
              child: const Icon(Icons.calendar_today_outlined,
                  size: 32, color: AppColors.brandGreen),
            ),
            const SizedBox(height: 16),
            Text(
              tab == 'All' ? 'No bookings yet' : 'No $tab bookings',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tests booked for this patient will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.member.name,
          style: const TextStyle(
              color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: _tabs.map((t) => Tab(text: t)).toList(),
        ),
      ),
      body: _reloading
          ? const Center(child: CircularProgressIndicator(color: AppColors.brandGreen))
          : TabBarView(
              controller: _tabCtrl,
              children: _tabs.map((tab) {
                final list = _filtered(tab);
                if (list.isEmpty) return _emptyState(tab);
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final b = list[i];
                    // Service charge applies only when this booking carries a service
                    // charge component (home collection fee) and technician has arrived.
                    // Family members whose booking has no service charge never get deducted.
                    const chargeApplies = false;
                    return _BookingCard(
                      booking: b,
                      chargeApplies: chargeApplies,
                      onTap: () => _showDetail(b),
                      onFeedbackSubmitted: _reload,
                      onCancelled: _reload,
                    );
                  },
                );
              }).toList(),
            ),
    );
  }
}

void _showFeedback(BuildContext context, BookingModel booking, {VoidCallback? onRefresh}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _FeedbackSheet(
      booking: booking,
      onSubmit: (rating, comment) async {
        final result = await ApiService.submitFeedback(
          booking.bookingIdNum!, rating, comment);
        if (!context.mounted) return;
        if (result['success'] == true) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Row(children: [
              ...List.generate(rating, (_) => const Icon(Icons.star_rounded, color: Colors.white, size: 14)),
              const SizedBox(width: 8),
              const Expanded(child: Text('Thank you for your feedback!')),
            ]),
            backgroundColor: AppColors.brandGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
          onRefresh?.call();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['message'] ?? 'Could not submit feedback'),
            backgroundColor: const Color(0xFFD32F2F),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      },
    ),
  );
}

void _showCancelSheet(BuildContext context, BookingModel booking, bool chargeApplies, VoidCallback? onCancelled) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CancelSheet(
      booking: booking,
      chargeApplies: chargeApplies,
      onConfirm: (reason) async {
        final result = await ApiService.cancelBooking(booking.bookingIdNum!, reason: reason);
        if (!context.mounted) return;
        if (result['success'] == true) {
          Navigator.pop(context);
          final refund = (result['refund_amount'] as num?)?.toDouble() ?? 0;
          final charge = (result['service_charge_applied'] as num?)?.toDouble() ?? 0;
          String msg = 'Booking cancelled.';
          if (refund > 0) msg += ' Refund of ₹${refund.toInt()} will be processed.';
          if (result['service_charge_transferred'] == true) {
            msg += ' Service charge transferred to your family member\'s booking.';
          } else if (charge > 0) {
            msg += ' ₹${charge.toInt()} service charge deducted.';
          }
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(msg),
            backgroundColor: const Color(0xFFD32F2F),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
          onCancelled?.call();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['message'] ?? 'Could not cancel booking'),
            backgroundColor: const Color(0xFFD32F2F),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      },
    ),
  );
}


void _showRescheduleSheet(BuildContext context, BookingModel booking, VoidCallback? onRescheduled) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RescheduleSheet(
      booking: booking,
      onConfirm: (collectionDate, availableSlotId, slotLabel) async {
        final result = await ApiService.rescheduleBooking(
          booking.bookingIdNum!,
          collectionDate: collectionDate,
          availableSlotId: availableSlotId,
        );
        if (!context.mounted) return;
        if (result['success'] == true) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Booking rescheduled to $collectionDate at $slotLabel'),
            backgroundColor: AppColors.brandGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
          onRescheduled?.call();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(result['message'] ?? 'Could not reschedule'),
            backgroundColor: const Color(0xFFD32F2F),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      },
    ),
  );
}

class _RescheduleSheet extends StatefulWidget {
  final BookingModel booking;
  final Future<void> Function(String collectionDate, int availableSlotId, String slotLabel) onConfirm;
  const _RescheduleSheet({required this.booking, required this.onConfirm});

  @override
  State<_RescheduleSheet> createState() => _RescheduleSheetState();
}

class _RescheduleSheetState extends State<_RescheduleSheet> {
  DateTime? _date;
  Map<String, dynamic>? _slot; // {time_slot_id, label, time, remaining}
  List<Map<String, dynamic>> _slots = [];
  bool _loadingSlots = false;
  bool _submitting   = false;
  String _slotError  = '';

  String _toApiDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _fmtDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  Future<void> _pickDate() async {
    final now    = DateTime.now();
    final picked = await showDatePicker(
      context:     context,
      initialDate: _date ?? now,
      firstDate:   now,
      lastDate:    now.add(const Duration(days: 30)),
      helpText:    'SELECT NEW DATE',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: Color(0xFF1565C0), onPrimary: Colors.white, surface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() { _date = picked; _slot = null; _slots = []; _slotError = ''; });
      _loadSlots(picked);
    }
  }

  Future<void> _loadSlots(DateTime date) async {
    setState(() { _loadingSlots = true; _slotError = ''; });
    try {
      final branchId   = widget.booking.branch?.id ?? '';
      final slotType   = widget.booking.mode == 'Home Collection' ? 'home_collection' : 'lab_visit';
      final uri = Uri.parse('${AppConstants.serverUrl}/api/slots').replace(queryParameters: {
        'branch_id': branchId,
        'date':      _toApiDate(date),
        'slot_type': slotType,
      });
      final res  = await http.get(uri).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (!mounted) return;
      if (res.statusCode == 200 && body['success'] == true) {
        final list = (body['slots'] as List).cast<Map<String, dynamic>>();
        setState(() {
          _slots        = list;
          _loadingSlots = false;
          _slotError    = list.isEmpty ? 'No slots available for this date.' : '';
        });
      } else {
        setState(() { _loadingSlots = false; _slotError = body['message'] as String? ?? 'Could not load slots.'; });
      }
    } catch (_) {
      if (mounted) setState(() { _loadingSlots = false; _slotError = 'Could not reach the server.'; });
    }
  }

  Future<void> _submit() async {
    if (_date == null || _slot == null || _submitting) return;
    setState(() => _submitting = true);
    try {
      await widget.onConfirm(_toApiDate(_date!), _slot!['time_slot_id'] as int, _slot!['label'] as String);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).padding.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(
            color: AppColors.divider, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),
          const Text('Reschedule Booking',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          Text('Current: ${widget.booking.timeSlot} · ${_fmtDate(widget.booking.date)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 20),

          // Date picker
          GestureDetector(
            onTap: _pickDate,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: BoxDecoration(
                color: _date != null ? const Color(0xFFF0F7FF) : AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _date != null ? const Color(0xFF1565C0) : AppColors.divider,
                    width: _date != null ? 1.5 : 1),
              ),
              child: Row(children: [
                Icon(Icons.event_outlined, size: 18,
                    color: _date != null ? const Color(0xFF1565C0) : AppColors.textHint),
                const SizedBox(width: 10),
                Text(_date != null ? _fmtDate(_date!) : 'Select new date',
                    style: TextStyle(fontSize: 14,
                        color: _date != null ? AppColors.textPrimary : AppColors.textHint)),
                const Spacer(),
                const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.textHint),
              ]),
            ),
          ),

          const SizedBox(height: 14),

          // Slots
          if (_loadingSlots)
            const Center(child: Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1565C0)),
            ))
          else if (_slotError.isNotEmpty)
            Text(_slotError, style: const TextStyle(fontSize: 12, color: Color(0xFFD32F2F)))
          else if (_slots.isNotEmpty)
            Wrap(
              spacing: 8, runSpacing: 8,
              children: _slots.map((s) {
                final selected = _slot?['time_slot_id'] == s['time_slot_id'];
                return GestureDetector(
                  onTap: () => setState(() => _slot = s),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF1565C0) : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: selected ? const Color(0xFF1565C0) : AppColors.divider,
                          width: selected ? 1.5 : 1),
                    ),
                    child: Text(s['label'] as String,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: selected ? Colors.white : AppColors.textPrimary)),
                  ),
                );
              }).toList(),
            ),

          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: (_date != null && _slot != null && !_submitting) ? _submit : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF1565C0).withValues(alpha: 0.35),
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _submitting
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Confirm Reschedule',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Booking Card ─────────────────────────────────────────────────────────────

class _BookingCard extends StatelessWidget {
  final BookingModel booking;
  final bool chargeApplies;
  final VoidCallback onTap;
  final VoidCallback? onFeedbackSubmitted;
  final VoidCallback? onCancelled;
  const _BookingCard({required this.booking, required this.chargeApplies, required this.onTap, this.onFeedbackSubmitted, this.onCancelled});

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Completed':             return AppColors.brandGreen;
      case 'Sample Collected':      return const Color(0xFF2E7D32);
      case 'Handed to Lab':         return const Color(0xFF2E7D32);
      case 'Technician Arrived':    return const Color(0xFF2E7D32);
      case 'Confirmed':             return const Color(0xFF1565C0);
      case 'Technician Allocated':  return const Color(0xFF1565C0);
      case 'In Progress':           return const Color(0xFF1565C0);
      case 'Cancelled':             return const Color(0xFFD32F2F);
      case 'Scheduled':             return const Color(0xFF6A1B9A);
      default:                      return const Color(0xFFE65100);
    }
  }

  IconData _statusIcon(String s) {
    switch (s) {
      case 'Completed':             return Icons.check_circle_outline;
      case 'Sample Collected':      return Icons.science_outlined;
      case 'Handed to Lab':         return Icons.local_shipping_outlined;
      case 'Technician Arrived':    return Icons.door_front_door_outlined;
      case 'Confirmed':             return Icons.event_available_outlined;
      case 'Technician Allocated':  return Icons.assignment_ind_outlined;
      case 'In Progress':           return Icons.directions_run_rounded;
      case 'Cancelled':             return Icons.cancel_outlined;
      case 'Scheduled':             return Icons.event_outlined;
      default:                      return Icons.hourglass_empty_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = _statusColor(booking.status);
    return GestureDetector(
      onTap: onTap,
      child: Container(
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
              // Status strip at top
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                color: sc.withOpacity(0.08),
                child: Row(
                  children: [
                    Icon(_statusIcon(booking.status), size: 14, color: sc),
                    const SizedBox(width: 6),
                    Text(booking.status,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sc)),
                    const Spacer(),
                    Text(booking.id,
                        style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Customer + mode
                    Row(
                      children: [
                        Expanded(
                          child: Text(booking.member.name,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.brandGreenSurface,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(booking.mode,
                              style: const TextStyle(
                                  fontSize: 10, color: AppColors.brandGreen, fontWeight: FontWeight.w500)),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Date + time
                    Row(
                      children: [
                        const Icon(Icons.event_outlined, size: 13, color: AppColors.textHint),
                        const SizedBox(width: 5),
                        Text(_formatDate(booking.date),
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                        const SizedBox(width: 12),
                        const Icon(Icons.schedule_outlined, size: 13, color: AppColors.textHint),
                        const SizedBox(width: 5),
                        Text(booking.timeSlot,
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // Tests list (max 2 shown + count)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        ...booking.tests.take(2).map((t) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                        )),
                        if (booking.tests.length > 2)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.background,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text('+${booking.tests.length - 2} more',
                                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                          ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Amount row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Paid: ₹${booking.paidAmount.toInt()}',
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
                            if (booking.paymentType == 'service_charge')
                              Text('Due at collection: ₹${(booking.grandTotal - booking.paidAmount).toInt()}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                            if (booking.status == 'Cancelled' && (booking.refundAmount ?? 0) > 0)
                              Text(
                                booking.refundStatus == 'processed'
                                    ? 'Refund of ₹${booking.refundAmount!.toInt()} initiated · 5–7 days'
                                    : 'Refund of ₹${booking.refundAmount!.toInt()} pending',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: booking.refundStatus == 'processed'
                                      ? AppColors.brandGreen
                                      : const Color(0xFFE65100),
                                ),
                              ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('View details',
                                style: TextStyle(
                                    fontSize: 12, color: AppColors.brandGreen, fontWeight: FontWeight.w500)),
                            const SizedBox(width: 4),
                            const Icon(Icons.arrow_forward_ios_rounded,
                                size: 11, color: AppColors.brandGreen),
                          ],
                        ),
                      ],
                    ),

                    // Feedback button for completed or sample-collected bookings
                    if ((booking.status == 'Completed' || booking.status == 'Sample Collected' || booking.status == 'Handed to Lab' || booking.status == 'collected') && booking.rating == null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () => _showFeedback(context, booking, onRefresh: onFeedbackSubmitted),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3E0),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFFFCC02).withOpacity(0.5)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.star_border_rounded, size: 16, color: Color(0xFFE65100)),
                              SizedBox(width: 6),
                              Text('Rate your experience',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFE65100))),
                            ],
                          ),
                        ),
                      ),
                    ],

                    // Show existing rating
                    if ((booking.status == 'Completed' || booking.status == 'Sample Collected' || booking.status == 'Handed to Lab' || booking.status == 'collected') && booking.rating != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.brandGreenSurface,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.brandGreenLight),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ...List.generate(5, (i) => Icon(
                              i < (booking.rating ?? 0) ? Icons.star_rounded : Icons.star_border_rounded,
                              size: 18,
                              color: i < (booking.rating ?? 0) ? const Color(0xFFFFB300) : AppColors.divider,
                            )),
                            const SizedBox(width: 8),
                            const Text('Thank you!',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.brandGreen)),
                          ],
                        ),
                      ),
                    ],

                    // Reschedule button
                    if (booking.canReschedule &&
                        (booking.status == 'Pending' || booking.status == 'Scheduled' || booking.status == 'Confirmed') &&
                        !booking.date.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)) &&
                        (booking.collectionStatus == null || booking.collectionStatus == 'assigned')) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () => _showRescheduleSheet(context, booking, onCancelled),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF0F7FF),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF90CAF9)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.edit_calendar_outlined, size: 15, color: Color(0xFF1565C0)),
                              SizedBox(width: 6),
                              Text('Reschedule',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1565C0))),
                            ],
                          ),
                        ),
                      ),
                    ],

                    // Cancel button — only for pending/scheduled/confirmed, future dates,
                    // and before technician starts collection
                    if ((booking.status == 'Pending' || booking.status == 'Scheduled' || booking.status == 'Confirmed') &&
                        !booking.date.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)) &&
                        !const {'collection_started', 'otp_verified', 'sample_collected',
                                 'handed_to_lab', 'collected', 'completed',
                                 'all_collected', 'cancelled'}
                            .contains(booking.collectionStatus)) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () => _showCancelSheet(context, booking, chargeApplies, onCancelled),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF8F8),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFEF9A9A)),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.cancel_outlined, size: 15, color: Color(0xFFD32F2F)),
                              SizedBox(width: 6),
                              Text('Cancel Booking',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFD32F2F))),
                            ],
                          ),
                        ),
                      ),
                    ],

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

// ─── Booking Detail Sheet ─────────────────────────────────────────────────────

class _BookingDetailSheet extends StatefulWidget {
  final BookingModel booking;
  final VoidCallback? onPaymentSuccess;
  const _BookingDetailSheet({required this.booking, this.onPaymentSuccess});

  @override
  State<_BookingDetailSheet> createState() => _BookingDetailSheetState();
}

class _BookingDetailSheetState extends State<_BookingDetailSheet>
    with WidgetsBindingObserver {
  bool _isProcessing = false;

  // Test results (released only)
  List<Map<String, dynamic>> _testResults = [];
  bool _resultsLoading = false;

  // Live technician state — refreshed on demand
  String? _collectionStatus;
  String? _technicianName;
  String? _technicianMobile;
  String? _technicianPhoto;
  int?    _technicianId;
  double? _patientLat;
  double? _patientLng;
  bool    _isTechRefreshing = false;

  StreamSubscription<BookingAcceptedEvent>? _acceptedSub;
  StreamSubscription<int>? _enRouteSub;
  StreamSubscription<int>? _arrivedSub;
  StreamSubscription<int>? _collectedSub;
  StreamSubscription<bool>? _connectedSub;

  bool _billBusy = false;

  Future<Uint8List> _generateBillPdf(BookingModel b) async {
    final font       = await PdfGoogleFonts.notoSansRegular();
    final fontBold   = await PdfGoogleFonts.notoSansBold();
    final fontItalic = await PdfGoogleFonts.notoSansItalic();

    final logoData  = await rootBundle.load('assets/icon/MicroLab-Logo.jpeg');
    final logoImage = pw.MemoryImage(logoData.buffer.asUint8List());

    final doc   = pw.Document();
    final green = PdfColor.fromHex('#2E7D32');
    final grey  = PdfColors.grey700;

    pw.TextStyle base({bool bold = false, bool italic = false, double size = 10, PdfColor? color}) =>
        pw.TextStyle(font: bold ? fontBold : (italic ? fontItalic : font), fontSize: size, color: color);

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Header — matches printed letterhead
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              // Left: address block
              pw.Expanded(
                flex: 3,
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                  pw.Text('# 12A, Cowley Brown Road(East), R.S.Puram Coimbatore-641002',
                      style: base(size: 9)),
                  pw.Text('Ph: 0422-2556628, 4354242', style: base(size: 9)),
                  pw.SizedBox(height: 4),
                  pw.Text('Web: www.microlabindia.com   E-mail: microlabcbe@microlabindia.com',
                      style: base(bold: true, size: 8)),
                ]),
              ),
              // Right: logo + name
              pw.Expanded(
                flex: 2,
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
                  pw.Image(logoImage, height: 90, fit: pw.BoxFit.contain),
                ]),
              ),
            ],
          ),
          pw.Divider(thickness: 1.5, color: green),
          // Receipt title + ref
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text('BILL RECEIPT', style: base(bold: true, size: 13)),
            pw.Text(b.id, style: base(size: 10, bold: true)),
          ]),
          pw.SizedBox(height: 8),

          // Booking info
          pw.Table(
            columnWidths: {
              0: const pw.FixedColumnWidth(70),
              1: const pw.FlexColumnWidth(),
            },
            children: [
              _infoRow('Patient', b.member.name, base: base),
              _infoRow('Mode',    b.mode,         base: base),
              _infoRow('Date',    '${b.date.day}/${b.date.month}/${b.date.year}', base: base),
              _infoRow('Slot',    b.timeSlot,     base: base),
              if (b.address != null) _infoRow('Address', b.address!, base: base),
            ],
          ),
          pw.SizedBox(height: 14),

          // Tests table
          pw.Text('Tests / Packages', style: base(bold: true, size: 11)),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300),
            columnWidths: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1)},
            children: [
              pw.TableRow(
                decoration: pw.BoxDecoration(color: PdfColor.fromHex('#E8F5E9')),
                children: [
                  pw.Padding(padding: const pw.EdgeInsets.all(6),
                      child: pw.Text('Test / Package', style: base(bold: true))),
                  pw.Padding(padding: const pw.EdgeInsets.all(6),
                      child: pw.Text('Amount', style: base(bold: true), textAlign: pw.TextAlign.right)),
                ],
              ),
              ...b.tests.map((t) => pw.TableRow(children: [
                pw.Padding(padding: const pw.EdgeInsets.all(6),
                    child: pw.Text(t.name, style: base())),
                pw.Padding(padding: const pw.EdgeInsets.all(6),
                    child: pw.Text('Rs.${t.finalPrice.toInt()}', style: base(), textAlign: pw.TextAlign.right)),
              ])),
            ],
          ),
          pw.SizedBox(height: 14),

          // Payment summary
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.SizedBox(
              width: 220,
              child: pw.Column(children: [
                _pdfSummaryRow('Tests Total', 'Rs.${b.testsTotal.toInt()}', base: base),
                if (b.serviceCharge > 0)
                  _pdfSummaryRow('Service Charge', 'Rs.${b.serviceCharge.toInt()}', base: base),
                pw.Divider(thickness: 0.8),
                _pdfSummaryRow('Grand Total', 'Rs.${b.grandTotal.toInt()}', bold: true, base: base),
                _pdfSummaryRow('Paid', 'Rs.${b.paidAmount.toInt()}', color: green, base: base),
                if (b.amountDue > 0)
                  _pdfSummaryRow('Amount Due', 'Rs.${b.amountDue.toInt()}', color: PdfColors.orange800, base: base),
              ]),
            ),
          ),

          pw.Spacer(),
          pw.Divider(color: PdfColors.grey300),
          pw.Center(
            child: pw.Text('Thank you for choosing Microbiological Laboratory',
                style: base(italic: true, size: 9, color: grey)),
          ),
        ],
      ),
    ));
    return doc.save();
  }

  pw.TableRow _infoRow(String label, String value,
      {required pw.TextStyle Function({bool bold, bool italic, double size, PdfColor? color}) base}) =>
    pw.TableRow(children: [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Text(label, style: base(bold: true)),
      ),
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Text(value, style: base()),
      ),
    ]);

  pw.Widget _pdfSummaryRow(String label, String value,
      {bool bold = false, PdfColor? color,
       required pw.TextStyle Function({bool bold, bool italic, double size, PdfColor? color}) base}) =>
    pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text(label, style: base(bold: bold)),
      pw.Text(value, style: base(bold: bold, color: color)),
    ]);

  Future<void> _downloadBill() async {
    if (_billBusy) return;
    setState(() => _billBusy = true);
    try {
      final bytes = await _generateBillPdf(widget.booking);
      final filename = 'Bill_${widget.booking.id}.pdf';
      if (kIsWeb) {
        await Printing.sharePdf(bytes: bytes, filename: filename);
      } else {
        final dir  = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$filename');
        await file.writeAsBytes(bytes);
        await OpenFilex.open(file.path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not download bill: $e'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } finally {
      if (mounted) setState(() => _billBusy = false);
    }
  }

  Future<void> _shareBill() async {
    if (_billBusy) return;
    setState(() => _billBusy = true);
    try {
      final bytes    = await _generateBillPdf(widget.booking);
      final filename = 'Bill_${widget.booking.id}.pdf';
      await Share.shareXFiles(
        [XFile.fromData(bytes, mimeType: 'application/pdf', name: filename)],
        subject: 'MicroLab Bill – ${widget.booking.id}',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not share bill: $e'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } finally {
      if (mounted) setState(() => _billBusy = false);
    }
  }

  Future<void> _loadResults() async {
    if (widget.booking.bookingIdNum == null) return;
    setState(() => _resultsLoading = true);
    final results = await ApiService.getBookingResults(widget.booking.bookingIdNum!);
    if (mounted) setState(() { _testResults = results; _resultsLoading = false; });
  }

  @override
  void initState() {
    super.initState();
    if (widget.booking.status == 'Completed') _loadResults();
    // Seed from the snapshot passed in
    _collectionStatus  = widget.booking.collectionStatus;
    _technicianName    = widget.booking.technicianName;
    _technicianMobile  = widget.booking.technicianMobile;
    _technicianPhoto   = widget.booking.technicianPhoto;
    _technicianId      = widget.booking.technicianId;
    _patientLat        = widget.booking.patientLat;
    _patientLng        = widget.booking.patientLng;
    WidgetsBinding.instance.addObserver(this);
    _acceptedSub  = SocketService.instance.onBookingAccepted.listen((_) => _refreshTechStatus());
    _enRouteSub   = SocketService.instance.onTechnicianEnRoute.listen((_) => _refreshTechStatus());
    _arrivedSub   = SocketService.instance.onTechnicianArrived.listen((_) => _refreshTechStatus());
    _collectedSub = SocketService.instance.onCollectionCompleted.listen((_) => _refreshTechStatus());
    _connectedSub = SocketService.instance.onConnected.listen((_) => _refreshTechStatus());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshTechStatus();
  }

  Future<void> _refreshTechStatus() async {
    if (_isTechRefreshing || widget.booking.bookingIdNum == null) return;
    setState(() => _isTechRefreshing = true);
    try {
      final data = await ApiService.fetchBookingStatus(widget.booking.bookingIdNum!);
      if (!mounted || data == null) return;
      setState(() {
        _collectionStatus = data['collection_status'] as String? ?? _collectionStatus;
        _technicianName   = data['tech_name']         as String? ?? _technicianName;
        _technicianMobile = data['tech_mobile']        as String? ?? _technicianMobile;
        _technicianPhoto  = data['tech_photo']         as String? ?? _technicianPhoto;
        if (data['technician_id'] != null) {
          _technicianId = (data['technician_id'] as num).toInt();
        }
        if (data['collection_latitude'] != null) {
          _patientLat = double.tryParse(data['collection_latitude'].toString());
        }
        if (data['collection_longitude'] != null) {
          _patientLng = double.tryParse(data['collection_longitude'].toString());
        }
      });
    } finally {
      if (mounted) setState(() => _isTechRefreshing = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _acceptedSub?.cancel();
    _enRouteSub?.cancel();
    _arrivedSub?.cancel();
    _collectedSub?.cancel();
    _connectedSub?.cancel();
    clearRazorpay();
    super.dispose();
  }

  void _showEditTests() {
    if (b.bookingIdNum == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditTestsSheet(
        booking: b,
        onSaved: () {
          if (!mounted) return;
          Navigator.pop(context);
          widget.onPaymentSuccess?.call();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Booking updated successfully'),
            backgroundColor: AppColors.brandGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        },
      ),
    );
  }

  BookingModel get b => widget.booking;

  bool get _canEditTests {
    if (b.paymentStatus == 'paid') return false;
    const blocked = {
      'en_route', 'arrived', 'collection_started', 'sample_collected', 'handed_to_lab'
    };
    if (b.collectionStatus != null && blocked.contains(b.collectionStatus)) return false;
    return b.status == 'Pending' || b.status == 'Confirmed' || b.status == 'Scheduled';
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  bool get _paymentPending => b.status != 'Cancelled' && b.paymentStatus != 'paid' && b.grandTotal > 0;
  bool get _prescriptionBlocking =>
      b.prescriptionImages.isNotEmpty && b.prescriptionStatus != 'verified';

  void _triggerPayment() {
    if (b.bookingIdNum == null) return;
    final amount = b.amountDue > 0 ? b.amountDue : b.grandTotal;
    setState(() => _isProcessing = true);

    openRazorpay(
      options: {
        'key':         'rzp_test_SonqjjPurqlLci',
        'amount':      (amount * 100).toInt(),
        'name':        'MicroLab',
        'description': b.tests.map((t) => t.name).join(', '),
        'prefill': {
          'contact': b.member.mobile,
          'name':    b.member.name,
        },
        'theme': {'color': '#0A5C4A'},
      },
      onSuccess: (paymentId) async {
        final ok = await ApiService.payBooking(
          bookingId:          b.bookingIdNum!,
          razorpayPaymentId:  paymentId,
          amount:             amount,
        );
        if (!mounted) return;
        setState(() => _isProcessing = false);
        if (ok) {
          Navigator.pop(context);
          widget.onPaymentSuccess?.call();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Payment successful! Booking confirmed.'),
            backgroundColor: AppColors.brandGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Payment recorded but confirmation failed. Contact support.'),
            backgroundColor: Colors.orange[700],
            behavior: SnackBarBehavior.floating,
          ));
        }
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message == 'Payment cancelled' ? 'Payment cancelled' : 'Payment failed: $message'),
          backgroundColor: message == 'Payment cancelled' ? AppColors.textSecondary : Colors.red[700],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
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
              decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Booking Details',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                      Text(b.id,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                BookingStatusBadge(status: b.status),
              ],
            ),
          ),
          const Divider(height: 1),

          // Scrollable content
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // Appointment info
                  _DetailSection(
                    title: 'Appointment',
                    rows: [
                      _DetailRow(Icons.person_outline, 'Customer', b.member.name),
                      _DetailRow(Icons.event_outlined, 'Date', _formatDate(b.date)),
                      _DetailRow(Icons.schedule_outlined, 'Time', b.timeSlot),
                      _DetailRow(
                        b.mode == 'Home Collection' ? Icons.home_outlined : Icons.local_hospital_outlined,
                        'Mode', b.mode,
                      ),
                      if (b.isVip && b.selectedTechnician != null)
                        _DetailRow(Icons.medical_services_outlined, 'Technician', b.selectedTechnician!.name),
                      if (b.isVip)
                        const _DetailRow(Icons.star_rounded, 'Type', 'VIP Customer', valueColor: Color(0xFFFFB300)),
                      if (b.mode == 'Home Collection') ...[
                        if (b.address != null && b.address!.isNotEmpty)
                          _DetailRow(Icons.home_outlined, 'Collection Address', b.address!),
                        if (b.city != null || b.pincode != null)
                          _DetailRow(Icons.location_on_outlined, 'Area',
                            [b.city, b.pincode].where((s) => s != null && s.isNotEmpty).join(', ')),
                      ] else ...[
                        if (b.branch != null)
                          _DetailRow(Icons.local_hospital_outlined, 'Branch', b.branch!.name),
                        if (b.branch?.address != null && b.branch!.address.isNotEmpty)
                          _DetailRow(Icons.location_on_outlined, 'Branch Address', b.branch!.address),
                      ],
                    ],
                  ),

                  // Technician card — always shown for home collection
                  if (b.mode == 'Home Collection') ...[
                    const SizedBox(height: 16),
                    _TechnicianCard(
                      name:             _technicianName,
                      mobile:           _technicianMobile,
                      photoUrl:         _technicianPhoto,
                      collectionStatus: _collectionStatus,
                      isRefreshing:     _isTechRefreshing,
                      onRefresh:        b.bookingIdNum != null ? _refreshTechStatus : null,
                      onTrack: (_collectionStatus == 'en_route' && _technicianId != null && b.bookingIdNum != null)
                          ? () => Navigator.push(context, MaterialPageRoute(
                              builder: (_) => TrackingMapScreen(
                                bookingId:      b.bookingIdNum!,
                                patientId:      int.tryParse(b.member.id) ?? 0,
                                trackingId:     b.bookingIdNum!.toString(),
                                technicianId:   _technicianId!,
                                technicianName: _technicianName ?? '',
                                patientLat:     _patientLat,
                                patientLng:     _patientLng,
                                patientAddress: b.address ?? '',
                                isPatientView:  true,
                              ),
                            ))
                          : null,
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Tests
                  _DetailSection(
                    title: 'Tests & Packages (${b.tests.length})',
                    rows: b.tests.map((t) => _DetailRow(
                      t.type == 'package' ? Icons.inventory_2_outlined : Icons.science_outlined,
                      t.name, '₹${t.finalPrice.toInt()}', valueBold: true,
                    )).toList(),
                  ),

                  // Pre-test instructions (only if any test has them)
                  Builder(builder: (context) {
                    final withInstr = b.tests
                        .where((t) => t.preInstructions != null)
                        .toList();
                    if (withInstr.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Preparation Instructions',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600,
                                  color: AppColors.textSecondary, letterSpacing: 0.3)),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFFDE7),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFFFEB3B)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: withInstr.map((t) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Icon(Icons.info_outline_rounded,
                                        size: 15, color: Color(0xFFF9A825)),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(t.name,
                                              style: const TextStyle(
                                                  fontSize: 12, fontWeight: FontWeight.w600,
                                                  color: AppColors.textPrimary)),
                                          const SizedBox(height: 2),
                                          Text(t.preInstructions!,
                                              style: const TextStyle(
                                                  fontSize: 12, color: AppColors.textSecondary,
                                                  height: 1.4)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              )).toList(),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),

                  if (_canEditTests) ...[
                    const SizedBox(height: 10),
                    GestureDetector(
                      onTap: _showEditTests,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.brandGreen),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.edit_outlined, size: 16, color: AppColors.brandGreen),
                            SizedBox(width: 8),
                            Text('Edit Tests / Packages',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                    color: AppColors.brandGreen)),
                          ],
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Payment
                  _DetailSection(
                    title: 'Payment',
                    rows: [
                      _DetailRow(Icons.receipt_outlined, 'Tests Total', '₹${b.testsTotal.toInt()}'),
                      if (b.serviceCharge > 0)
                        _DetailRow(Icons.add_circle_outline, 'Service Charge', '+ ₹${b.serviceCharge.toInt()}'),
                      _DetailRow(Icons.calculate_outlined, 'Grand Total', '₹${b.grandTotal.toInt()}', valueBold: true),
                      _DetailRow(Icons.check_circle_outline, 'Paid',
                          '₹${b.paidAmount.toInt()}', valueColor: AppColors.brandGreen),
                      if (b.amountDue > 0)
                        _DetailRow(Icons.pending_outlined,
                            b.mode == 'Home Collection' ? 'Due at Collection' : 'Due at Lab',
                            '₹${b.amountDue.toInt()}', valueColor: const Color(0xFFE65100)),
                    ],
                  ),

                  // Bill receipt actions — only when customer has paid something
                  if (b.paidAmount > 0) ...[
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _billBusy ? null : _downloadBill,
                        icon: _billBusy
                            ? const SizedBox(width: 14, height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen))
                            : const Icon(Icons.download_outlined, size: 16, color: AppColors.brandGreen),
                        label: const Text('Download Bill',
                            style: TextStyle(fontSize: 13, color: AppColors.brandGreen)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.brandGreen),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _billBusy ? null : _shareBill,
                        icon: const Icon(Icons.share_outlined, size: 16, color: AppColors.brandGreen),
                        label: const Text('Share Bill',
                            style: TextStyle(fontSize: 13, color: AppColors.brandGreen)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.brandGreen),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                  ]),
                  ], // end paidAmount > 0

                  // Prescription section
                  if (b.prescriptionImages.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    const Text('Prescription',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
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
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Status badge
                          Row(children: [
                            Icon(
                              b.prescriptionStatus == 'verified'
                                  ? Icons.verified_outlined
                                  : Icons.hourglass_top_rounded,
                              size: 14,
                              color: b.prescriptionStatus == 'verified'
                                  ? AppColors.brandGreen
                                  : const Color(0xFFE65100),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              b.prescriptionStatus == 'verified'
                                  ? 'Prescription Verified'
                                  : 'Awaiting Verification',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: b.prescriptionStatus == 'verified'
                                    ? AppColors.brandGreen
                                    : const Color(0xFFE65100),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          // Thumbnails
                          SizedBox(
                            height: 80,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: b.prescriptionImages.length,
                              separatorBuilder: (_, __) => const SizedBox(width: 8),
                              itemBuilder: (_, i) => ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  b.prescriptionImages[i],
                                  width: 80, height: 80,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 80, height: 80,
                                    color: AppColors.brandGreenSurface,
                                    child: const Icon(Icons.image_not_supported_outlined,
                                        color: AppColors.brandGreen, size: 28),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text('${b.prescriptionImages.length} image${b.prescriptionImages.length == 1 ? '' : 's'} uploaded',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                  ],

                  // Pay Now button — only shown after prescription is verified (or no doc required)
                  if (_paymentPending && !_prescriptionBlocking) ...[
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: _isProcessing ? null : _triggerPayment,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: _isProcessing
                              ? AppColors.brandGreen.withValues(alpha: 0.5)
                              : const Color(0xFF1565C0),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _isProcessing
                            ? const Center(child: SizedBox(width: 20, height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white))))
                            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                const Icon(Icons.payment_outlined, size: 18, color: Colors.white),
                                const SizedBox(width: 8),
                                Text(
                                  'Pay ₹${(b.amountDue > 0 ? b.amountDue : b.grandTotal).toInt()} via Razorpay',
                                  style: const TextStyle(fontSize: 14,
                                      fontWeight: FontWeight.w600, color: Colors.white),
                                ),
                              ]),
                      ),
                    ),
                  ],

                  // Report section for completed bookings
                  if (b.status == 'Completed') ...[
                    const SizedBox(height: 16),
                    Row(children: [
                      const Icon(Icons.science_outlined, size: 15, color: AppColors.textHint),
                      const SizedBox(width: 6),
                      const Text('Test Results',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                      const Spacer(),
                      if (_resultsLoading)
                        const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                    ]),
                    const SizedBox(height: 10),
                    if (_resultsLoading)
                      const SizedBox.shrink()
                    else if (_testResults.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.divider),
                        ),
                        child: const Row(children: [
                          Icon(Icons.hourglass_empty_rounded, size: 16, color: AppColors.textHint),
                          SizedBox(width: 8),
                          Text('Results not available yet',
                              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                        ]),
                      )
                    else
                      Column(
                        children: _testResults.map((r) {
                          final flag = r['result_flag'] as String? ?? '';
                          final flagColor = flag == 'critical' ? const Color(0xFFD32F2F)
                              : (flag == 'high' || flag == 'low') ? const Color(0xFFE65100)
                              : AppColors.brandGreen;
                          final flagLabel = flag == 'critical' ? 'Critical'
                              : flag == 'high' ? 'High'
                              : flag == 'low'  ? 'Low'
                              : 'Normal';
                          final releasedAt = r['released_at'] as String?;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: flagColor.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: flagColor.withValues(alpha: 0.2)),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(child: Text(r['test_name'] as String? ?? '',
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                          color: AppColors.textPrimary))),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: flagColor.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(flagLabel,
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                                            color: flagColor)),
                                  ),
                                ]),
                                const SizedBox(height: 6),
                                Row(children: [
                                  Text(
                                    '${r['result_value'] ?? '—'} ${r['result_unit'] ?? ''}'.trim(),
                                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: flagColor),
                                  ),
                                  if (r['reference_range'] != null) ...[
                                    const SizedBox(width: 10),
                                    Text('Ref: ${r['reference_range']}',
                                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                  ],
                                ]),
                                if (r['result_remarks'] != null && (r['result_remarks'] as String).isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(r['result_remarks'] as String,
                                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                ],
                                if (releasedAt != null) ...[
                                  const SizedBox(height: 4),
                                  Text('Released: ${_formatDate(DateTime.tryParse(releasedAt) ?? DateTime.now())}',
                                      style: const TextStyle(fontSize: 10, color: AppColors.textHint)),
                                ],
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Technician Card (always shown for Home Collection bookings) ───────────────

class _TechnicianCard extends StatelessWidget {
  final String? name;            // null = no technician assigned yet
  final String? mobile;
  final String? photoUrl;
  final String? collectionStatus;
  final VoidCallback? onTrack;   // non-null only when en_route + technicianId known
  final VoidCallback? onRefresh;
  final bool isRefreshing;

  const _TechnicianCard({
    this.name,
    this.mobile,
    this.photoUrl,
    this.collectionStatus,
    this.onTrack,
    this.onRefresh,
    this.isRefreshing = false,
  });

  bool get _assigned => name != null && name!.isNotEmpty;

  String get _statusLabel {
    switch (collectionStatus) {
      case 'assigned':           return 'Assigned';
      case 'en_route':           return 'On the way';
      case 'arrived':            return 'Arrived';
      case 'collection_started': return 'Collection Started';
      case 'otp_verified':        return 'Sample Collected';
      case 'sample_collected':   return 'Sample Collected';
      case 'handed_to_lab':      return 'Handed to Lab';
      default:                   return 'Assigned';
    }
  }

  Color get _statusColor {
    switch (collectionStatus) {
      case 'en_route':           return const Color(0xFF1565C0);
      case 'arrived':            return const Color(0xFF2E7D32);
      case 'collection_started': return const Color(0xFF6A1B9A);
      case 'otp_verified':        return const Color(0xFF2E7D32);
      case 'sample_collected':   return const Color(0xFF2E7D32);
      case 'handed_to_lab':      return AppColors.brandGreen;
      default:                   return AppColors.brandGreen;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Technician Status',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary, letterSpacing: 0.3)),
            const Spacer(),
            if (isRefreshing)
              const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen),
              )
            else
              GestureDetector(
                onTap: onRefresh,
                child: const Icon(Icons.refresh_rounded, size: 20, color: AppColors.brandGreen),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _assigned ? _assignedRow(context) : _pendingRow(),
              if (onTrack != null) ...[
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: onTrack,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.my_location_rounded, size: 16, color: Colors.white),
                        SizedBox(width: 8),
                        Text('Track Live',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _pendingRow() {
    return Row(
      children: [
        Container(
          width: 52, height: 52,
          decoration: BoxDecoration(
            color: AppColors.brandGreenSurface,
            borderRadius: BorderRadius.circular(26),
          ),
          child: const Icon(Icons.person_search_outlined, size: 26, color: AppColors.brandGreen),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Finding Technician',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              SizedBox(height: 4),
              Text('A technician will be assigned shortly',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _assignedRow(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: AppColors.brandGreenSurface,
          // Image.network's errorBuilder (unlike CircleAvatar.backgroundImage,
          // which has no load-failure fallback) lets a broken/404 photo URL
          // fall back to the person icon instead of rendering a blank circle.
          child: photoUrl != null && photoUrl!.isNotEmpty
              ? ClipOval(
                  child: Image.network(
                    photoUrl!,
                    width: 52,
                    height: 52,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.person_outline, size: 26, color: AppColors.brandGreen),
                  ),
                )
              : const Icon(Icons.person_outline, size: 26, color: AppColors.brandGreen),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name!,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_statusLabel,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: _statusColor)),
              ),
            ],
          ),
        ),
        if (mobile != null && mobile!.isNotEmpty &&
            collectionStatus != 'sample_collected' &&
            collectionStatus != 'handed_to_lab')
          GestureDetector(
            onTap: () => launchUrl(Uri(scheme: 'tel', path: mobile)),
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: AppColors.brandGreenSurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.phone_outlined, size: 20, color: AppColors.brandGreen),
            ),
          ),
      ],
    );
  }
}

class _DetailSection extends StatelessWidget {
  final String title;
  final List<_DetailRow> rows;
  const _DetailSection({required this.title, required this.rows});

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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                ],
              ),
            )).toList(),
          ),
        ),
      ],
    );
  }
}

class _DetailRow {
  final IconData icon;
  final String label;
  final String value;
  final bool valueBold;
  final Color? valueColor;
  const _DetailRow(this.icon, this.label, this.value, {this.valueBold = false, this.valueColor});
}

// ─── Feedback Sheet ───────────────────────────────────────────────────────────

// ─── Cancel Sheet ─────────────────────────────────────────────────────────────

class _CancelSheet extends StatefulWidget {
  final BookingModel booking;
  final bool chargeApplies;
  final Future<void> Function(String? reason) onConfirm;
  const _CancelSheet({required this.booking, required this.chargeApplies, required this.onConfirm});

  @override
  State<_CancelSheet> createState() => _CancelSheetState();
}

class _CancelSheetState extends State<_CancelSheet> {
  static const _reasons = ['Changed plans', 'Emergency', 'Wrong booking', 'Other'];
  String? _reason;
  bool _submitting = false;

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      await widget.onConfirm(_reason);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final arrivedWarning = widget.chargeApplies;
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Icons.cancel_outlined, color: Color(0xFFD32F2F), size: 20),
            const SizedBox(width: 8),
            const Text('Cancel Booking',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          ]),
          const SizedBox(height: 4),
          Text('${widget.booking.member.name} · ${widget.booking.id}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          if (arrivedWarning) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFFCC02)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Color(0xFFE65100)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The technician has arrived. A service charge will be deducted from your refund.',
                      style: TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          const Text('Reason (optional)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _reasons.map((r) {
              final selected = _reason == r;
              return GestureDetector(
                onTap: () => setState(() => _reason = selected ? null : r),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: selected ? const Color(0xFFFFEBEE) : AppColors.background,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: selected ? const Color(0xFFD32F2F) : AppColors.divider),
                  ),
                  child: Text(r,
                      style: TextStyle(
                          fontSize: 12,
                          color: selected ? const Color(0xFFD32F2F) : AppColors.textSecondary,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.divider),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                child: const Text('Go Back',
                    style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFD32F2F),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                child: _submitting
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Confirm Cancel',
                        style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

// ─── Feedback Sheet ───────────────────────────────────────────────────────────

class _FeedbackSheet extends StatefulWidget {
  final BookingModel booking;
  final Future<void> Function(int rating, String comment) onSubmit;
  const _FeedbackSheet({required this.booking, required this.onSubmit});

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  int _rating = 0;
  int _hoveredRating = 0;
  final _commentCtrl = TextEditingController();
  bool _submitting = false;

  final List<String> _quickTags = [
    'On time', 'Professional', 'Friendly', 'Careful',
    'Clean kit', 'Quick process', 'Would recommend',
  ];
  final Set<String> _selectedTags = {};

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  String get _ratingLabel {
    switch (_rating) {
      case 1: return 'Poor';
      case 2: return 'Fair';
      case 3: return 'Good';
      case 4: return 'Very Good';
      case 5: return 'Excellent!';
      default: return 'Tap to rate';
    }
  }

  Color get _ratingColor {
    if (_rating <= 2) return const Color(0xFFD32F2F);
    if (_rating == 3) return const Color(0xFFE65100);
    return AppColors.brandGreen;
  }

  Future<void> _submit() async {
    if (_rating == 0) return;
    setState(() => _submitting = true);
    final comment = [
      ..._selectedTags,
      if (_commentCtrl.text.trim().isNotEmpty) _commentCtrl.text.trim(),
    ].join(', ');
    try {
      await widget.onSubmit(_rating, comment);
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).padding.bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40, height: 4,
                decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
              ),
            ),

            const Text('Rate your experience',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 4),
            Text(
              'Technician visit on ${_formatDate(widget.booking.date)} · ${widget.booking.timeSlot}',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),

            // Star rating
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (i) {
                final starVal = i + 1;
                final filled = starVal <= (_hoveredRating > 0 ? _hoveredRating : _rating);
                return GestureDetector(
                  onTap: () => setState(() => _rating = starVal),
                  onTapDown: (_) => setState(() => _hoveredRating = starVal),
                  onTapUp: (_) => setState(() => _hoveredRating = 0),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        filled ? Icons.star_rounded : Icons.star_border_rounded,
                        key: ValueKey('$starVal-$filled'),
                        size: 44,
                        color: filled ? const Color(0xFFFFB300) : AppColors.divider,
                      ),
                    ),
                  ),
                );
              }),
            ),

            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                _ratingLabel,
                key: ValueKey(_rating),
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _rating > 0 ? _ratingColor : AppColors.textHint),
              ),
            ),

            const SizedBox(height: 20),

            // Quick tags
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('What went well?',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _quickTags.map((tag) {
                final sel = _selectedTags.contains(tag);
                return GestureDetector(
                  onTap: () => setState(() {
                    sel ? _selectedTags.remove(tag) : _selectedTags.add(tag);
                  }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: sel ? AppColors.brandGreenSurface : AppColors.background,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: sel ? AppColors.brandGreen : AppColors.divider,
                          width: sel ? 1.5 : 1),
                    ),
                    child: Text(tag,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                            color: sel ? AppColors.brandGreen : AppColors.textSecondary)),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 16),

            // Comment
            TextField(
              controller: _commentCtrl,
              maxLines: 3,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Additional comments (optional)',
                hintStyle: const TextStyle(fontSize: 13, color: AppColors.textHint),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.divider)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.divider)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                contentPadding: const EdgeInsets.all(14),
              ),
            ),

            const SizedBox(height: 20),

            // Submit
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _rating > 0 && !_submitting ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  disabledBackgroundColor: AppColors.brandGreen.withValues(alpha: 0.35),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _submitting
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                    : const Text('Submit Feedback',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${months[d.month]} ${d.year}';
  }
}

// ─── Edit Tests Sheet ─────────────────────────────────────────────────────────

class _EditTestsSheet extends StatefulWidget {
  final BookingModel booking;
  final VoidCallback onSaved;
  const _EditTestsSheet({required this.booking, required this.onSaved});

  @override
  State<_EditTestsSheet> createState() => _EditTestsSheetState();
}

class _EditTestsSheetState extends State<_EditTestsSheet> {
  List<TestModel> _allTests = [];
  final Set<String> _selectedIds = {};
  Set<String> _initialIds = {};
  bool _loading = true;
  bool _saving = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // Prescription upload (only shown when a selected test needs it)
  final List<Uint8List> _prescriptions = [];
  bool _isPicking = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadTests();
    _searchCtrl.addListener(() => setState(() => _searchQuery = _searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTests() async {
    setState(() => _loading = true);
    try {
      final tests = await ApiService.getPackages();

      // Real product_id matches (id != '0')
      final realIds = widget.booking.tests
          .where((t) => t.id != '0')
          .map((t) => t.id)
          .toSet();

      // Fallback: old bookings with product_id=0 — match by name, first occurrence only
      final fallbackNames = widget.booking.tests
          .where((t) => t.id == '0')
          .map((t) => t.name.toLowerCase())
          .toSet();

      final preselected = <String>{};
      preselected.addAll(tests.where((t) => realIds.contains(t.id)).map((t) => t.id));
      for (final name in fallbackNames) {
        final match = tests.cast<TestModel?>().firstWhere(
          (t) => t!.name.toLowerCase() == name,
          orElse: () => null,
        );
        if (match != null) preselected.add(match.id);
      }

      setState(() {
        _allTests = tests;
        _selectedIds.addAll(preselected);
        _initialIds = Set.from(preselected);
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  List<TestModel> get _filtered {
    if (_searchQuery.isEmpty) return _allTests;
    final q = _searchQuery.toLowerCase();
    return _allTests
        .where((t) =>
            t.name.toLowerCase().contains(q) ||
            t.category.toLowerCase().contains(q))
        .toList();
  }

  // Prescription is required only when the user added a NEW doc-required test
  // that was not part of the original booking.
  bool get _needsPrescription =>
      _allTests
          .where((t) => _selectedIds.contains(t.id) && !_initialIds.contains(t.id))
          .any((t) => t.docRequired);

  double get _itemsTotal => _allTests
      .where((t) => _selectedIds.contains(t.id))
      .fold(0.0, (s, t) => s + t.finalPrice);

  double get _serviceCharge =>
      widget.booking.mode == 'Home Collection' ? widget.booking.serviceCharge : 0.0;

  double get _total => _itemsTotal + _serviceCharge;

  void _showPresSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(ctx).padding.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
          ),
          _EditPresSourceTile(
            icon: Icons.camera_alt_outlined,
            title: 'Camera',
            subtitle: 'Take a photo now',
            onTap: () { Navigator.pop(ctx); _pickPres(ImageSource.camera); },
          ),
          const SizedBox(height: 8),
          _EditPresSourceTile(
            icon: Icons.photo_library_outlined,
            title: 'Gallery',
            subtitle: 'Choose from your photos',
            onTap: () { Navigator.pop(ctx); _pickPres(ImageSource.gallery); },
          ),
        ]),
      ),
    );
  }

  Future<void> _pickPres(ImageSource source) async {
    if (_isPicking || _prescriptions.length >= 5) return;
    setState(() => _isPicking = true);
    try {
      if (source == ImageSource.gallery) {
        final images = await _picker.pickMultiImage(imageQuality: 80);
        if (images.isNotEmpty) {
          final toAdd = images.take(5 - _prescriptions.length);
          final bytes = await Future.wait(toAdd.map((f) => f.readAsBytes()));
          setState(() => _prescriptions.addAll(bytes));
        }
      } else {
        final img = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
        if (img != null) {
          final bytes = await img.readAsBytes();
          setState(() => _prescriptions.add(bytes));
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _isPicking = false);
  }

  void _viewImage(int index) {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => _EditPresViewerPage(images: List.from(_prescriptions), initialIndex: index),
    ));
  }

  Future<void> _save() async {
    if (_selectedIds.isEmpty || _saving || widget.booking.bookingIdNum == null) return;
    setState(() => _saving = true);
    try {
      final selectedTests = _allTests.where((t) => _selectedIds.contains(t.id)).toList();
      final items = selectedTests.map((t) => {
        'packageId':     t.id,
        'originalPrice': t.originalPrice,
        'finalPrice':    t.finalPrice,
      }).toList();
      final result = await ApiService.updateBookingItems(
        bookingId:     widget.booking.bookingIdNum!,
        items:         items,
        serviceCharge: _serviceCharge,
      );
      if (!mounted) return;
      if (result != null && result['success'] == true) {
        // Upload any collected prescriptions (non-fatal if it fails)
        if (_prescriptions.isNotEmpty) {
          try {
            final rawIds = result['docRequiredItemIds'];
            final bookingItemId = (rawIds is List && rawIds.isNotEmpty)
                ? rawIds[0] as int?
                : null;
            final urls = <String>[];
            for (final bytes in _prescriptions) {
              final url = await ApiService.uploadFile(
                  bytes, 'pres_${DateTime.now().millisecondsSinceEpoch}.jpg');
              if (url != null) urls.add(url);
            }
            if (urls.isNotEmpty) {
              await ApiService.savePrescription(
                bookingId:     widget.booking.bookingIdNum!,
                patientId:     int.tryParse(widget.booking.member.id) ?? 0,
                bookingItemId: bookingItemId,
                imageUrls:     urls,
              );
            }
          } catch (_) {}
        }
        if (!mounted) return;
        Navigator.pop(context);
        widget.onSaved();
      } else {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result?['message'] as String? ?? 'Failed to update booking'),
          backgroundColor: Colors.red[700],
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildPrescriptionSection() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFFFCC02))),
        color: Color(0xFFFFF3E0),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.description_outlined, size: 15, color: Color(0xFFE65100)),
          const SizedBox(width: 6),
          const Text('Prescription',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFE65100))),
          const Text(' *',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFD32F2F))),
          const Spacer(),
          if (_prescriptions.isNotEmpty)
            Text('${_prescriptions.length}/5',
                style: const TextStyle(fontSize: 11, color: Color(0xFF795548))),
        ]),
        const SizedBox(height: 2),
        const Text('Upload a valid prescription for the selected test(s)',
            style: TextStyle(fontSize: 11, color: Color(0xFF795548), height: 1.3)),
        const SizedBox(height: 10),
        SizedBox(
          height: 104,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(top: 8),
            children: [
              ..._prescriptions.asMap().entries.map((e) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(clipBehavior: Clip.none, children: [
                  GestureDetector(
                    onTap: () => _viewImage(e.key),
                    child: Container(
                      width: 88, height: 88,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(e.value, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                  Positioned(bottom: 4, right: 4,
                    child: IgnorePointer(
                      child: Container(
                        width: 24, height: 24,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.fullscreen_rounded, size: 15, color: Colors.white),
                      ),
                    ),
                  ),
                  Positioned(top: -6, right: -6, child: GestureDetector(
                    onTap: () => setState(() => _prescriptions.removeAt(e.key)),
                    child: Container(
                      width: 22, height: 22,
                      decoration: const BoxDecoration(color: Color(0xFFD32F2F), shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 13, color: Colors.white),
                    ),
                  )),
                ]),
              )),
              if (_prescriptions.length < 5)
                GestureDetector(
                  onTap: _isPicking ? null : _showPresSourcePicker,
                  child: Container(
                    width: 88, height: 88,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _prescriptions.isEmpty ? const Color(0xFFE65100) : const Color(0xFFFFCC02),
                        width: 1.5,
                      ),
                    ),
                    child: _isPicking
                        ? const Center(child: SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)))
                        : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(
                              _prescriptions.isEmpty ? Icons.upload_file_outlined : Icons.add_photo_alternate_outlined,
                              size: 26,
                              color: _prescriptions.isEmpty ? const Color(0xFFE65100) : const Color(0xFF795548),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _prescriptions.isEmpty ? 'Upload' : 'Add more',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: _prescriptions.isEmpty ? const Color(0xFFE65100) : const Color(0xFF795548),
                              ),
                            ),
                          ]),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88),
      child: Column(
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40, height: 4,
              decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Edit Tests / Packages',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      Text('Tap to select or deselect',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                if (_selectedIds.isNotEmpty)
                  Text('₹${_total.toInt()}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                          color: AppColors.brandGreen)),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search tests...',
                hintStyle: const TextStyle(fontSize: 13, color: AppColors.textHint),
                prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textHint),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.brandGreen))
                : _filtered.isEmpty
                    ? const Center(
                        child: Text('No tests found',
                            style: TextStyle(color: AppColors.textSecondary)))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: _filtered.length,
                        itemBuilder: (_, i) {
                          final t = _filtered[i];
                          final selected = _selectedIds.contains(t.id);
                          return GestureDetector(
                            onTap: () => setState(() {
                              selected ? _selectedIds.remove(t.id) : _selectedIds.add(t.id);
                              if (!_needsPrescription) _prescriptions.clear();
                            }),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppColors.brandGreenSurface
                                    : AppColors.background,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: selected ? AppColors.brandGreen : AppColors.divider,
                                  width: selected ? 1.5 : 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    t.type == 'package'
                                        ? Icons.inventory_2_outlined
                                        : Icons.science_outlined,
                                    size: 18,
                                    color: selected ? AppColors.brandGreen : AppColors.textHint,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(t.name,
                                            style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: selected
                                                    ? AppColors.brandGreen
                                                    : AppColors.textPrimary)),
                                        if (t.category.isNotEmpty)
                                          Text(t.category,
                                              style: const TextStyle(
                                                  fontSize: 11, color: AppColors.textSecondary)),
                                      ],
                                    ),
                                  ),
                                  Text('₹${t.finalPrice.toInt()}',
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: selected
                                              ? AppColors.brandGreen
                                              : AppColors.textPrimary)),
                                  const SizedBox(width: 8),
                                  Icon(
                                    selected
                                        ? Icons.check_circle_rounded
                                        : Icons.circle_outlined,
                                    size: 20,
                                    color: selected ? AppColors.brandGreen : AppColors.divider,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          if (!_loading && _needsPrescription) _buildPrescriptionSection(),

          Container(
            padding: EdgeInsets.fromLTRB(
                16, 12, 16, MediaQuery.of(context).padding.bottom + 16),
            decoration: const BoxDecoration(
              color: AppColors.white,
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _selectedIds.isEmpty || _saving ||
                    (_needsPrescription && _prescriptions.isEmpty)
                    ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  disabledBackgroundColor: AppColors.brandGreen.withValues(alpha: 0.35),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                    : Text(
                        _selectedIds.isEmpty
                            ? 'Select at least one test'
                            : (_needsPrescription && _prescriptions.isEmpty)
                                ? 'Upload prescription to continue'
                                : 'Update Booking · ₹${_total.toInt()}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w500),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Prescription source picker tile ─────────────────────────────────────────

class _EditPresSourceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _EditPresSourceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: AppColors.brandGreenSurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AppColors.brandGreen, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textHint, size: 20),
          ],
        ),
      ),
    );
  }
}

// ─── Full-screen prescription image viewer ────────────────────────────────────

class _EditPresViewerPage extends StatefulWidget {
  final List<Uint8List> images;
  final int initialIndex;

  const _EditPresViewerPage({required this.images, required this.initialIndex});

  @override
  State<_EditPresViewerPage> createState() => _EditPresViewerPageState();
}

class _EditPresViewerPageState extends State<_EditPresViewerPage> {
  late final PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_current + 1} / ${widget.images.length}',
            style: const TextStyle(fontSize: 14, color: Colors.white70)),
        centerTitle: true,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _current = i),
              itemBuilder: (_, i) => InteractiveViewer(
                minScale: 0.8,
                maxScale: 4.0,
                child: Center(
                  child: Image.memory(widget.images[i], fit: BoxFit.contain),
                ),
              ),
            ),
          ),
          if (widget.images.length > 1)
            Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 16, top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.images.length, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _current ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _current ? AppColors.brandGreen : Colors.white38,
                    borderRadius: BorderRadius.circular(3),
                  ),
                )),
              ),
            ),
        ],
      ),
    );
  }
}
