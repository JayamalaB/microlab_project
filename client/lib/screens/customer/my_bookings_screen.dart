import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'checkout_screen.dart';
import 'booking_widgets.dart';
import 'package:microlab/models.dart';

class MyBookingsScreen extends StatefulWidget {
  final BookingModel? initialBooking;
  final bool embedded;
  const MyBookingsScreen({super.key, this.initialBooking, this.embedded = false});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Mock bookings list — replace with GET /api/bookings
  late List<BookingModel> _bookings;

  final List<String> _tabs = ['All', 'Upcoming', 'Completed', 'Cancelled'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _buildMockBookings();
  }

  void _buildMockBookings() {
    // TODO: replace with GET /api/bookings
    final sampleMember = MemberModel(
      id: 's1', name: 'Ravi Kumar', mobile: '9876543210',
      gender: 'Male', location: 'Chennai',
      address: '12, Gandhi Street, T Nagar, Chennai - 600017',
      relation: 'Self', dob: DateTime(1985, 6, 15),
    );
    final List<TestModel> sampleTests = [
      TestModel.fromJson({'id': '1', 'name': 'HbA1c', 'type': 'single', 'category': 'Diabetes', 'description': '3-month average blood sugar', 'offer': 'no', 'original_price': '600', 'final_price': '540', 'doc_req': 'no', 'report_sts': '48 hrs'}),
      TestModel.fromJson({'id': '2', 'name': 'CBC', 'type': 'single', 'category': 'General', 'description': 'Complete blood count', 'offer': 'no', 'original_price': '350', 'final_price': '350', 'doc_req': 'no', 'report_sts': '24 hrs'}),
    ];

    _bookings = [
      // Upcoming
      BookingModel(
        id: 'BK00123456', member: sampleMember, tests: sampleTests,
        mode: 'Home Collection', city: 'Chennai', pincode: '600017',
        address: '12, Gandhi Street, T Nagar',
        date: DateTime.now().add(const Duration(days: 2)),
        timeSlot: '10:00 AM', paymentType: 'service_charge',
        serviceCharge: 99, testsTotal: 890, grandTotal: 989, paidAmount: 99,
        status: 'Technician Allocated', createdAt: DateTime.now().subtract(const Duration(hours: 3)),
        docRequired: false, docVerified: false,
      ),
      BookingModel(
        id: 'BK00123789', member: sampleMember,
        tests: [TestModel.fromJson({'id': '5', 'name': 'Diabetes Care Package', 'type': 'package', 'category': 'Diabetes', 'description': 'HbA1c + Fasting + Insulin', 'offer': 'yes', 'original_price': '1800', 'offer_pct': '20', 'final_price': '1440', 'doc_req': 'no', 'report_sts': '48 hrs'})],
        mode: 'Lab Test', branch: null,
        date: DateTime.now().add(const Duration(days: 5)),
        timeSlot: '1:00 PM', paymentType: 'full',
        serviceCharge: 99, testsTotal: 1440, grandTotal: 1539, paidAmount: 1539,
        status: 'In Progress', createdAt: DateTime.now().subtract(const Duration(days: 1)),
        docRequired: false, docVerified: false,
      ),
      // Completed
      BookingModel(
        id: 'BK00122001', member: sampleMember,
        tests: [TestModel.fromJson({'id': '4', 'name': 'Lipid Profile', 'type': 'single', 'category': 'Heart', 'description': 'Cholesterol, HDL, LDL', 'offer': 'no', 'original_price': '500', 'final_price': '500', 'doc_req': 'no', 'report_sts': '24 hrs'})],
        mode: 'Home Collection', city: 'Chennai', pincode: '600017',
        address: '12, Gandhi Street, T Nagar',
        date: DateTime.now().subtract(const Duration(days: 7)),
        timeSlot: '4:00 PM', paymentType: 'full',
        serviceCharge: 99, testsTotal: 500, grandTotal: 599, paidAmount: 599,
        status: 'Completed', createdAt: DateTime.now().subtract(const Duration(days: 8)),
        docRequired: false, docVerified: false,
        reportUrl: 'https://example.com/reports/BK00122001.pdf',
        reportReadyDate: DateTime.now().subtract(const Duration(days: 6)),
      ),
    ];

    // Add the real booking from checkout if provided (add at front)
    if (widget.initialBooking != null) {
      _bookings.insert(0, widget.initialBooking!);
    }
  }

