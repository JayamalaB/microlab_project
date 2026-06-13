import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models.dart';

// ─── Reports screen ───────────────────────────────────────────────────────────

class ReportsScreen extends StatelessWidget {
  final bool embedded;
  const ReportsScreen({super.key, this.embedded = false});

  static List<BookingModel> _mockReports() {
    final member = MemberModel(
      id: 's1', name: 'Ravi Kumar', mobile: '9876543210',
      gender: 'Male', location: 'Chennai',
      address: '12, Gandhi Street, T Nagar, Chennai - 600017',
      relation: 'Self', dob: DateTime(1985, 6, 15),
    );
    return [
      BookingModel(
        id: 'BK00122001', member: member,
        tests: [
          TestModel.fromJson({'id': '4', 'name': 'Lipid Profile', 'type': 'single', 'category': 'Heart', 'description': 'Cholesterol, HDL, LDL', 'offer': 'no', 'original_price': '500', 'final_price': '500', 'doc_req': 'no', 'report_sts': '24 hrs'}),
        ],
        mode: 'Home Collection', city: 'Chennai', pincode: '600017',
        address: '12, Gandhi Street, T Nagar',
        date: DateTime.now().subtract(const Duration(days: 7)),
        timeSlot: '4:00 PM', paymentType: 'full',
        serviceCharge: 99, testsTotal: 500, grandTotal: 599, paidAmount: 599,
        status: 'Completed', createdAt: DateTime.now().subtract(const Duration(days: 8)),
        docRequired: false, docVerified: false,
        reportUrl: 'https://microlab.in/reports/BK00122001.pdf',
        reportReadyDate: DateTime.now().subtract(const Duration(days: 6)),
      ),
      BookingModel(
        id: 'BK00120055', member: member,
        tests: [
          TestModel.fromJson({'id': '1', 'name': 'HbA1c', 'type': 'single', 'category': 'Diabetes', 'description': '3-month average blood sugar', 'offer': 'no', 'original_price': '600', 'final_price': '540', 'doc_req': 'no', 'report_sts': '48 hrs'}),
          TestModel.fromJson({'id': '3', 'name': 'Thyroid Profile', 'type': 'single', 'category': 'Thyroid', 'description': 'T3, T4, TSH', 'offer': 'no', 'original_price': '900', 'final_price': '765', 'doc_req': 'no', 'report_sts': '24 hrs'}),
        ],
        mode: 'Home Collection', city: 'Chennai', pincode: '600017',
        address: '12, Gandhi Street, T Nagar',
        date: DateTime.now().subtract(const Duration(days: 20)),
        timeSlot: '10:00 AM', paymentType: 'full',
        serviceCharge: 99, testsTotal: 1305, grandTotal: 1404, paidAmount: 1404,
        status: 'Completed', createdAt: DateTime.now().subtract(const Duration(days: 21)),
        docRequired: false, docVerified: false,
        reportUrl: 'https://microlab.in/reports/BK00120055.pdf',
        reportReadyDate: DateTime.now().subtract(const Duration(days: 18)),
      ),
      BookingModel(
        id: 'BK00119800', member: member,
        tests: [
          TestModel.fromJson({'id': '8', 'name': 'Kidney Function Test', 'type': 'single', 'category': 'Kidney', 'description': 'Creatinine, urea, eGFR', 'offer': 'no', 'original_price': '450', 'final_price': '450', 'doc_req': 'no', 'report_sts': '24 hrs'}),
        ],
        mode: 'Lab Test', city: 'Chennai',
        address: null, pincode: null,
        date: DateTime.now().subtract(const Duration(days: 35)),
        timeSlot: '1:00 PM', paymentType: 'full',
        serviceCharge: 99, testsTotal: 450, grandTotal: 549, paidAmount: 549,
        status: 'Completed', createdAt: DateTime.now().subtract(const Duration(days: 36)),
        docRequired: false, docVerified: false,
        reportUrl: null,
        reportReadyDate: null,
      ),
    ];
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

  void _showShareSheet(BuildContext context, BookingModel booking) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ShareSheet(booking: booking),
    );
  }

  Widget _buildBody(BuildContext context, List<BookingModel> reports) {
    if (reports.isEmpty) {
      return const Center(
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
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      itemCount: reports.length,
      itemBuilder: (_, i) {
        final b = reports[i];
        final hasReport = b.reportUrl != null;
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
                // ── Status strip ───────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: hasReport ? AppColors.brandGreenSurface : const Color(0xFFFFF8E1),
                  child: Row(
                    children: [
                      Icon(
                        hasReport ? Icons.check_circle_outline : Icons.hourglass_top_rounded,
                        size: 14,
                        color: hasReport ? AppColors.brandGreen : const Color(0xFFE65100),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        hasReport ? 'Report Ready' : 'Processing',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: hasReport ? AppColors.brandGreen : const Color(0xFFE65100)),
                      ),
                      const Spacer(),
                      Text(b.id, style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
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
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Wrap(
                        spacing: 6, runSpacing: 4,
                        children: b.tests.map((t) => Container(
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
                        )).toList(),
                      ),

                      const SizedBox(height: 10),

                      if (b.reportReadyDate != null)
                        Row(children: [
                          const Icon(Icons.event_available_outlined, size: 12, color: AppColors.textHint),
                          const SizedBox(width: 4),
                          Text('Available since ${_formatDate(b.reportReadyDate!)}',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        ]),

                      if (!hasReport)
                        Row(children: [
                          const Icon(Icons.schedule_outlined, size: 12, color: AppColors.textHint),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'Report ready within ${b.tests.map((t) => t.reportStatus).toSet().join(' / ')}',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                            ),
                          ),
                        ]),

                      const SizedBox(height: 12),

                      // ── Action buttons ──────────────────
                      if (hasReport)
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _openReport(context, b),
                                icon: const Icon(Icons.description_outlined, size: 16),
                                label: const Text('View Report'),
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
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => _showShareSheet(context, b),
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: AppColors.brandGreenSurface,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.brandGreenLight),
                                ),
                                child: const Icon(Icons.share_outlined,
                                    size: 18, color: AppColors.brandGreen),
                              ),
                            ),
                          ],
                        )
                      else
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.hourglass_empty_outlined, size: 16),
                            label: const Text('Report being processed'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.textHint,
                              side: const BorderSide(color: AppColors.divider),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final reports = _mockReports();
    if (embedded) {
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
              child: _buildBody(context, reports),
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
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: _buildBody(context, reports),
    );
  }
}

