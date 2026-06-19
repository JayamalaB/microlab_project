import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models/technician_booking.dart';

class TechnicianHistoryScreen extends StatelessWidget {
  final String mobile;
  final bool embedded;
  const TechnicianHistoryScreen({super.key, required this.mobile, this.embedded = false});

  // Mock completed history — replace with GET /api/technician/bookings?status=completed
  static List<TechnicianBooking> _mockHistory() => [
    TechnicianBooking(
      id: 'BK00122001',
      customerName: 'Suresh Babu',
      customerPhone: '9876543212',
      address: '22, 100 Feet Road, Velachery',
      city: 'Chennai', pincode: '600042',
      date: DateTime.now().subtract(const Duration(days: 1)),
      timeSlot: '4:00 PM',
      testNames: ['Lipid Profile'],
      mode: 'Home Collection',
      status: 'Completed',
      serviceChargePaid: 99, testsTotal: 500,
      assignedAt: DateTime.now().subtract(const Duration(days: 2)),
    ),
    TechnicianBooking(
      id: 'BK00121555',
      customerName: 'Meena Devi',
      customerPhone: '9876543213',
      address: 'Anna Nagar Branch',
      city: 'Chennai', pincode: '600040',
      date: DateTime.now().subtract(const Duration(days: 3)),
      timeSlot: '10:00 AM',
      testNames: ['Full Body Checkup'],
      mode: 'Lab Test',
      status: 'Completed',
      docRequired: true, docVerified: true,
      serviceChargePaid: 99, testsTotal: 2625,
      assignedAt: DateTime.now().subtract(const Duration(days: 4)),
    ),
    TechnicianBooking(
      id: 'BK00120333',
      customerName: 'Rajan Pillai',
      customerPhone: '9876543230',
      address: '3, Besant Nagar, 5th Ave',
      city: 'Chennai', pincode: '600090',
      date: DateTime.now().subtract(const Duration(days: 5)),
      timeSlot: '9:00 AM',
      testNames: ['HbA1c', 'Fasting Glucose', 'Lipid Profile'],
      mode: 'Home Collection',
      status: 'Completed',
      serviceChargePaid: 99, testsTotal: 1160,
      assignedAt: DateTime.now().subtract(const Duration(days: 6)),
    ),
    TechnicianBooking(
      id: 'BK00119800',
      customerName: 'Kavitha S',
      customerPhone: '9876543240',
      address: '9, Raja Street, Mylapore',
      city: 'Chennai', pincode: '600004',
      date: DateTime.now().subtract(const Duration(days: 8)),
      timeSlot: '11:00 AM',
      testNames: ['Thyroid Profile', 'Vitamin D3'],
      mode: 'Home Collection',
      status: 'Cancelled',
      serviceChargePaid: 99, testsTotal: 0,
      assignedAt: DateTime.now().subtract(const Duration(days: 9)),
    ),
  ];

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final history = _mockHistory();
    final completed = history.where((b) => b.status == 'Completed').toList();
    final cancelled = history.where((b) => b.status == 'Cancelled').toList();

    if (embedded) {
      return DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Container(
              color: AppColors.brandGreen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, MediaQuery.of(context).padding.top + 14, 16, 8),
                    child: const Text('History',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w600)),
                  ),
                  TabBar(
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
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: AppColors.background,
                child: TabBarView(
                  children: [
                    _BookingList(bookings: completed, formatDate: _formatDate),
                    _BookingList(bookings: cancelled, formatDate: _formatDate),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.brandGreen,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 18),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text('History',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600)),
          bottom: TabBar(
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
        body: TabBarView(
          children: [
            _BookingList(bookings: completed, formatDate: _formatDate),
            _BookingList(bookings: cancelled, formatDate: _formatDate),
          ],
        ),
      ),
    );
  }
}

// ─── Booking List ─────────────────────────────────────────────────────────────

class _BookingList extends StatelessWidget {
  final List<TechnicianBooking> bookings;
  final String Function(DateTime) formatDate;

  const _BookingList({required this.bookings, required this.formatDate});

  @override
  Widget build(BuildContext context) {
    if (bookings.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreenSurface, shape: BoxShape.circle),
              child: const Icon(Icons.history_outlined,
                  size: 30, color: AppColors.brandGreen),
            ),
            const SizedBox(height: 14),
            const Text('No records yet',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: bookings.length,
      itemBuilder: (_, i) => _HistoryCard(booking: bookings[i], formatDate: formatDate),
    );
  }
}

// ─── History Card (read-only) ─────────────────────────────────────────────────

class _HistoryCard extends StatelessWidget {
  final TechnicianBooking booking;
  final String Function(DateTime) formatDate;

  const _HistoryCard({required this.booking, required this.formatDate});

  @override
  Widget build(BuildContext context) {
    final isCompleted = booking.status == 'Completed';
    final statusColor = isCompleted ? AppColors.brandGreen : const Color(0xFFD32F2F);
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
                if (booking.isVip)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.star_rounded, size: 9, color: Colors.white),
                      SizedBox(width: 3),
                      Text('VIP', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
                    ]),
                  ),
                if (booking.isVip) const SizedBox(width: 8),
                Text(booking.id,
                    style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name + lock icon
                  Row(children: [
                    Expanded(
                      child: Text(booking.customerName,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                    ),
                    Container(
                      width: 30, height: 30,
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: const Icon(Icons.lock_outline_rounded,
                          size: 14, color: AppColors.textHint),
                    ),
                  ]),

                  const SizedBox(height: 8),

                  // Date + time
                  Row(children: [
                    const Icon(Icons.event_outlined, size: 12, color: AppColors.textHint),
                    const SizedBox(width: 5),
                    Text(formatDate(booking.date),
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(width: 10),
                    const Icon(Icons.schedule_outlined, size: 12, color: AppColors.textHint),
                    const SizedBox(width: 5),
                    Text(booking.timeSlot,
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  ]),

                  const SizedBox(height: 6),

                  // Address
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.location_on_outlined, size: 12, color: AppColors.textHint),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '${booking.address}, ${booking.city}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),

                  const SizedBox(height: 8),

                  // Tests chips
                  Wrap(spacing: 6, runSpacing: 4,
                    children: [
                      ...booking.testNames.take(2).map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.brandGreenSurface,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(t, style: const TextStyle(fontSize: 11, color: AppColors.brandGreen)),
                      )),
                      if (booking.testNames.length > 2)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('+${booking.testNames.length - 2} more',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Amount collected
                  if (isCompleted)
                    Row(children: [
                      const Icon(Icons.payments_outlined,
                          size: 13, color: AppColors.brandGreen),
                      const SizedBox(width: 5),
                      Text('Collected: ₹${totalCollected.toInt()}',
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.brandGreen,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(width: 4),
                      Text('(₹${booking.serviceChargePaid.toInt()} + ₹${booking.testsTotal.toInt()})',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    ]),

                  if (booking.docRequired) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      Icon(
                        booking.docVerified
                            ? Icons.verified_outlined
                            : Icons.pending_outlined,
                        size: 13,
                        color: booking.docVerified
                            ? AppColors.brandGreen
                            : const Color(0xFFE65100),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        booking.docVerified ? 'Prescription verified' : 'Prescription not verified',
                        style: TextStyle(
                            fontSize: 11,
                            color: booking.docVerified
                                ? AppColors.brandGreen
                                : const Color(0xFFE65100)),
                      ),
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