  List<BookingModel> _filtered(String tab) {
    if (tab == 'All') return _bookings;
    if (tab == 'Upcoming') {
      return _bookings.where((b) =>
        b.status == 'Technician Allocated' || b.status == 'In Progress'
      ).toList();
    }
    if (tab == 'Completed') return _bookings.where((b) => b.status == 'Completed').toList();
    if (tab == 'Cancelled') return _bookings.where((b) => b.status == 'Cancelled').toList();
    return _bookings;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        children: [
          Container(
            color: AppColors.brandGreen,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 14, 16, 8),
                  child: const Text('My Bookings',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                ),
                TabBar(
                  controller: _tabController,
                  indicatorColor: Colors.white,
                  indicatorWeight: 3,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white60,
                  labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  unselectedLabelStyle:
                      const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: _tabs.map((t) => Tab(text: t)).toList(),
                ),
              ],
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: const Color(0xFFF4F6F8),
              child: TabBarView(
                controller: _tabController,
                children: _tabs.map((tab) {
                  final list = _filtered(tab);
                  if (list.isEmpty) return _emptyState(tab);
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _BookingCard(
                      booking: list[i],
                      onTap: () => _showBookingDetail(list[i]),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
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
        bottom: TabBar(
          controller: _tabController,
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
      body: TabBarView(
        controller: _tabController,
        children: _tabs.map((tab) {
          final list = _filtered(tab);
          if (list.isEmpty) return _emptyState(tab);
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            itemCount: list.length,
            itemBuilder: (_, i) => _BookingCard(
              booking: list[i],
              onTap: () => _showBookingDetail(list[i]),
            ),
          );
        }).toList(),
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
              width: 72, height: 72,
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
              'Your booked tests will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  void _showBookingDetail(BookingModel booking) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BookingDetailSheet(booking: booking),
    );
  }
}

void _showFeedback(BuildContext context, BookingModel booking) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _FeedbackSheet(
      booking: booking,
      onSubmit: (rating, comment) {
        // TODO: POST /api/bookings/${booking.id}/feedback { rating, comment }
        // For now show a snackbar; in real app update state with new rating
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
      },
    ),
  );
}

void _downloadReport(BuildContext context, BookingModel booking) {
  // TODO: url_launcher → launch(booking.reportUrl!)
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Row(children: [
      const Icon(Icons.download_outlined, color: Colors.white, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text('Downloading report for ${booking.member.name}…')),
    ]),
    backgroundColor: AppColors.brandGreen,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  ));
}

// ─── Booking Card ─────────────────────────────────────────────────────────────