// ─── Share bottom sheet ───────────────────────────────────────────────────────

class _ShareSheet extends StatefulWidget {
  final BookingModel booking;
  const _ShareSheet({required this.booking});

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _copied = false;

  String _formatDateShort(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${months[d.month]} ${d.year}';
  }

  String get _shareText {
    final b = widget.booking;
    final tests = b.tests.map((t) => t.name).join(', ');
    final status = b.reportUrl != null ? 'Report Ready ✅' : 'Processing ⏳';
    final link = b.reportUrl != null
        ? '\nView report: ${b.reportUrl}'
        : '\nReport will be available shortly.';

    return '*MicroLab Lab Report*\n'
        'Booking ID: ${b.id}\n'
        'Patient: ${b.member.name}\n'
        'Tests: $tests\n'
        'Date: ${_formatDateShort(b.date)}\n'
        'Status: $status'
        '$link\n\n'
        '_MicroLab – Your health, our priority._';
  }

  Future<void> _whatsApp() async {
    final url = Uri.parse(
        'https://wa.me/?text=${Uri.encodeComponent(_shareText)}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      _showError('WhatsApp is not installed.');
    }
  }

  Future<void> _sms() async {
    final url = Uri.parse(
        'sms:?body=${Uri.encodeComponent(_shareText)}');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else if (mounted) {
      _showError('Unable to open SMS.');
    }
  }

  Future<void> _more() async {
    await Share.share(
      _shareText,
      subject: 'MicroLab Report – ${widget.booking.id}',
    );
  }

  Future<void> _copyLink() async {
    final text = widget.booking.reportUrl ?? _shareText;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2),
        () { if (mounted) setState(() => _copied = false); });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.red.shade700,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.booking;
    final tests = b.tests.map((t) => t.name).join(' · ');

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 36, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),

              // Header
              Row(children: [
                Container(
                  width: 42, height: 42,
                  decoration: const BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      shape: BoxShape.circle),
                  child: const Icon(Icons.share_outlined,
                      size: 20, color: AppColors.brandGreen),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Share Report',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                      Text('${b.id} · $tests',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ]),

              const SizedBox(height: 20),

              // WhatsApp
              _ShareTile(
                color: const Color(0xFF25D366),
                icon: Icons.chat_rounded,
                label: 'WhatsApp',
                sub: 'Share via WhatsApp',
                onTap: () { Navigator.pop(context); _whatsApp(); },
              ),

              const SizedBox(height: 10),

              // SMS
              _ShareTile(
                color: const Color(0xFF1565C0),
                icon: Icons.sms_outlined,
                label: 'Send SMS',
                sub: 'Open default SMS app',
                onTap: () { Navigator.pop(context); _sms(); },
              ),

              const SizedBox(height: 10),

              // Copy link
              _ShareTile(
                color: _copied ? AppColors.brandGreen : const Color(0xFF616161),
                icon: _copied ? Icons.check_rounded : Icons.link_rounded,
                label: _copied ? 'Copied!' : 'Copy Link',
                sub: widget.booking.reportUrl ?? 'Copy report summary',
                onTap: _copyLink,
              ),

              const SizedBox(height: 10),

              // More
              _ShareTile(
                color: const Color(0xFF7B1FA2),
                icon: Icons.more_horiz_rounded,
                label: 'More options',
                sub: 'Email, Telegram, Drive…',
                onTap: () { Navigator.pop(context); _more(); },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShareTile extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;
  const _ShareTile({
    required this.color,
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  Text(sub,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: AppColors.textHint),
          ]),
        ),
      );
}

// ─── Report detail page ───────────────────────────────────────────────────────

class _ReportDetailPage extends StatefulWidget {
  final BookingModel booking;
  const _ReportDetailPage({required this.booking});

  @override
  State<_ReportDetailPage> createState() => _ReportDetailPageState();
}

class _ReportDetailPageState extends State<_ReportDetailPage> {
  bool _isGenerating = false;

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

  void _share() {
    final tests = booking.tests.map((t) => t.name).join(', ');
    const status = 'Report Ready ✅';
    Share.share(
      '*MicroLab Lab Report*\n'
      'Booking: ${booking.id}\nPatient: ${booking.member.name}\n'
      'Tests: $tests\nDate: ${_fmtShort(booking.date)}\nStatus: $status',
      subject: 'MicroLab Report – ${booking.id}',
    );
  }