class _BookingCard extends StatelessWidget {
  final BookingModel booking;
  final VoidCallback onTap;
  const _BookingCard({required this.booking, required this.onTap});

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'Completed': return AppColors.brandGreen;
      case 'Cancelled': return const Color(0xFFD32F2F);
      case 'In Progress': return const Color(0xFF1565C0);
      default: return const Color(0xFFE65100);
    }
  }

  IconData _statusIcon(String s) {
    switch (s) {
      case 'Completed': return Icons.check_circle_outline;
      case 'Cancelled': return Icons.cancel_outlined;
      case 'In Progress': return Icons.directions_run_rounded;
      default: return Icons.person_pin_outlined;
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

                    // Feedback button for completed bookings
                    if (booking.status == 'Completed' && booking.rating == null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () => _showFeedback(context, booking),
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
                    if (booking.status == 'Completed' && booking.rating != null) ...[
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

                    // Download report for completed bookings
                    if (booking.status == 'Completed' && booking.reportUrl != null) ...[
                      const SizedBox(height: 10),
                      GestureDetector(
                        onTap: () => _downloadReport(context, booking),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 9),
                          decoration: BoxDecoration(
                            color: AppColors.brandGreenSurface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.brandGreenLight),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(Icons.download_outlined, size: 16, color: AppColors.brandGreen),
                              SizedBox(width: 6),
                              Text('Download Report',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
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

class _BookingDetailSheet extends StatelessWidget {
  final BookingModel booking;
  const _BookingDetailSheet({required this.booking});

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
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
                      Text(booking.id,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                BookingStatusBadge(status: booking.status),
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
                      _DetailRow(Icons.person_outline, 'Customer', booking.member.name),
                      _DetailRow(Icons.event_outlined, 'Date', _formatDate(booking.date)),
                      _DetailRow(Icons.schedule_outlined, 'Time', booking.timeSlot),
                      _DetailRow(
                        booking.mode == 'Home Collection' ? Icons.home_outlined : Icons.local_hospital_outlined,
                        'Mode', booking.mode,
                      ),
                      if (booking.isVip && booking.selectedTechnician != null)
                        _DetailRow(Icons.medical_services_outlined,
                            'Technician', booking.selectedTechnician!.name),
                      if (booking.isVip)
                        _DetailRow(Icons.star_rounded, 'Type',
                            'VIP Customer', valueColor: const Color(0xFFFFB300)),
                      if (booking.city != null)
                        _DetailRow(Icons.location_on_outlined, 'Location',
                            '${booking.city}${booking.pincode != null ? ', ${booking.pincode}' : ''}'),
                      if (booking.branch != null)
                        if (booking.branch != null) _DetailRow(Icons.local_hospital_outlined, 'Branch', booking.branch!.name),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Tests
                  _DetailSection(
                    title: 'Tests & Packages (${booking.tests.length})',
                    rows: booking.tests.map((t) => _DetailRow(
                      t.type == 'package' ? Icons.inventory_2_outlined : Icons.science_outlined,
                      t.name,
                      '₹${t.finalPrice.toInt()}',
                      valueBold: true,
                    )).toList(),
                  ),

                  const SizedBox(height: 16),

                  // Payment
                  _DetailSection(
                    title: 'Payment',
                    rows: [
                      _DetailRow(Icons.receipt_outlined, 'Tests Total', '₹${booking.testsTotal.toInt()}'),
                      _DetailRow(Icons.add_circle_outline, 'Service Charge', '+ ₹${booking.serviceCharge.toInt()}'),
                      _DetailRow(Icons.calculate_outlined, 'Grand Total', '₹${booking.grandTotal.toInt()}', valueBold: true),
                      _DetailRow(Icons.check_circle_outline, 'Paid',
                          '₹${booking.paidAmount.toInt()}', valueColor: AppColors.brandGreen),
                      if (booking.paymentType == 'service_charge')
                        _DetailRow(Icons.pending_outlined, 'Due at Collection',
                            '₹${(booking.grandTotal - booking.paidAmount).toInt()}',
                            valueColor: const Color(0xFFE65100)),
                    ],
                  ),

                  if (booking.docRequired) ...[
                    const SizedBox(height: 16),
                    _DetailSection(
                      title: 'Document',
                      rows: [
                        _DetailRow(
                          booking.docVerified ? Icons.verified_outlined : Icons.pending_outlined,
                          'Prescription',
                          booking.docVerified ? 'Verified' : 'Awaiting verification',
                          valueColor: booking.docVerified ? AppColors.brandGreen : const Color(0xFFE65100),
                        ),
                      ],
                    ),
                  ],

                  // Report section for completed bookings
                  if (booking.status == 'Completed') ...[
                    const SizedBox(height: 16),
                    _DetailSection(
                      title: 'Report',
                      rows: [
                        _DetailRow(
                          Icons.science_outlined,
                          'Status',
                          booking.reportUrl != null ? 'Ready to download' : 'Being processed',
                          valueColor: booking.reportUrl != null ? AppColors.brandGreen : const Color(0xFFE65100),
                        ),
                        if (booking.reportReadyDate != null)
                          _DetailRow(
                            Icons.event_available_outlined,
                            'Available since',
                            _formatDate(booking.reportReadyDate!),
                          ),
                      ],
                    ),
                    if (booking.reportUrl != null) ...[
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: () => _downloadReport(context, booking),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          decoration: BoxDecoration(
                            color: AppColors.brandGreen,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.download_outlined, size: 18, color: Colors.white),
                              SizedBox(width: 8),
                              Text('Download Report',
                                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
                    ],
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

class _FeedbackSheet extends StatefulWidget {
  final BookingModel booking;
  final void Function(int rating, String comment) onSubmit;
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
    await Future.delayed(const Duration(milliseconds: 600));
    final comment = [
      ..._selectedTags,
      if (_commentCtrl.text.trim().isNotEmpty) _commentCtrl.text.trim(),
    ].join(', ');
    widget.onSubmit(_rating, comment);
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
                  disabledBackgroundColor: AppColors.brandGreen.withOpacity(0.35),
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