  Future<void> _downloadPdf() async {
    if (_isGenerating) return;
    setState(() => _isGenerating = true);
    try {
      final bytes = await _buildReportPdf(booking);
      if (!mounted) return;
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: 'MicroLab_Report_${booking.id}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to generate PDF: $e'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
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
                style: const TextStyle(
                    color: Colors.white70, fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _share,
            icon: const Icon(Icons.share_outlined, color: Colors.white, size: 20),
            tooltip: 'Share',
          ),
          IconButton(
            onPressed: _isGenerating ? null : _downloadPdf,
            icon: _isGenerating
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.download_outlined, color: Colors.white, size: 20),
            tooltip: 'Download PDF',
          ),
        ],
      ),
      body: SingleChildScrollView(
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
                    _ReportMeta(
                        label: 'Report ID', value: booking.id),
                    const SizedBox(width: 20),
                    _ReportMeta(
                        label: 'Collected',
                        value: _fmtShort(booking.date)),
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
                  _ReportRow(label: 'Date & Time',
                      value: '${_fmt(booking.date)}  ·  ${booking.timeSlot}'),
                  _ReportRow(
                      label: 'Tests',
                      value: booking.tests.map((t) => t.name).join(', '),
                      last: true),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Test results ────────────────────────────
            const Text('Test Results',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 10),

            ...booking.tests.map((test) {
              final params = _paramsFor(test.name);
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Test header
                    Container(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                      decoration: const BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.vertical(
                            top: Radius.circular(11)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.science_outlined,
                            size: 14, color: AppColors.brandGreen),
                        const SizedBox(width: 8),
                        Text(test.name,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.brandGreen)),
                      ]),
                    ),

                    // Column headers
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 6),
                      color: AppColors.background,
                      child: const Row(children: [
                        Expanded(
                            flex: 5,
                            child: Text('Parameter',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary))),
                        Expanded(
                            flex: 2,
                            child: Text('Value',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary))),
                        Expanded(
                            flex: 2,
                            child: Text('Unit',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary))),
                        Expanded(
                            flex: 4,
                            child: Text('Reference',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textSecondary))),
                      ]),
                    ),
                    const Divider(height: 1, color: AppColors.divider),

                    // Parameter rows
                    ...params.asMap().entries.map((e) {
                      final p = e.value;
                      final isLast = e.key == params.length - 1;
                      return _ParamRow(param: p, isLast: isLast);
                    }),
                  ],
                ),
              );
            }),

            const SizedBox(height: 12),

            // ── Interpretation note ─────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF8E1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFCC80)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14, color: Color(0xFFE65100)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Results marked H (High) or L (Low) are outside reference range. '
                      'Please consult your doctor for clinical interpretation.',
                      style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF5D4037),
                          height: 1.5),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // ── Footer ──────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text('MicroLab Diagnostics Pvt. Ltd.',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 4),
                  const Text(
                      '45, Pondy Bazaar, T Nagar, Chennai – 600017\n'
                      'support@microlab.in  ·  1800-XXX-XXXX',
                      style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textSecondary,
                          height: 1.6),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  const Divider(color: AppColors.divider),
                  const SizedBox(height: 6),
                  Text(
                    'Report generated on ${_fmtShort(DateTime.now())}  ·  '
                    'This is a computer-generated report.',
                    style: const TextStyle(
                        fontSize: 9,
                        color: AppColors.textHint,
                        height: 1.5),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: booking.reportUrl != null
          ? Container(
              padding: EdgeInsets.fromLTRB(
                  16, 10, 16, MediaQuery.of(context).padding.bottom + 10),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.share_outlined, size: 16),
                      label: const Text('Share'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.brandGreen,
                        side: const BorderSide(
                            color: AppColors.brandGreen, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isGenerating ? null : _downloadPdf,
                      icon: _isGenerating
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.download_outlined, size: 16),
                      label: Text(_isGenerating ? 'Generating…' : 'Download PDF'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        disabledBackgroundColor:
                            AppColors.brandGreen.withValues(alpha: 0.5),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

// ─── Report detail helpers ────────────────────────────────────────────────────

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

// ─── Report parameter model ───────────────────────────────────────────────────

enum _Flag { normal, high, low }

class _ReportParam {
  final String name;
  final String value;
  final String unit;
  final String refRange;
  final _Flag flag;
  const _ReportParam(this.name, this.value, this.unit, this.refRange,
      [this.flag = _Flag.normal]);
}

class _ParamRow extends StatelessWidget {
  final _ReportParam param;
  final bool isLast;
  const _ParamRow({required this.param, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final Color flagColor = switch (param.flag) {
      _Flag.high => const Color(0xFFD32F2F),
      _Flag.low => const Color(0xFF1565C0),
      _Flag.normal => AppColors.textPrimary,
    };
    final String flagLabel = switch (param.flag) {
      _Flag.high => 'H',
      _Flag.low => 'L',
      _Flag.normal => '',
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text(param.name,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textPrimary)),
              ),
              Expanded(
                flex: 2,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(param.value,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: flagColor)),
                    if (flagLabel.isNotEmpty) ...[
                      const SizedBox(width: 3),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: flagColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(flagLabel,
                            style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                color: flagColor)),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(param.unit,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ),
              Expanded(
                flex: 4,
                child: Text(param.refRange,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
              ),
            ],
          ),
        ),
        if (!isLast) const Divider(height: 1, color: AppColors.divider),
      ],
    );
  }
}

// ─── Mock test parameter data ─────────────────────────────────────────────────

List<_ReportParam> _paramsFor(String testName) {
  final n = testName.toLowerCase();

  if (n.contains('lipid')) {
    return const [
      _ReportParam('Total Cholesterol', '185', 'mg/dL', '< 200'),
      _ReportParam('HDL Cholesterol', '52', 'mg/dL', '> 40'),
      _ReportParam('LDL Cholesterol', '118', 'mg/dL', '< 130'),
      _ReportParam('VLDL', '29', 'mg/dL', '< 30'),
      _ReportParam('Triglycerides', '145', 'mg/dL', '< 150'),
      _ReportParam('Cholesterol / HDL Ratio', '3.6', '', '< 5.0'),
    ];
  }

  if (n.contains('hba1c')) {
    return const [
      _ReportParam('HbA1c', '6.2', '%', '4.0 – 5.6', _Flag.high),
      _ReportParam('Estimated Avg Glucose', '131', 'mg/dL', '70 – 100', _Flag.high),
    ];
  }

  if (n.contains('thyroid')) {
    return const [
      _ReportParam('TSH', '2.50', 'µIU/mL', '0.40 – 4.00'),
      _ReportParam('T3 (Triiodothyronine)', '1.20', 'ng/mL', '0.80 – 2.00'),
      _ReportParam('T4 (Thyroxine)', '8.50', 'µg/dL', '5.10 – 14.10'),
      _ReportParam('Free T3', '3.20', 'pg/mL', '2.30 – 4.20'),
      _ReportParam('Free T4', '1.10', 'ng/dL', '0.89 – 1.76'),
    ];
  }

  if (n.contains('kidney') || n.contains('renal')) {
    return const [
      _ReportParam('Serum Creatinine', '0.90', 'mg/dL', '0.60 – 1.20'),
      _ReportParam('Blood Urea Nitrogen', '28', 'mg/dL', '15 – 40'),
      _ReportParam('Uric Acid', '5.8', 'mg/dL', '3.5 – 7.2'),
      _ReportParam('eGFR', '85', 'mL/min/1.73m²', '> 60'),
      _ReportParam('Sodium', '139', 'mEq/L', '136 – 145'),
      _ReportParam('Potassium', '4.2', 'mEq/L', '3.5 – 5.1'),
    ];
  }

  if (n.contains('cbc') || n.contains('complete blood')) {
    return const [
      _ReportParam('Haemoglobin', '14.2', 'g/dL', '13.0 – 17.0'),
      _ReportParam('WBC Count', '7200', 'cells/µL', '4000 – 11000'),
      _ReportParam('RBC Count', '5.1', 'M/µL', '4.5 – 5.5'),
      _ReportParam('Platelet Count', '2.8', 'lakh/µL', '1.5 – 4.0'),
      _ReportParam('MCV', '88', 'fL', '80 – 100'),
      _ReportParam('MCH', '29', 'pg', '27 – 33'),
      _ReportParam('Haematocrit', '42', '%', '40 – 50'),
    ];
  }

  if (n.contains('vitamin d') || n.contains('vit d')) {
    return const [
      _ReportParam('25-OH Vitamin D', '18', 'ng/mL', '30 – 100', _Flag.low),
    ];
  }

  if (n.contains('vitamin b') || n.contains('b12')) {
    return const [
      _ReportParam('Vitamin B12', '310', 'pg/mL', '200 – 900'),
    ];
  }

  if (n.contains('blood glucose') || n.contains('sugar') || n.contains('fbs') || n.contains('rbs')) {
    return const [
      _ReportParam('Glucose (Fasting)', '95', 'mg/dL', '70 – 100'),
    ];
  }

  // Generic fallback
  return const [
    _ReportParam('Result', 'Normal', '', 'Within limits'),
  ];
}

// ─── PDF generator ────────────────────────────────────────────────────────────

Future<Uint8List> _buildReportPdf(BookingModel booking) async {
  final doc = pw.Document(
    title: 'Lab Report – ${booking.id}',
    author: 'MicroLab Diagnostics',
  );

  // Brand colors
  const brandGreen = PdfColor(0.18, 0.49, 0.196);
  const greenLight = PdfColor(0.902, 0.961, 0.906);
  const grey900 = PdfColor(0.12, 0.12, 0.12);
  const grey600 = PdfColor(0.38, 0.38, 0.38);
  const grey200 = PdfColor(0.93, 0.93, 0.93);
  const grey50 = PdfColor(0.97, 0.97, 0.97);
  const flagRed = PdfColor(0.82, 0.09, 0.09);
  const flagBlue = PdfColor(0.08, 0.38, 0.74);

  String fmtDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  String fmtShort(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${months[d.month]} ${d.year}';
  }

  int calcAge(DateTime dob) {
    final now = DateTime.now();
    int age = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) { age--; }
    return age;
  }

  // ── Section label bar ──────────────────────────────────────────────────────
  pw.Widget sectionBar(String title) => pw.Container(
        width: double.infinity,
        color: greenLight,
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: pw.Text(title,
            style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: brandGreen)),
      );

  // ── Patient & collection info ──────────────────────────────────────────────
  final m = booking.member;
  final infoRows = <List<String>>[
    ['Patient Name', m.name],
    ['Booking ID', booking.id],
    if (m.gender.isNotEmpty || m.dob != null)
      ['Gender / Age',
        [
          if (m.gender.isNotEmpty) m.gender,
          if (m.dob != null) '${calcAge(m.dob!)} yrs',
        ].join('  ·  ')],
    if (m.dob != null) ['Date of Birth', fmtShort(m.dob!)],
    ['Mobile', '+91 ${m.mobile}'],
    if (m.address.isNotEmpty) ['Address', m.address],
    ['Collection Date', fmtDate(booking.date)],
    ['Time Slot', booking.timeSlot],
    ['Collection Mode', booking.mode],
    ['Tests Ordered', booking.tests.map((t) => t.name).join(', ')],
    if (booking.reportReadyDate != null)
      ['Report Date', fmtDate(booking.reportReadyDate!)],
  ];

  pw.Widget infoTable() => pw.Table(
        columnWidths: const {
          0: pw.FixedColumnWidth(110),
          1: pw.FlexColumnWidth(),
        },
        children: infoRows.asMap().entries.map((e) {
          final even = e.key.isEven;
          return pw.TableRow(
            decoration: even ? null : const pw.BoxDecoration(color: grey200),
            children: [
              pw.Padding(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: pw.Text(e.value[0],
                    style: const pw.TextStyle(fontSize: 8.5, color: grey600)),
              ),
              pw.Padding(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: pw.Text(e.value[1],
                    style: pw.TextStyle(
                        fontSize: 8.5,
                        color: grey900,
                        fontWeight: pw.FontWeight.bold)),
              ),
            ],
          );
        }).toList(),
      );

  // ── Test result section ────────────────────────────────────────────────────
  pw.Widget testSection(TestModel test) {
    final params = _paramsFor(test.name);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        sectionBar(test.name.toUpperCase()),
        pw.Table(
          border: pw.TableBorder(
            horizontalInside: const pw.BorderSide(
                color: grey200, width: 0.5),
          ),
          columnWidths: const {
            0: pw.FlexColumnWidth(5),
            1: pw.FixedColumnWidth(52),
            2: pw.FixedColumnWidth(64),
            3: pw.FlexColumnWidth(4),
            4: pw.FixedColumnWidth(18),
          },
          children: [
            // Header row
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: grey200),
              children: [
                'Parameter', 'Value', 'Unit', 'Reference Range', ''
              ].map((h) => pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    child: pw.Text(h,
                        style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                            color: grey600)),
                  )).toList(),
            ),
            // Data rows
            ...params.asMap().entries.map((e) {
              final p = e.value;
              final even = e.key.isEven;
              final flagColor = switch (p.flag) {
                _Flag.high => flagRed,
                _Flag.low => flagBlue,
                _Flag.normal => grey900,
              };
              final flagLabel = switch (p.flag) {
                _Flag.high => 'H',
                _Flag.low => 'L',
                _Flag.normal => '',
              };
              return pw.TableRow(
                decoration: even
                    ? null
                    : const pw.BoxDecoration(color: grey50),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    child: pw.Text(p.name,
                        style: pw.TextStyle(fontSize: 8.5, color: grey900)),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    child: pw.Text(p.value,
                        style: pw.TextStyle(
                            fontSize: 8.5,
                            fontWeight: pw.FontWeight.bold,
                            color: flagColor)),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    child: pw.Text(p.unit,
                        style: pw.TextStyle(fontSize: 8, color: grey600)),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 5),
                    child: pw.Text(p.refRange,
                        style: pw.TextStyle(fontSize: 8, color: grey600)),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 4, vertical: 5),
                    child: pw.Text(flagLabel,
                        style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                            color: flagColor)),
                  ),
                ],
              );
            }),
          ],
        ),
        pw.SizedBox(height: 12),
      ],
    );
  }

  // ── Page header (repeated per page) ───────────────────────────────────────
  pw.Widget pageHeader(pw.Context ctx) => pw.Column(
        children: [
          pw.Container(
            color: brandGreen,
            padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('MicroLab Diagnostics',
                        style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 14,
                            fontWeight: pw.FontWeight.bold)),
                    pw.Text('NABL Accredited  ·  ISO 15189:2022',
                        style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 8)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text('LAB REPORT',
                        style: pw.TextStyle(
                            color: PdfColors.white,
                            fontSize: 11,
                            fontWeight: pw.FontWeight.bold,
                            letterSpacing: 1.2)),
                    pw.Text(booking.id,
                        style: pw.TextStyle(
                            color: PdfColors.white, fontSize: 9)),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
        ],
      );

  // ── Page footer ────────────────────────────────────────────────────────────
  pw.Widget pageFooter(pw.Context ctx) => pw.Column(
        children: [
          pw.Divider(color: grey200, thickness: 0.5),
          pw.SizedBox(height: 6),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('MicroLab Diagnostics Pvt. Ltd.',
                      style: pw.TextStyle(
                          fontSize: 7.5,
                          fontWeight: pw.FontWeight.bold,
                          color: grey900)),
                  pw.Text(
                      '45, Pondy Bazaar, T Nagar, Chennai – 600017  |  support@microlab.in',
                      style: pw.TextStyle(fontSize: 7, color: grey600)),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('Generated: ${fmtShort(DateTime.now())}',
                      style: pw.TextStyle(fontSize: 7, color: grey600)),
                  pw.Text(
                      'Page ${ctx.pageNumber} of ${ctx.pagesCount}',
                      style: pw.TextStyle(fontSize: 7, color: grey600)),
                ],
              ),
            ],
          ),
        ],
      );

  // ── Assemble document ──────────────────────────────────────────────────────
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.symmetric(horizontal: 40, vertical: 28),
    header: pageHeader,
    footer: pageFooter,
    build: (ctx) => [
      // Patient & collection info
      sectionBar('PATIENT & COLLECTION INFORMATION'),
      infoTable(),
      pw.SizedBox(height: 16),

      // Test results
      pw.Text('TEST RESULTS',
          style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: grey900)),
      pw.SizedBox(height: 6),
      ...booking.tests.map(testSection),

      // Disclaimer
      pw.Container(
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: const PdfColor(1.0, 0.98, 0.93),
          border: pw.Border.all(
              color: const PdfColor(1.0, 0.70, 0.20), width: 0.5),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
        ),
        child: pw.Text(
          'Note: Values marked H (High) or L (Low) are outside the standard reference range. '
          'Results should be clinically interpreted by a qualified physician. '
          'This is a computer-generated report and does not require a physical signature.',
          style: pw.TextStyle(
              fontSize: 7.5,
              color: const PdfColor(0.35, 0.21, 0.0),
              lineSpacing: 2),
        ),
      ),
    ],
  ));

  return doc.save();
}
