import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/razorpay_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/models/technician_booking.dart';
import 'technician_active_job_screen.dart';

// ─── Prescription doc model ──────────────────────────────────────────────────

class _TechPresDoc {
  final int? docId;         // null while uploading; set once saved to server
  final Uint8List? bytes;   // local bytes present only while uploading
  final String? url;        // remote URL set after upload completes
  final String fileName;
  final DateTime uploadedAt;
  bool isUploading;
  String docStatus;

  _TechPresDoc({
    this.docId,
    this.bytes,
    this.url,
    required this.fileName,
    required this.uploadedAt,
    this.isUploading = false,
    this.docStatus = 'pending_review',
  });

  bool get isVerified => docStatus == 'verified';
}

// (Test catalogue is now loaded from the server — see _loadItems)

// ─── Journey steps ────────────────────────────────────────────────────────────

class _JourneyStep {
  final String status;
  final String label;
  final String description;
  final IconData icon;
  final Color color;
  const _JourneyStep({
    required this.status, required this.label,
    required this.description, required this.icon, required this.color,
  });
}

const List<_JourneyStep> _journeySteps = [
  _JourneyStep(
    status: 'Confirmed',
    label: 'Confirmed',
    description: 'Booking confirmed',
    icon: Icons.check_circle_outline,
    color: AppColors.brandGreen,
  ),
  _JourneyStep(
    status: 'Journey Started',
    label: 'Journey Started',
    description: 'On the way to customer',
    icon: Icons.directions_bike_rounded,
    color: Color(0xFF1565C0),
  ),
  _JourneyStep(
    status: 'Destination Reached',
    label: 'Destination Reached',
    description: 'Arrived at customer location',
    icon: Icons.location_on_rounded,
    color: Color(0xFF6A1B9A),
  ),
  _JourneyStep(
    status: 'Collection Started',
    label: 'Collection Started',
    description: 'Sample collection in progress',
    icon: Icons.science_outlined,
    color: Color(0xFFE65100),
  ),
  _JourneyStep(
    status: 'Sample Collected',
    label: 'Sample Collected',
    description: 'Sample successfully collected',
    icon: Icons.biotech_rounded,
    color: Color(0xFF6A1B9A),
  ),
  _JourneyStep(
    status: 'OTP Verified',
    label: 'OTP Verified',
    description: 'Identity verified by patient',
    icon: Icons.verified_user_outlined,
    color: Color(0xFF1565C0),
  ),
  _JourneyStep(
    status: 'Handed to Lab',
    label: 'Handed to Lab',
    description: 'Sample handed over to laboratory',
    icon: Icons.local_hospital_rounded,
    color: AppColors.brandGreen,
  ),
];

// ─── Screen ───────────────────────────────────────────────────────────────────

class TechnicianBookingDetailScreen extends StatefulWidget {
  final TechnicianBooking booking;
  final void Function(TechnicianBooking)? onNewBooking;
  const TechnicianBookingDetailScreen({
    super.key,
    required this.booking,
    this.onNewBooking,
  });

  @override
  State<TechnicianBookingDetailScreen> createState() =>
      _TechnicianBookingDetailScreenState();
}

class _TechnicianBookingDetailScreenState
    extends State<TechnicianBookingDetailScreen> {

  late String _currentStatus;
  List<Map<String, String>> _selectedTests = [];
  // IDs of tests that existed in the booking at screen open — used to block
  // deletion of paid original tests without affecting newly added ones.
  Set<String> _originalItemIds = {};
  bool _itemsLoading = true;
  List<Map<String, String>> _catalogueItems = [];
  bool _showAddTest = false;
  String _searchQuery = '';

  // Document — multi-image upload
  final List<_TechPresDoc> _docUploads = [];
  bool _docIsPicking = false;
  bool _docVerified = false;
  bool _docsLoading = true;
  static const int _docMaxFiles = 5;
  final ImagePicker _picker = ImagePicker();

  // Payment — live values fetched from server in initState, overriding immutable widget.booking fields
  bool _isProcessingPayment = false;
  double _sessionPaymentCollected = 0.0;
  late String _livePaymentStatus;  // refreshed from server; starts from widget value
  late double _liveAmountPaid;     // refreshed from server; starts from widget value

  // Visit members linked to this booking (refreshed after each add)
  List<Map<String, dynamic>> _linkedPatients = [];

  // OTP
  final List<TextEditingController> _otpControllers =
      List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes =
      List.generate(4, (_) => FocusNode());
  bool _isVerifyingOtp  = false;
  bool _isResendingOtp  = false;
  bool _otpError        = false;
  String _otpErrorText  = 'Invalid OTP. Please try again.';

  // ── Computed ──────────────────────────────────────────────

  double get _testsTotal =>
      _selectedTests.fold(0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0));

  double get _serviceChargePaid => widget.booking.serviceChargePaid;

  double get _amountDue {
    final due = _testsTotal - (_liveAmountPaid + _sessionPaymentCollected);
    return due < 0.0 ? 0.0 : due;
  }

  bool get _paymentDone => _amountDue <= 0.0;

  // True when any sibling booking added this session still has an unpaid balance.
  bool get _hasUnpaidSiblings => _linkedPatients.any((c) {
    final due = double.tryParse(c['amount_due']?.toString() ?? '0') ?? 0.0;
    return due > 0 && c['payment_status'] != 'paid';
  });

  // A test is locked when it was already paid for:
  // - original tests on a booking whose payment_status is 'paid', OR
  // - tests that existed in the booking when the technician collected payment
  //   this session (captured in _paidTestIds at the moment of collection).
  Set<String> _paidTestIds = {};

  bool _isTestLocked(String testId) =>
      (_livePaymentStatus == 'paid' && _originalItemIds.contains(testId)) ||
      _paidTestIds.contains(testId);

  int get _currentStepIndex =>
      _journeySteps.indexWhere((s) => s.status == _currentStatus);

  bool get _isCompleted => _currentStatus == 'Handed to Lab';
  // Visit is finalized after OTP Verified — no more edits allowed from this point.
  bool get _isFinalized => _currentStatus == 'OTP Verified' || _currentStatus == 'Handed to Lab';
  bool get _canAdvance  => !_isCompleted;

  String? get _nextStatus {
    final idx = _currentStepIndex;
    if (idx < 0 || idx >= _journeySteps.length - 1) return null;
    return _journeySteps[idx + 1].status;
  }

  @override
  void initState() {
    super.initState();
    _currentStatus        = widget.booking.status;
    _livePaymentStatus    = widget.booking.paymentStatus;
    _liveAmountPaid       = widget.booking.amountPaid;
    _loadItems();
    _loadDocs();
    _loadLinkedPatients();
    _refreshPaymentInfo();
  }

  // Fetches fresh payment_status + amount_paid from the server so the screen
  // never shows stale data from the time the dashboard last loaded bookings.
  Future<void> _refreshPaymentInfo() async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    if (bookingId == 0) return;
    try {
      final data = await ApiService.getBookingPaymentInfo(bookingId);
      if (!mounted || data == null) return;
      setState(() {
        _livePaymentStatus = data['payment_status'] as String? ?? _livePaymentStatus;
        _liveAmountPaid    = double.tryParse(data['amount_paid']?.toString() ?? '') ?? _liveAmountPaid;
      });
    } catch (e) {
      debugPrint('[_refreshPaymentInfo] $e');
    }
  }

  Future<void> _loadDocs() async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    if (bookingId == 0) {
      if (mounted) setState(() => _docsLoading = false);
      return;
    }
    try {
      final docs = await ApiService.getPrescriptions(bookingId);
      if (!mounted) return;
      setState(() {
        for (final d in docs) {
          _docUploads.add(_TechPresDoc(
            docId:      (d['doc_id'] as num?)?.toInt(),
            url:        d['file_path'] as String?,
            fileName:   d['file_name'] as String? ?? 'document',
            uploadedAt: DateTime.tryParse(d['created_at']?.toString() ?? '') ?? DateTime.now(),
            docStatus:  d['doc_status'] as String? ?? 'pending_review',
          ));
        }
        _docVerified = _docUploads.isNotEmpty && _docUploads.every((d) => d.isVerified);
        _docsLoading = false;
      });
    } catch (e) {
      debugPrint('[_loadDocs] ERROR: $e');
      if (mounted) setState(() => _docsLoading = false);
    }
  }

  Future<void> _loadItems() async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    if (bookingId == 0) {
      if (mounted) setState(() => _itemsLoading = false);
      return;
    }
    try {
      // Both calls run in parallel
      final results = await Future.wait([
        ApiService.getBookingItems(bookingId),
        ApiService.getTechTestCatalogue(),
      ]);
      if (!mounted) return;
      final items     = results[0] as List<Map<String, dynamic>>;
      final catalogue = results[1] as List<Map<String, String>>;
      setState(() {
        _selectedTests = items.map((i) => {
          'bookingItemId': i['booking_item_id']?.toString() ?? '',
          'id':            i['product_id']?.toString() ?? '',
          'name':          i['name']?.toString()     ?? '',
          'category':      i['category']?.toString() ?? 'General',
          // MySQL DECIMAL comes back as a String from mysql2 — parse it safely
          'price':         double.tryParse(i['price']?.toString() ?? '0')?.toStringAsFixed(0) ?? '0',
        }).toList();
        _originalItemIds = items.map((i) => i['product_id']?.toString() ?? '').toSet();
        _catalogueItems = catalogue;
        _itemsLoading = false;
      });
    } catch (e) {
      debugPrint('[_loadItems] ERROR: $e');
      if (mounted) setState(() => _itemsLoading = false);
    }
  }

  Future<void> _loadLinkedPatients() async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    if (bookingId == 0) return;
    try {
      final patients = await ApiService.getLinkedPatients(bookingId);
      if (mounted) setState(() => _linkedPatients = patients);
    } catch (e) {
      debugPrint('[_loadLinkedPatients] ERROR: $e');
    }
  }

  Future<void> _openAddVisitMemberSheet() async {
    // Block adding family members once OTP has been verified — visit is finalized.
    if (_isFinalized) return;
    final parentBookingId = int.tryParse(widget.booking.id) ?? 0;
    if (parentBookingId == 0) return;
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddVisitMemberSheet(
        parentBookingId: parentBookingId,
        catalogueItems: _catalogueItems,
        parentTestIds: _originalItemIds,
        linkedPatientIds: _linkedPatients
            .map((p) => (p['patient_id'] as num?)?.toInt() ?? 0)
            .where((id) => id > 0)
            .toSet(),
      ),
    );
    if (result != null && mounted) {
      final count     = result['count'] as int? ?? 1;
      final firstName = result['firstName'] as String? ?? '';
      // Reload items, payment info, and linked patients so all sections are fresh
      _loadItems();
      _refreshPaymentInfo();
      _loadLinkedPatients();
      if (mounted) {
        final msg = count > 1
            ? '$count members added — collect payment below'
            : '$firstName added — collect payment below';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: AppColors.brandGreen,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    }
  }

  @override
  void dispose() {
    clearRazorpay();
    for (final c in _otpControllers) c.dispose();
    for (final f in _otpFocusNodes) f.dispose();
    super.dispose();
  }

  // ── Journey advance ───────────────────────────────────────

void _advanceStatus() {
  if (_currentStatus == 'Handed to Lab') return;

  final next = _nextStatus;
  if (next == null) return;

  // OTP step: all payments (parent + siblings) must be settled first
  if (next == 'OTP Verified') {
    if ((_amountDue > 0) || _hasUnpaidSiblings) {
      _showCompleteSheet();
    } else {
      _showOtpDialog();
    }
    return;
  }

  // Final step: payment check, then confirm, then emit handed_to_lab
  if (next == 'Handed to Lab') {
    if (_amountDue > 0 || _hasUnpaidSiblings) {
      _showCompleteSheet();
      return;
    }
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Hand Over to Lab?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text(
          'This will complete the visit and cannot be undone.',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              final bookingId = int.tryParse(widget.booking.id) ?? 0;
              SocketService.instance.emitHandedToLab(bookingId: bookingId);
              setState(() => _currentStatus = 'Handed to Lab');
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandGreen, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    return;
  }

  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('$next?',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: Text(
        _journeySteps.firstWhere((s) => s.status == next).description,
        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary))),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context);
            _handleStatusTransition(next);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.brandGreen, elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Text('Confirm', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

  // Applies the correct socket event and navigation for each status transition,
// mirroring the behaviour of the dashboard "Start Journey" card flow.
void _handleStatusTransition(String next) {
  final bookingId = int.tryParse(widget.booking.id) ?? 0;

  switch (next) {
    case 'Journey Started':
      // Only update status and emit if not already in progress
      if (_currentStatus != 'Journey Started') {
        setState(() => _currentStatus = 'Journey Started');
        // Notify customer immediately
        if (bookingId > 0) SocketService.instance.emitEnRoute(bookingId: bookingId);
      }
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TechnicianActiveJobScreen(
            bookingId: bookingId,
            patientName: widget.booking.customerName,
            patientMobile: widget.booking.customerPhone,
            patientAddress: widget.booking.address,
            patientLat: widget.booking.patientLat,
            patientLng: widget.booking.patientLng,
            hospital: widget.booking.hospital,
            startInEnRoute: true,
          ),
        ),
      ).then((wasCompleted) {
        if (wasCompleted == true && mounted) {
          setState(() => _currentStatus = 'Handed to Lab');
        }
      });
      break;

    case 'Destination Reached':
      setState(() => _currentStatus = 'Destination Reached');
      if (bookingId > 0) SocketService.instance.emitArrived(bookingId: bookingId);
      break;

    case 'Collection Started':
      setState(() => _currentStatus = 'Collection Started');
      if (bookingId > 0) SocketService.instance.emitCollectionStarted(bookingId: bookingId);
      break;

    case 'Sample Collected':
      setState(() => _currentStatus = 'Sample Collected');
      if (bookingId > 0) SocketService.instance.emitSampleCollected(bookingId: bookingId);
      break;

    default:
      setState(() => _currentStatus = next);
  }
}
// ── Resume Journey ───────────────────────────────────────

void _resumeJourney() {
  final bookingId = int.tryParse(widget.booking.id) ?? 0;
  
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => TechnicianActiveJobScreen(
        bookingId: bookingId,
        patientName: widget.booking.customerName,
        patientMobile: widget.booking.customerPhone,
        patientAddress: widget.booking.address,
        patientLat: widget.booking.patientLat,
        patientLng: widget.booking.patientLng,
        hospital: widget.booking.hospital,
        startInEnRoute: true,
      ),
    ),
  ).then((wasCompleted) {
    if (wasCompleted == true && mounted) {
      setState(() => _currentStatus = 'Handed to Lab');
    }
  });
}
 // ── OTP dialog ────────────────────────────────────────────

  Future<void> _showOtpDialog() async {
    for (final c in _otpControllers) { c.clear(); }
    setState(() { _otpError = false; _otpErrorText = 'Invalid OTP. Please try again.'; });

    final bookingId = int.tryParse(widget.booking.id) ?? 0;

    // Generate OTP on server and send SMS before opening the dialog
    final genResult = await ApiService.generateBookingOtp(bookingId);
    if (!mounted) return;

    if (genResult == null || genResult['success'] != true) {
      final msg = genResult?['message'] as String? ?? 'Failed to send OTP. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }

    final maskedMobile = genResult['maskedMobile'] as String? ??
        widget.booking.customerPhone.replaceRange(3, 7, '****');

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: const BoxDecoration(
                    color: AppColors.brandGreenSurface, shape: BoxShape.circle),
                  child: const Icon(Icons.lock_open_rounded,
                      size: 28, color: AppColors.brandGreen),
                ),
                const SizedBox(height: 14),
                const Text('Enter Customer OTP',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  'OTP sent to $maskedMobile. Ask the customer to share it.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 20),

                // 4 OTP boxes
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(4, (i) => Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i < 3 ? 10 : 0),
                      child: Container(
                        height: 56,
                        decoration: BoxDecoration(
                          color: _otpError
                              ? const Color(0xFFFFF5F5)
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _otpError
                                ? const Color(0xFFD32F2F)
                                : _otpControllers[i].text.isNotEmpty
                                    ? AppColors.brandGreen
                                    : AppColors.divider,
                            width: 1.5,
                          ),
                        ),
                        child: TextField(
                          controller: _otpControllers[i],
                          focusNode: _otpFocusNodes[i],
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          maxLength: 1,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: _otpError
                                ? const Color(0xFFD32F2F)
                                : AppColors.textPrimary,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            counterText: '',
                          ),
                          onChanged: (v) {
                            setDialogState(() => _otpError = false);
                            if (v.isNotEmpty && i < 3) {
                              FocusScope.of(ctx).requestFocus(_otpFocusNodes[i + 1]);
                            }
                          },
                        ),
                      ),
                    ),
                  )),
                ),

                if (_otpError) ...[
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.error_outline, size: 13, color: Color(0xFFD32F2F)),
                    const SizedBox(width: 4),
                    Flexible(child: Text(_otpErrorText,
                        style: const TextStyle(fontSize: 12, color: Color(0xFFD32F2F)))),
                  ]),
                ],

                const SizedBox(height: 8),

                // Resend OTP
                Center(
                  child: _isResendingOtp
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.textSecondary))
                      : TextButton(
                          onPressed: () => _resendOtp(setDialogState),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.textSecondary,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          ),
                          child: const Text('Resend OTP', style: TextStyle(fontSize: 12)),
                        ),
                ),

                const SizedBox(height: 12),

                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isVerifyingOtp ? null : () => Navigator.pop(ctx),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        side: const BorderSide(color: AppColors.divider),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _isVerifyingOtp
                          ? null
                          : () => _verifyOtp(ctx, setDialogState),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isVerifyingOtp
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Verify',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _otpFocusNodes[0].requestFocus();
    });
  }

  Future<void> _verifyOtp(BuildContext ctx, StateSetter setDialogState) async {
    final otp = _otpControllers.map((c) => c.text).join();
    if (otp.length < 4) {
      setDialogState(() => _otpError = true);
      return;
    }

    setState(() { _isVerifyingOtp = true; _otpError = false; });
    setDialogState(() {});

    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    final result = await ApiService.verifyBookingOtp(bookingId: bookingId, otp: otp);

    if (!mounted) return;

    if (result?['success'] == true) {
      setState(() { _isVerifyingOtp = false; _currentStatus = 'OTP Verified'; });
      if (ctx.mounted) Navigator.pop(ctx);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('OTP verified — tap "Hand Over to Lab" to complete'),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
      ));
    } else {
      final msg = result?['message'] as String? ?? 'Invalid OTP. Please try again.';
      setState(() {
        _isVerifyingOtp = false;
        _otpError       = true;
        _otpErrorText   = msg;
      });
      setDialogState(() {});
    }
  }

  Future<void> _resendOtp(StateSetter setDialogState) async {
    setState(() => _isResendingOtp = true);
    setDialogState(() {});

    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    final result    = await ApiService.resendBookingOtp(bookingId);

    if (!mounted) return;
    setState(() => _isResendingOtp = false);
    setDialogState(() {});

    if (result?['success'] == true) {
      for (final c in _otpControllers) { c.clear(); }
      setState(() { _otpError = false; _otpErrorText = 'Invalid OTP. Please try again.'; });
      setDialogState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('OTP resent successfully'),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } else {
      final msg = result?['message'] as String? ?? 'Failed to resend OTP. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  // ── Tests ─────────────────────────────────────────────────

  Future<void> _removeTest(String id) async {
    // Block all removals once OTP has been verified — visit is finalized at that point.
    if (_isFinalized) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tests cannot be changed after OTP verification.'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (_isTestLocked(id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tests cannot be removed after payment has been collected.'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final test          = _selectedTests.firstWhere((t) => t['id'] == id, orElse: () => {});
    final bookingItemId = int.tryParse(test['bookingItemId'] ?? '');
    // Remove from UI immediately (optimistic)
    setState(() => _selectedTests.removeWhere((t) => t['id'] == id));
    if (bookingItemId != null && bookingItemId > 0) {
      final bookingId = int.tryParse(widget.booking.id) ?? 0;
      await ApiService.removeBookingItem(bookingId: bookingId, bookingItemId: bookingItemId);
    }
  }

  Future<void> _addTest(Map<String, String> t) async {
    // Block new tests once OTP has been verified — visit is finalized at that point.
    if (_isFinalized) return;
    if (_selectedTests.any((x) => x['id'] == t['id'])) return;
    // Add optimistically with empty bookingItemId while the API call is in flight
    setState(() {
      _selectedTests.add({...Map<String, String>.from(t), 'bookingItemId': ''});
      _showAddTest = false;
      _searchQuery = '';
    });
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    final productId = int.tryParse(t['id'] ?? '') ?? 0;
    if (bookingId == 0 || productId == 0) return;
    final result = await ApiService.addBookingItem(bookingId: bookingId, productId: productId);
    if (!mounted) return;
    if (result != null) {
      // Stamp the real bookingItemId on the optimistic entry
      setState(() {
        final idx = _selectedTests.indexWhere(
            (x) => x['id'] == t['id'] && x['bookingItemId'] == '');
        if (idx != -1) {
          _selectedTests[idx]['bookingItemId'] =
              (result['bookingItemId'] as num?)?.toInt().toString() ?? '';
        }
      });
    } else {
      setState(() => _selectedTests.removeWhere(
          (x) => x['id'] == t['id'] && x['bookingItemId'] == ''));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to add test — please retry'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  List<Map<String, String>> get _filteredCatalogue {
    final already = _selectedTests.map((t) => t['id']).toSet();
    return _catalogueItems.where((t) {
      if (already.contains(t['id'])) return false;
      if (_searchQuery.isEmpty) return true;
      return (t['name']?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
          (t['category']?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);
    }).toList();
  }

  // ── Document ──────────────────────────────────────────────

  void _showDocSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(context).padding.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
          ),
          _DocSourceTile(Icons.camera_alt_outlined, 'Camera', 'Take a photo now',
              () { Navigator.pop(context); _pickDoc(ImageSource.camera); }),
          const SizedBox(height: 8),
          _DocSourceTile(Icons.photo_library_outlined, 'Gallery', 'Choose from your photos',
              () { Navigator.pop(context); _pickDoc(ImageSource.gallery); }),
          const SizedBox(height: 4),
        ]),
      ),
    );
  }

  Future<void> _pickDoc(ImageSource source) async {
    if (_docIsPicking || _docUploads.length >= _docMaxFiles) return;
    setState(() => _docIsPicking = true);
    try {
      if (source == ImageSource.gallery) {
        final images = await _picker.pickMultiImage(imageQuality: 80);
        if (images.isNotEmpty) {
          final toAdd = images.take(_docMaxFiles - _docUploads.length);
          for (final f in toAdd) {
            final bytes = await f.readAsBytes();
            final placeholder = _TechPresDoc(
              bytes: bytes, fileName: f.name,
              uploadedAt: DateTime.now(), isUploading: true,
            );
            setState(() => _docUploads.add(placeholder));
            _uploadDoc(placeholder, bytes, f.name);
          }
        }
      } else {
        final image = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
        if (image != null) {
          final bytes = await image.readAsBytes();
          final placeholder = _TechPresDoc(
            bytes: bytes, fileName: image.name,
            uploadedAt: DateTime.now(), isUploading: true,
          );
          setState(() => _docUploads.add(placeholder));
          _uploadDoc(placeholder, bytes, image.name);
        }
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
    setState(() => _docIsPicking = false);
  }

  Future<void> _uploadDoc(_TechPresDoc placeholder, Uint8List bytes, String fileName) async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    final patientId = widget.booking.patientId ?? 0;
    try {
      // Step 1: upload file binary → get URL
      final url = await ApiService.uploadFile(bytes.toList(), fileName);
      if (url == null || !mounted) {
        setState(() => _docUploads.remove(placeholder));
        return;
      }
      // Step 2: save URL linked to booking → get docId
      final docId = await ApiService.savePrescriptionDoc(
        bookingId: bookingId, patientId: patientId, imageUrl: url,
      );
      if (!mounted) return;
      setState(() {
        final idx = _docUploads.indexOf(placeholder);
        if (idx == -1) return;
        if (docId != null) {
          _docUploads[idx] = _TechPresDoc(
            docId: docId, url: url, fileName: fileName,
            uploadedAt: DateTime.now(), docStatus: 'pending_review',
          );
        } else {
          _docUploads.removeAt(idx);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Upload failed — please retry'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ));
        }
      });
    } catch (e) {
      debugPrint('[_uploadDoc] ERROR: $e');
      if (mounted) setState(() => _docUploads.remove(placeholder));
    }
  }

  void _viewDocImage(int index) {
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _DocImageViewerPage(images: _docUploads, initialIndex: index)));
  }

  Future<void> _deleteDocImage(int index) async {
    final doc = _docUploads[index];
    if (doc.isUploading) return; // wait for upload to finish first
    if (doc.docId != null) {
      final ok = await ApiService.deletePrescription(doc.docId!);
      if (!ok || !mounted) return;
    }
    setState(() {
      _docUploads.removeAt(index);
      if (_docUploads.isEmpty) _docVerified = false;
    });
  }

  Future<void> _markDocsVerified() async {
    for (final doc in _docUploads) {
      if (doc.docId != null && !doc.isVerified) {
        final ok = await ApiService.verifyPrescription(doc.docId!);
        if (ok && mounted) setState(() => doc.docStatus = 'verified');
      }
    }
    if (mounted) setState(() => _docVerified = true);
  }

  // ── Payment ───────────────────────────────────────────────

  void _showCompleteSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.fromLTRB(
              20, 0, 20, MediaQuery.of(ctx).padding.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const Text('Complete Booking',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text('${widget.booking.customerName} · ${widget.booking.id}',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 20),

              // Step 1: Payment
              _CompleteStep(
                number: '1',
                title: 'Collect Payment',
                subtitle: _paymentDone
                    ? 'All payments collected'
                    : _livePaymentStatus == 'paid'
                        ? 'Original ₹${_liveAmountPaid.toInt()} paid. Collect additional: ₹${_amountDue.toInt()}'
                        : 'Collect ₹${_amountDue.toInt()} from customer (tests amount)',
                done: _paymentDone,
                locked: false,
                buttonLabel: _paymentDone ? 'Paid ✓' : 'Make Payment  ₹${_amountDue.toInt()}',
                buttonColor: _paymentDone ? AppColors.brandGreen : const Color(0xFF1565C0),
                onTap: _paymentDone
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _collectPayment(onDone: () {
                          Future.delayed(
                              const Duration(milliseconds: 300), _showCompleteSheet);
                        });
                      },
              ),

              const SizedBox(height: 12),

              // Step 2: OTP
              _CompleteStep(
                number: '2',
                title: 'Verify OTP',
                subtitle: 'Ask customer for the OTP sent to their phone',
                done: _currentStatus == 'OTP Verified' || _isCompleted,
                locked: !_paymentDone || _hasUnpaidSiblings,
                buttonLabel: (_currentStatus == 'OTP Verified' || _isCompleted) ? 'Verified ✓' : 'Verify OTP',
                buttonColor: AppColors.brandGreen,
                onTap: (!_paymentDone || _hasUnpaidSiblings || _currentStatus == 'OTP Verified' || _isCompleted)
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _showOtpDialog();
                      },
              ),

              const SizedBox(height: 20),

              if (!_paymentDone)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFFFCC02).withOpacity(0.4)),
                  ),
                  child: const Row(children: [
                    Icon(Icons.info_outline_rounded, size: 13, color: Color(0xFFE65100)),
                    SizedBox(width: 8),
                    Expanded(child: Text(
                      'Complete payment first, then verify OTP to finish the booking.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF795548), height: 1.4),
                    )),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _collectPayment({VoidCallback? onDone}) {
    setState(() => _isProcessingPayment = true);

    final options = {
      'key': 'rzp_test_SonqjjPurqlLci',
      'amount': (_amountDue * 100).toInt(),
      'name': 'MicroLab',
      'description': _selectedTests.map((t) => t['name']).join(', '),
      'prefill': {
        'contact': widget.booking.customerPhone,
        'name': widget.booking.customerName,
      },
      'notes': {
        'booking_id': widget.booking.id,
        'note': 'Test amount (service charge already paid)',
      },
      'theme': {'color': '#0A5C4A'},
    };

    openRazorpay(
      options: options,
      onSuccess: (paymentId) {
        // Capture amount + test IDs before state changes
        final paidAmount      = _amountDue;
        final bookingId       = int.tryParse(widget.booking.id) ?? 0;
        final nowPaidTestIds  = _selectedTests.map((t) => t['id'] ?? '').toSet();
        setState(() {
          _isProcessingPayment     = false;
          _sessionPaymentCollected += paidAmount;
          _livePaymentStatus       = 'paid';
          _paidTestIds             = {..._paidTestIds, ...nowPaidTestIds};
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Payment of ₹${paidAmount.toInt()} received · $paymentId'),
          backgroundColor: AppColors.brandGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
        onDone?.call();
        // Persist to DB and refresh live payment state from server
        () async {
          final ok = await ApiService.collectPayment(
            bookingId: bookingId,
            razorpayPaymentId: paymentId,
            amount: paidAmount,
          );
          if (mounted) _refreshPaymentInfo();
          if (!ok && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Payment saved locally but server sync failed — contact support'),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
              duration: Duration(seconds: 6),
            ));
          }
        }();
      },
      onError: (msg) {
        setState(() => _isProcessingPayment = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg == 'Payment cancelled' ? 'Payment cancelled' : 'Failed: $msg'),
          backgroundColor: Colors.red[700],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      },
    );
  }

  // Collect payment for a visit-member's sibling booking (separate from the parent's payment)
  void _collectVisitMemberPayment({
    required int siblingBookingId,
    required double amountDue,
    required String patientName,
  }) {
    if (amountDue <= 0) return;
    final options = {
      'key': 'rzp_test_SonqjjPurqlLci',
      'amount': (amountDue * 100).toInt(),
      'name': 'MicroLab',
      'description': 'Tests for $patientName',
      'prefill': {
        'contact': widget.booking.customerPhone,
        'name': patientName,
      },
      'notes': {
        'booking_id': siblingBookingId.toString(),
        'note': 'Visit member payment',
      },
      'theme': {'color': '#0A5C4A'},
    };

    openRazorpay(
      options: options,
      onSuccess: (paymentId) async {
        // Optimistic UI update: mark this sibling as paid in the local list
        if (mounted) {
          setState(() {
            _linkedPatients = _linkedPatients.map((p) {
              if ((p['booking_id'] as num?)?.toInt() == siblingBookingId) {
                return {...p, 'payment_status': 'paid', 'amount_due': 0.0};
              }
              return p;
            }).toList();
          });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('₹${amountDue.toInt()} received for $patientName · $paymentId'),
            backgroundColor: AppColors.brandGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
        final ok = await ApiService.collectPayment(
          bookingId: siblingBookingId,
          razorpayPaymentId: paymentId,
          amount: amountDue,
        );
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Payment saved locally but server sync failed — contact support'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 6),
          ));
        }
        // Refresh the list to get accurate server state
        if (mounted) _loadLinkedPatients();
      },
      onError: (msg) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(msg == 'Payment cancelled' ? 'Payment cancelled' : 'Failed: $msg'),
            backgroundColor: Colors.red[700],
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      },
    );
  }

  // Collects a single combined Razorpay payment for all unpaid bookings (parent + siblings).
  // Each booking's ip_payment_transactions row is updated individually using the same
  // Razorpay payment ID — existing per-booking data structure is not changed.
  void _collectAllPayment() {
    final unpaidItems = <Map<String, dynamic>>[];

    if (!_paymentDone && _amountDue > 0) {
      unpaidItems.add({
        'bookingId': int.tryParse(widget.booking.id) ?? 0,
        'amount':    _amountDue,
        'name':      widget.booking.customerName,
        'isParent':  true,
      });
    }
    for (final p in _linkedPatients) {
      final sibId = (p['booking_id'] as num?)?.toInt();
      final due   = double.tryParse(p['amount_due']?.toString() ?? '0') ?? 0.0;
      if (sibId != null && due > 0 && p['payment_status'] != 'paid') {
        unpaidItems.add({
          'bookingId': sibId,
          'amount':    due,
          'name':      p['patient_name'] as String? ?? 'Visit Member',
          'isParent':  false,
        });
      }
    }
    if (unpaidItems.length < 2) return;

    final totalAmount = unpaidItems.fold<double>(0, (s, i) => s + (i['amount'] as double));

    setState(() => _isProcessingPayment = true);

    openRazorpay(
      options: {
        'key':         'rzp_test_SonqjjPurqlLci',
        'amount':      (totalAmount * 100).toInt(),
        'name':        'MicroLab',
        'description': 'Combined payment · ${unpaidItems.length} members',
        'prefill': {
          'contact': widget.booking.customerPhone,
          'name':    widget.booking.customerName,
        },
        'notes': {
          'booking_ids': unpaidItems.map((i) => i['bookingId'].toString()).join(','),
          'note':        'Combined visit payment',
        },
        'theme': {'color': '#0A5C4A'},
      },
      onSuccess: (paymentId) async {
        if (!mounted) return;
        setState(() {
          _isProcessingPayment = false;
          final parentItem = unpaidItems.where((i) => i['isParent'] == true).toList();
          if (parentItem.isNotEmpty) {
            _sessionPaymentCollected += parentItem.first['amount'] as double;
            _livePaymentStatus        = 'paid';
            _paidTestIds              = {..._paidTestIds, ..._selectedTests.map((t) => t['id'] ?? '').toSet()};
          }
          _linkedPatients = _linkedPatients.map((p) {
            final sibId = (p['booking_id'] as num?)?.toInt();
            final inList = unpaidItems.any((i) => i['bookingId'] == sibId && i['isParent'] == false);
            return inList ? {...p, 'payment_status': 'paid', 'amount_due': 0.0} : p;
          }).toList();
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:         Text('Combined ₹${totalAmount.toInt()} received · $paymentId'),
          backgroundColor: AppColors.brandGreen,
          behavior:        SnackBarBehavior.floating,
          shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
        // Persist each booking's record individually with the same Razorpay ID
        for (final item in unpaidItems) {
          await ApiService.collectPayment(
            bookingId:         item['bookingId'] as int,
            razorpayPaymentId: paymentId,
            amount:            item['amount']    as double,
          );
        }
        if (mounted) {
          _refreshPaymentInfo();
          _loadLinkedPatients();
        }
      },
      onError: (msg) {
        if (mounted) {
          setState(() => _isProcessingPayment = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:         Text(msg == 'Payment cancelled' ? 'Payment cancelled' : 'Failed: $msg'),
            backgroundColor: Colors.red[700],
            behavior:        SnackBarBehavior.floating,
            shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentStep = _journeySteps.firstWhere(
      (s) => s.status == _currentStatus,
      orElse: () => _journeySteps.first,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_isCompleted ? true : null);
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context, _isCompleted ? true : null),  // pops with true only when Handed to Lab
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Manage Booking',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            Text(widget.booking.id,
                style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone_outlined, color: Colors.white),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Calling ${widget.booking.customerPhone}…'),
                backgroundColor: AppColors.brandGreen,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [

          // ── Journey Status Stepper ────────────────────────
          _SectionCard(
            title: 'Journey Status',
            icon: Icons.alt_route_rounded,
            child: Column(
              children: [
                ...List.generate(_journeySteps.length, (i) {
                  final step = _journeySteps[i];
                  final isDone = i < _currentStepIndex;
                  final isCurrent = i == _currentStepIndex;
                  final isLast = i == _journeySteps.length - 1;

                  return IntrinsicHeight(
                    child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: isDone || isCurrent
                                ? step.color
                                : AppColors.background,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDone || isCurrent
                                  ? step.color
                                  : AppColors.divider,
                              width: 1.5,
                            ),
                          ),
                          child: Icon(
                            isDone ? Icons.check_rounded : step.icon,
                            size: 16,
                            color: isDone || isCurrent
                                ? Colors.white
                                : AppColors.textHint,
                          ),
                        ),
                        if (!isLast)
                          Expanded(
                            child: Container(
                              width: 2,
                              color: i < _currentStepIndex
                                  ? AppColors.brandGreen
                                  : AppColors.divider,
                            ),
                          ),
                      ]),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: isLast ? 0 : 12, top: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(step.label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                                    color: isCurrent
                                        ? step.color
                                        : isDone
                                            ? AppColors.textSecondary
                                            : AppColors.textHint,
                                  )),
                              if (isCurrent)
                                Text(step.description,
                                    style: TextStyle(
                                        fontSize: 11, color: step.color.withOpacity(0.8))),
                            ],
                          ),
                        ),
                      ),
          if (isCurrent && _canAdvance) ...[
  const SizedBox(width: 8),
  if (_currentStatus == 'Journey Started') 
    // Show Resume button only if not completed
    GestureDetector(
      onTap: _resumeJourney,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1565C0),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'Resume ▸',
          style: TextStyle(
            fontSize: 11, 
            fontWeight: FontWeight.w700, 
            color: Colors.white
          ),
        ),
      ),
    )
  else if (_currentStatus != 'Handed to Lab' && _nextStatus != null)
    GestureDetector(
      onTap: _advanceStatus,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: step.color,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          '${_journeySteps[i + 1].label} ▸',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white
          ),
        ),
      ),
    ),
],          
                    ],
                  ));
                }),
              ],
            ),
            
          ),

          const SizedBox(height: 14),

          // ── Customer Info ─────────────────────────────────
          _SectionCard(
            title: 'Customer Details',
            icon: Icons.person_outline,
            child: Column(children: [
              _InfoRow(Icons.person_outline, 'Name', widget.booking.customerName),
              _InfoRow(Icons.phone_outlined, 'Phone', '+91 ${widget.booking.customerPhone}'),
              _InfoRow(
                widget.booking.mode == 'Home Collection'
                    ? Icons.home_outlined : Icons.local_hospital_outlined,
                'Mode', widget.booking.mode,
              ),
              _InfoRow(Icons.location_on_outlined, 'Address',
                  [widget.booking.address, widget.booking.city, widget.booking.pincode]
                      .where((s) => s.isNotEmpty)
                      .join(', ')),
              _InfoRow(Icons.event_outlined, 'Date', _formatDate(widget.booking.date)),
              _InfoRow(Icons.schedule_outlined, 'Slot', widget.booking.timeSlot),
              if (widget.booking.isVip)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFB300).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFB300)),
                      SizedBox(width: 5),
                      Text('VIP Customer',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFE65100))),
                    ]),
                  ),
                ),
            ]),
          ),

          const SizedBox(height: 14),

          // ── Tests ──────────────────────────────────────────
          _SectionCard(
            title: 'Tests & Packages',
            icon: Icons.science_outlined,
            child: _itemsLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                  )
                : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ..._selectedTests.map((t) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Row(children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: t['category'] == 'Package'
                            ? AppColors.brandGreen : const Color(0xFF1565C0),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t['name'] ?? '',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                        Text(t['category'] ?? '',
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      ]),
                    ),
                    Text('₹${t['price'] ?? '0'}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    // Hide the remove control entirely once the visit is finalized (OTP Verified or Handed to Lab).
                    if (!_isFinalized) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () { _removeTest(t['id'] ?? ''); },
                        child: _isTestLocked(t['id'] ?? '')
                            ? const Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.textHint)
                            : const Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                      ),
                    ],
                  ]),
                )),

                // Always visible; shows a lock icon and disabled style once the visit is finalized.
                if (!_isCompleted && !_showAddTest)
                  GestureDetector(
                    onTap: _isFinalized ? null : () => setState(() => _showAddTest = true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: _isFinalized ? AppColors.background : AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _isFinalized ? AppColors.divider : AppColors.brandGreenLight,
                        ),
                      ),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(
                          _isFinalized ? Icons.lock_outline_rounded : Icons.add_circle_outline,
                          size: 15,
                          color: _isFinalized ? AppColors.textHint : AppColors.brandGreen,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isFinalized ? 'Tests Locked' : 'Add Test / Package',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: _isFinalized ? AppColors.textHint : AppColors.brandGreen,
                          ),
                        ),
                      ]),
                    ),
                  ),

                if (_showAddTest) ...[
                  const SizedBox(height: 8),
                  TextField(
                    autofocus: true,
                    onChanged: (v) => setState(() => _searchQuery = v),
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Search test…',
                      hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textHint),
                      suffixIcon: GestureDetector(
                        onTap: () => setState(() { _showAddTest = false; _searchQuery = ''; }),
                        child: const Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                      ),
                      filled: true, fillColor: AppColors.background,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.divider)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.divider)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._filteredCatalogue.take(5).map((t) => GestureDetector(
                    onTap: () { _addTest(t); },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t['name'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                          Text(t['category'] ?? '', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        ])),
                        Text('₹${t['price']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.brandGreen)),
                        const SizedBox(width: 8),
                        const Icon(Icons.add_circle_outline, size: 18, color: AppColors.brandGreen),
                      ]),
                    ),
                  )),
                ],

                if (_selectedTests.isNotEmpty) ...[
                  const Divider(height: 20),
                  _BillRow('Tests Total', '₹${_testsTotal.toInt()}', bold: true, green: true),
                  const SizedBox(height: 4),
                  _BillRow('Service Charge', '₹${_serviceChargePaid.toInt()} (paid at booking)', sub: true),
                  const Divider(height: 16),
                  _BillRow('Amount Due Now', '₹${_amountDue.toInt()}', bold: true, green: true),
                ],
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ── Prescription / Document ─────────────────────────
          _SectionCard(
            title: 'Prescription / Document',
            icon: Icons.description_outlined,
            badge: widget.booking.docRequired ? 'REQUIRED' : null,
            child: _docsLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: widget.booking.docRequired
                      ? const Color(0xFFFFF3E0)
                      : AppColors.brandGreenSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: widget.booking.docRequired
                        ? const Color(0xFFFFCC02).withOpacity(0.4)
                        : AppColors.brandGreenLight,
                  ),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    widget.booking.docRequired
                        ? Icons.warning_amber_rounded
                        : Icons.info_outline_rounded,
                    size: 13,
                    color: widget.booking.docRequired
                        ? const Color(0xFFE65100)
                        : AppColors.brandGreen,
                  ),
                  const SizedBox(width: 7),
                  Expanded(child: Text(
                    widget.booking.docRequired
                        ? 'This booking requires a doctor\'s prescription. Upload and verify before collecting sample.'
                        : 'Upload prescription if provided by the customer.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: widget.booking.docRequired
                          ? const Color(0xFF795548)
                          : AppColors.brandGreen,
                    ),
                  )),
                ]),
              ),
              const SizedBox(height: 12),

              if (_docUploads.isNotEmpty) ...[
                SizedBox(
                  height: 104,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _docUploads.length +
                        (_docUploads.length < _docMaxFiles ? 1 : 0),
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      if (i == _docUploads.length) {
                        return _DocAddMoreTile(
                          onTap: _docIsPicking ? null : _showDocSourcePicker,
                        );
                      }
                      return _DocThumbnailCard(
                        doc: _docUploads[i],
                        onView: () => _viewDocImage(i),
                        onDelete: () { _deleteDocImage(i); },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_docUploads.length} of $_docMaxFiles image${_docUploads.length == 1 ? '' : 's'} uploaded',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
              ],

              if (_docUploads.isEmpty)
                GestureDetector(
                  onTap: _docIsPicking ? null : _showDocSourcePicker,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 22),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.divider, width: 1.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _docIsPicking
                            ? const SizedBox(
                                width: 24, height: 24,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.brandGreen))
                            : const Icon(Icons.upload_file_outlined,
                                size: 28, color: AppColors.brandGreen),
                        const SizedBox(height: 8),
                        Text(
                          _docIsPicking ? 'Picking…' : 'Tap to upload prescription',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.brandGreen),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Up to $_docMaxFiles images · JPG or PNG',
                          style: const TextStyle(fontSize: 11, color: AppColors.textHint),
                        ),
                      ],
                    ),
                  ),
                ),

              if (_docUploads.isNotEmpty && !_docVerified) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _markDocsVerified,
                    icon: const Icon(Icons.verified_outlined, size: 16),
                    label: const Text('Mark as Verified',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
              if (_docVerified) ...[
                const SizedBox(height: 8),
                const Row(children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: AppColors.brandGreen),
                  SizedBox(width: 6),
                  Text('All documents verified',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.brandGreen)),
                ]),
              ],
            ]),
          ),

          // ── Collect Payment ──────────────────────────────
          if (!_isCompleted)
            _SectionCard(
              title: 'Collect Payment',
              icon: Icons.payment_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // Info banner
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreenSurface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.brandGreenLight),
                  ),
                  child: Row(children: [
                    const Icon(Icons.info_outline_rounded, size: 14, color: AppColors.brandGreen),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      _paymentDone
                          ? 'Service charge ₹${_serviceChargePaid.toInt()} paid at booking. All tests also paid.'
                          : _livePaymentStatus == 'paid'
                              ? 'Original booking (₹${_liveAmountPaid.toInt()}) paid. Collect additional tests: ₹${_amountDue.toInt()}'
                              : 'Service charge ₹${_serviceChargePaid.toInt()} paid at booking. Collect tests amount: ₹${_amountDue.toInt()}',
                      style: const TextStyle(fontSize: 12, color: AppColors.brandGreen, height: 1.4),
                    )),
                  ]),
                ),
                const SizedBox(height: 12),

                // Billing Summary — per-person breakdown before collect buttons
                ...() {
                  final rows = <Map<String, dynamic>>[];
                  if (!_paymentDone && _amountDue > 0) {
                    rows.add({
                      'name':   '${widget.booking.customerName} (Tests)',
                      'amount': _amountDue,
                    });
                  }
                  for (final p in _linkedPatients) {
                    final due = double.tryParse(p['amount_due']?.toString() ?? '0') ?? 0.0;
                    if (p['payment_status'] != 'paid' && due > 0) {
                      rows.add({
                        'name':   p['patient_name'] as String? ?? 'Visit Member',
                        'amount': due,
                      });
                    }
                  }
                  if (rows.isEmpty) return <Widget>[];
                  final totalDue = rows.fold<double>(0, (s, r) => s + (r['amount'] as double));
                  return [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F7FA),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE0E4EA)),
                      ),
                      child: Column(
                        children: [
                          ...rows.map<Widget>((r) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(r['name'] as String,
                                    style: const TextStyle(fontSize: 13, color: Color(0xFF555555))),
                                Text('₹${(r['amount'] as double).toInt()}',
                                    style: const TextStyle(fontSize: 13, color: Color(0xFF333333))),
                              ],
                            ),
                          )),
                          const Divider(height: 16, thickness: 1),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Total Due',
                                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                              Text('₹${totalDue.toInt()}',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1565C0))),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ];
                }(),

                // Collect All — single Razorpay transaction when 2+ bookings are unpaid
                ...() {
                  final parentUnpaid    = !_paymentDone && _amountDue > 0;
                  final unpaidSiblings  = _linkedPatients.where((c) {
                    final due = double.tryParse(c['amount_due']?.toString() ?? '0') ?? 0.0;
                    return (c['booking_id'] as num?) != null && due > 0 && c['payment_status'] != 'paid';
                  }).toList();
                  final totalUnpaid     = (parentUnpaid ? 1 : 0) + unpaidSiblings.length;
                  if (totalUnpaid < 2) return <Widget>[];
                  final totalAmount     = (parentUnpaid ? _amountDue : 0.0) +
                      unpaidSiblings.fold<double>(0, (s, c) =>
                          s + (double.tryParse(c['amount_due']?.toString() ?? '0') ?? 0.0));
                  return [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isProcessingPayment ? null : _collectAllPayment,
                        icon: _isProcessingPayment
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.payments_outlined, size: 18),
                        label: Text(
                          _isProcessingPayment
                              ? 'Processing…'
                              : 'Collect All ₹${totalAmount.toInt()} · $totalUnpaid members',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          elevation:       0,
                          padding:         const EdgeInsets.symmetric(vertical: 14),
                          shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ];
                }(),

                // Single-booking button — shown only when exactly one booking is unpaid
                // (Collect All handles the 2+ case above)
                ...() {
                  final parentUnpaid   = !_paymentDone && _amountDue > 0;
                  final unpaidSiblings = _linkedPatients.where((c) {
                    final sibId = (c['booking_id'] as num?)?.toInt();
                    final due   = double.tryParse(c['amount_due']?.toString() ?? '0') ?? 0.0;
                    return sibId != null && due > 0 && c['payment_status'] != 'paid';
                  }).toList();
                  if ((parentUnpaid ? 1 : 0) + unpaidSiblings.length >= 2) return <Widget>[];

                  final widgets = <Widget>[];

                  if (parentUnpaid) {
                    widgets.add(SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isProcessingPayment ? null : () => _collectPayment(onDone: null),
                        icon: _isProcessingPayment
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.payment_outlined, size: 18),
                        label: Text(
                          _isProcessingPayment
                              ? 'Processing…'
                              : 'Collect ₹${_amountDue.toInt()} · ${widget.booking.customerName}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1565C0),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ));
                  }

                  for (final c in unpaidSiblings) {
                    final sibId = (c['booking_id'] as num?)!.toInt();
                    final due   = double.tryParse(c['amount_due']?.toString() ?? '0') ?? 0.0;
                    final mName = c['patient_name'] as String? ?? 'Visit Member';
                    widgets.add(Padding(
                      padding: EdgeInsets.only(top: widgets.isEmpty ? 0 : 8),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _collectVisitMemberPayment(
                            siblingBookingId: sibId,
                            amountDue: due,
                            patientName: mName,
                          ),
                          icon: const Icon(Icons.payment_outlined, size: 18),
                          label: Text('Collect ₹${due.toInt()} · $mName',
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1565C0),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ));
                  }

                  if (widgets.isEmpty && _paymentDone) {
                    widgets.add(SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.check_circle_outline, size: 18),
                        label: const Text('Booking Paid ✓',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ));
                  }

                  return widgets;
                }(),

                // Refresh row
                const SizedBox(height: 4),
                Center(
                  child: TextButton.icon(
                    onPressed: () {
                      _refreshPaymentInfo();
                      _loadLinkedPatients();
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 15),
                    label: const Text('Refresh payment status', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                  ),
                ),
              ]),
            ),

          const SizedBox(height: 14),

          // ── Visit Members (Same Location) ─────────────────
          _SectionCard(
            title: 'Visit Members',
            icon: Icons.group_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Add family members at this address who also need a blood test during this visit.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 12),

                if (_linkedPatients.isNotEmpty) ...[
                  ..._linkedPatients.map((c) {
                    final amountDue   = double.tryParse(c['amount_due']?.toString() ?? '0') ?? 0.0;
                    final totalAmount = double.tryParse(c['total_amount']?.toString() ?? '0') ?? 0.0;
                    final isPaid      = c['payment_status'] == 'paid' || amountDue <= 0;
                    final hasPayment  = (c['booking_id'] as num?) != null && totalAmount > 0;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.brandGreenLight),
                      ),
                      child: Row(children: [
                        const Icon(Icons.check_circle_outline_rounded, size: 16, color: AppColors.brandGreen),
                        const SizedBox(width: 8),
                        Expanded(child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${c['patient_name'] ?? ''}  ·  ${c['patient_mobile'] ?? ''}',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            if ((c['booking_ref'] as String?) != null)
                              Text(c['booking_ref'] as String,
                                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                          ],
                        )),
                        if (hasPayment)
                          isPaid
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.brandGreen.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text('Paid ✓',
                                    style: TextStyle(fontSize: 11, color: AppColors.brandGreen, fontWeight: FontWeight.w600)),
                              )
                            : Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE3F2FD),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text('₹${amountDue.toInt()} due',
                                    style: const TextStyle(fontSize: 11, color: Color(0xFF1565C0), fontWeight: FontWeight.w600)),
                              ),
                      ]),
                    );
                  }),
                  const SizedBox(height: 8),
                ],

                // Disabled with lock icon once visit is finalized — no new family members after OTP.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isFinalized ? null : _openAddVisitMemberSheet,
                    icon: Icon(
                      _isFinalized ? Icons.lock_outline_rounded : Icons.person_add_outlined,
                      size: 16,
                    ),
                    label: Text(_isFinalized ? 'Visit Member Locked' : 'Add Visit Member'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _isFinalized ? AppColors.textHint : AppColors.brandGreen,
                      side: BorderSide(
                        color: _isFinalized ? AppColors.divider : AppColors.brandGreen,
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),

      bottomNavigationBar: Container(
              padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    if (!_isCompleted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: const Text('Changes saved'),
                        backgroundColor: AppColors.brandGreen,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ));
                    }
                    Navigator.pop(context, _isCompleted ? true : null);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    _isCompleted ? 'Done' : 'Save Changes',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
      ),   // Scaffold
    );     // PopScope
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }
}

// ─── Reusable widgets ─────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final String? badge;
  const _SectionCard({required this.title, required this.icon, required this.child, this.badge});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 15, color: AppColors.brandGreen),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            if (badge != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFFFFF3E0), borderRadius: BorderRadius.circular(6)),
                child: Text(badge!, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFE65100), letterSpacing: 0.5)),
              ),
            ],
          ]),
          const SizedBox(height: 12),
          child,
        ]),
      );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 14, color: AppColors.brandGreen),
          const SizedBox(width: 10),
          SizedBox(width: 80, child: Text(label,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          Expanded(child: Text(value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textPrimary))),
        ]),
      );
}

class _BillRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final bool green;
  final bool sub;
  const _BillRow(this.label, this.value, {this.bold = false, this.green = false, this.sub = false});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: sub ? 12 : 13, color: sub ? AppColors.textSecondary : AppColors.textPrimary)),
          Text(value, style: TextStyle(fontSize: sub ? 12 : 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: green ? AppColors.brandGreen : AppColors.textPrimary)),
        ],
      );
}

// ─── Complete Step Widget ─────────────────────────────────────────────────────

class _CompleteStep extends StatelessWidget {
  final String number;
  final String title;
  final String subtitle;
  final bool done;
  final bool locked;
  final String buttonLabel;
  final Color buttonColor;
  final VoidCallback? onTap;

  const _CompleteStep({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.done,
    required this.locked,
    required this.buttonLabel,
    required this.buttonColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: done
            ? AppColors.brandGreenSurface
            : locked
                ? AppColors.background
                : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: done
              ? AppColors.brandGreen
              : locked
                  ? AppColors.divider
                  : AppColors.divider,
          width: done ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: done
                  ? AppColors.brandGreen
                  : locked
                      ? AppColors.divider
                      : buttonColor.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: done
                  ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
                  : locked
                      ? const Icon(Icons.lock_outline_rounded, size: 14, color: AppColors.textHint)
                      : Text(number,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: buttonColor)),
            ),
          ),
          const SizedBox(width: 12),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: locked ? AppColors.textHint : AppColors.textPrimary)),
                Text(subtitle,
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),

          GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: onTap == null
                    ? (done ? AppColors.brandGreen : AppColors.divider)
                    : buttonColor,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                buttonLabel,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: onTap == null && !done
                        ? AppColors.textHint
                        : Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Form Field Widget ────────────────────────────────────────────────────────

class _FormField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType keyboardType;
  final int maxLines;

  const _FormField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType = TextInputType.text,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            keyboardType: keyboardType,

            maxLines: maxLines,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
              prefixIcon: Icon(icon, size: 18, color: AppColors.textHint),
              counterText: '',
              filled: true,
              fillColor: AppColors.background,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.divider)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.divider)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
              contentPadding: EdgeInsets.symmetric(
                  vertical: maxLines > 1 ? 14 : 12, horizontal: 14),
            ),
          ),
        ],
      );
}

// ─── Document upload widgets ──────────────────────────────────────────────────

class _DocThumbnailCard extends StatelessWidget {
  final _TechPresDoc doc;
  final VoidCallback onView;
  final VoidCallback onDelete;
  const _DocThumbnailCard({
    required this.doc,
    required this.onView,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onView,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.divider),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: doc.isUploading
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen))
                  : doc.bytes != null
                      ? Image.memory(doc.bytes!, fit: BoxFit.cover)
                      : Image.network(
                          doc.url!,
                          fit: BoxFit.cover,
                          loadingBuilder: (_, child, progress) =>
                              progress == null ? child : const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: AppColors.textHint),
                        ),
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                    color: Color(0xFFD32F2F), shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 13, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            bottom: 6,
            right: 6,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.45),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.fullscreen_rounded, size: 14, color: Colors.white),
            ),
          ),
        ]),
      );
}

class _DocAddMoreTile extends StatelessWidget {
  final VoidCallback? onTap;
  const _DocAddMoreTile({this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.brandGreenLight, width: 1.5),
            color: AppColors.brandGreenSurface,
          ),
          child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.add_photo_alternate_outlined, size: 26, color: AppColors.brandGreen),
            SizedBox(height: 4),
            Text('Add more',
                style: TextStyle(
                    fontSize: 10,
                    color: AppColors.brandGreen,
                    fontWeight: FontWeight.w500)),
          ]),
        ),
      );
}

class _DocSourceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _DocSourceTile(this.icon, this.title, this.subtitle, this.onTap);

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreenSurface, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: AppColors.brandGreen),
            ),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
            ]),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textHint),
          ]),
        ),
      );
}

// ─── Full-screen document image viewer ───────────────────────────────────────

class _DocImageViewerPage extends StatefulWidget {
  final List<_TechPresDoc> images;
  final int initialIndex;
  const _DocImageViewerPage({required this.images, required this.initialIndex});

  @override
  State<_DocImageViewerPage> createState() => _DocImageViewerPageState();
}

class _DocImageViewerPageState extends State<_DocImageViewerPage> {
  late final PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: _current);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(
            widget.images.length > 1
                ? 'Photo ${_current + 1} of ${widget.images.length}'
                : 'Photo',
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
        body: Column(children: [
          Expanded(
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _current = i),
              itemBuilder: (_, i) {
                final doc = widget.images[i];
                return InteractiveViewer(
                  maxScale: 5.0,
                  child: Center(
                    child: doc.bytes != null
                        ? Image.memory(doc.bytes!, fit: BoxFit.contain)
                        : Image.network(
                            doc.url!,
                            fit: BoxFit.contain,
                            loadingBuilder: (_, child, progress) => progress == null
                                ? child
                                : const CircularProgressIndicator(color: Colors.white),
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.broken_image, color: Colors.white54, size: 48),
                          ),
                  ),
                );
              },
            ),
          ),
          if (widget.images.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 24, top: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(widget.images.length, (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: _current == i ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _current == i ? Colors.white : Colors.white38,
                    borderRadius: BorderRadius.circular(3),
                  ),
                )),
              ),
            ),
        ]),
      );
}

// ─── Add Visit Member bottom sheet ───────────────────────────────────────────

class _AddVisitMemberSheet extends StatefulWidget {
  final int parentBookingId;
  final List<Map<String, String>> catalogueItems;
  final Set<String> parentTestIds;
  // Patient IDs already linked to this visit — excluded from the picker
  // so the technician cannot add the same person twice.
  final Set<int> linkedPatientIds;

  const _AddVisitMemberSheet({
    required this.parentBookingId,
    required this.catalogueItems,
    required this.parentTestIds,
    required this.linkedPatientIds,
  });

  @override
  State<_AddVisitMemberSheet> createState() => _AddVisitMemberSheetState();
}

class _AddVisitMemberSheetState extends State<_AddVisitMemberSheet> {
  // 0 = patient info, 1 = test selection, 2 = queue review
  int _step = 0;
  // 'select' shows family cards; 'newPatient' shows the mobile+form
  String _mode = 'select';

  // ── Queued members awaiting Submit All ──────────────────────────────────
  final List<Map<String, dynamic>> _queuedMembers = [];

  // ── Family members (loaded on init) ─────────────────────────────────────
  bool _loadingFamily = true;
  List<Map<String, dynamic>> _familyMembers = [];
  Map<String, dynamic>? _selectedFamilyMember;

  // ── New patient form ─────────────────────────────────────────────────────
  final _mobileCtrl = TextEditingController();
  bool _isSearching = false;
  Map<String, dynamic>? _foundPatient;
  bool _searchedWithNoResult = false;
  final _nameCtrl   = TextEditingController();
  final _dobCtrl    = TextEditingController();
  final _healthCtrl = TextEditingController();
  DateTime? _dob;
  int? _age;
  String? _gender;
  String? _relation;

  // ── Test selection ───────────────────────────────────────────────────────
  final Set<String> _selectedTestIds = {};
  String _testSearch = '';
  bool _isSaving = false;

  static const _relations = [
    'Self','Spouse','Father','Mother','Son','Daughter','Brother','Sister','Other',
  ];

  static const _avatarColors = [
    Color(0xFF1565C0), Color(0xFF2E7D32), Color(0xFFE65100),
    Color(0xFF6A1B9A), Color(0xFFC62828), Color(0xFF00695C),
    Color(0xFF4527A0), Color(0xFF558B2F), Color(0xFF00838F),
  ];

  @override
  void initState() {
    super.initState();
    _nameCtrl.addListener(_onFormChanged);
    _mobileCtrl.addListener(_onFormChanged);
    _loadFamilyMembers();
  }

  void _onFormChanged() { if (mounted) setState(() {}); }

  // Family members minus anyone already on this visit or already queued this session.
  List<Map<String, dynamic>> get _availableMembers {
    final queuedIds = _queuedMembers
        .map((m) => (m['patientId'] as num?)?.toInt() ?? 0)
        .where((id) => id > 0)
        .toSet();
    return _familyMembers.where((m) {
      final id = (m['patient_id'] as num?)?.toInt() ?? 0;
      return !widget.linkedPatientIds.contains(id) && !queuedIds.contains(id);
    }).toList();
  }

  Future<void> _loadFamilyMembers() async {
    try {
      final members = await ApiService.getBookingFamily(widget.parentBookingId);
      if (!mounted) return;
      setState(() {
        _familyMembers = members;
        _loadingFamily = false;
        // Switch to form if no selectable members remain after filtering
        if (_availableMembers.isEmpty) _mode = 'newPatient';
      });
    } catch (_) {
      if (mounted) setState(() { _loadingFamily = false; _mode = 'newPatient'; });
    }
  }

  @override
  void dispose() {
    _mobileCtrl.dispose();
    _nameCtrl.dispose();
    _dobCtrl.dispose();
    _healthCtrl.dispose();
    super.dispose();
  }

  Color _avatarColor(String name) {
    if (name.isEmpty) return _avatarColors[0];
    return _avatarColors[name.codeUnitAt(0) % _avatarColors.length];
  }

  double get _selectedTotal => widget.catalogueItems
      .where((t) => _selectedTestIds.contains(t['id']))
      .fold(0.0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0));

  double get _queuedTotal => _queuedMembers
      .fold(0.0, (s, m) => s + ((m['total'] as num?)?.toDouble() ?? 0.0));

  List<Map<String, String>> get _filteredTests {
    final available = widget.catalogueItems
        .where((t) => !widget.parentTestIds.contains(t['id']))
        .toList();
    if (_testSearch.isEmpty) return available;
    final q = _testSearch.toLowerCase();
    return available.where((t) =>
        (t['name']?.toLowerCase().contains(q) ?? false) ||
        (t['category']?.toLowerCase().contains(q) ?? false)).toList();
  }

  void _selectFamilyMember(Map<String, dynamic> m) {
    setState(() {
      _selectedFamilyMember = m;
      _foundPatient = m;
      _nameCtrl.text   = (m['patient_name']   as String?) ?? '';
      _mobileCtrl.text = (m['patient_mobile'] as String?) ?? '';
    });
  }

  Future<void> _searchPatient() async {
    final mobile = _mobileCtrl.text.trim();
    if (mobile.length != 10) return;
    setState(() { _isSearching = true; _foundPatient = null; _searchedWithNoResult = false; });
    try {
      final result = await ApiService.lookupPatientByMobile(
        mobile: mobile,
        bookingId: widget.parentBookingId,
      );
      if (!mounted) return;
      setState(() {
        _foundPatient = result;
        _isSearching = false;
        _searchedWithNoResult = result == null;
        if (result != null && _nameCtrl.text.trim().isEmpty) {
          _nameCtrl.text = result['patient_name'] as String? ?? '';
        }
      });
    } catch (_) {
      if (mounted) setState(() { _isSearching = false; _searchedWithNoResult = true; });
    }
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 30),
      firstDate: DateTime(now.year - 120),
      lastDate: now,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.light(primary: AppColors.brandGreen)),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      int age = now.year - picked.year;
      if (now.month < picked.month ||
          (now.month == picked.month && now.day < picked.day)) { age--; }
      setState(() {
        _dob = picked;
        _age = age;
        _dobCtrl.text =
            '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      });
    }
  }

  void _onNextStep() {
    if (_mode == 'select') {
      if (_selectedFamilyMember == null) return;
    } else {
      if (_nameCtrl.text.trim().isEmpty || _mobileCtrl.text.trim().length != 10) return;
    }
    setState(() => _step = 1);
  }

  // Builds the member payload from the current form and appends to _queuedMembers,
  // then resets the form so the technician can add another member.
  void _addToQueue() {
    if (_selectedTestIds.isEmpty) return;

    final String name;
    final String mobile;
    int? patientId;
    int? age;
    String? gender;
    String? relation;
    String? dobStr;

    if (_mode == 'select') {
      name      = (_selectedFamilyMember?['patient_name']   as String? ?? '').trim();
      mobile    = (_selectedFamilyMember?['patient_mobile'] as String? ?? '').trim();
      patientId = (_selectedFamilyMember?['patient_id']     as num?)?.toInt();
      age       = (_selectedFamilyMember?['patient_age']    as num?)?.toInt();
      gender    = _selectedFamilyMember?['patient_gender']  as String?;
      relation  = _selectedFamilyMember?['patient_relation'] as String?;
    } else {
      name      = _nameCtrl.text.trim();
      mobile    = _mobileCtrl.text.trim();
      patientId = (_foundPatient?['patient_id'] as num?)?.toInt();
      age       = _age;
      gender    = _gender;
      relation  = _relation;
      if (_dob != null) {
        dobStr = '${_dob!.year}-${_dob!.month.toString().padLeft(2,'0')}-${_dob!.day.toString().padLeft(2,'0')}';
      }
    }

    final tests = widget.catalogueItems
        .where((t) => _selectedTestIds.contains(t['id']))
        .map((t) => <String, dynamic>{
              'productId': int.tryParse(t['id'] ?? '0') ?? 0,
              'price': double.tryParse(t['price'] ?? '0') ?? 0.0,
            })
        .where((t) => (t['productId'] as int) > 0)
        .toList();

    final totalAmount = _selectedTotal;

    setState(() {
      _queuedMembers.add({
        'name':       name,
        'mobile':     mobile,
        if (patientId != null) 'patientId': patientId,
        if (dobStr != null)    'dob':       dobStr,
        if (age != null)       'age':       age,
        if (gender != null)    'gender':    gender,
        if (relation != null)  'relation':  relation,
        if (_healthCtrl.text.trim().isNotEmpty) 'healthNotes': _healthCtrl.text.trim(),
        'tests': tests,
        'total': totalAmount,  // UI-only field, stripped before API call
      });
      _step = 2;
    });
  }

  void _addAnotherMember() {
    setState(() {
      _step = 0;
      _mode = _availableMembers.isEmpty ? 'newPatient' : 'select';
      _selectedFamilyMember = null;
      _foundPatient = null;
      _searchedWithNoResult = false;
      _mobileCtrl.clear();
      _nameCtrl.clear();
      _dobCtrl.clear();
      _healthCtrl.clear();
      _dob = null; _age = null; _gender = null; _relation = null;
      _selectedTestIds.clear();
      _testSearch = '';
    });
  }

  Future<void> _submitAll() async {
    if (_queuedMembers.isEmpty) return;
    setState(() => _isSaving = true);

    // Strip the UI-only 'total' field before sending to server
    final apiMembers = _queuedMembers.map((m) {
      final copy = Map<String, dynamic>.from(m);
      copy.remove('total');
      return copy;
    }).toList();

    try {
      final result = await ApiService.addVisitMembers(
        parentBookingId: widget.parentBookingId,
        members: apiMembers,
      );
      if (!mounted) return;
      if (result != null) {
        final firstName = (_queuedMembers.first['name'] as String? ?? '');
        Navigator.pop(context, {
          'count':     _queuedMembers.length,
          'firstName': firstName,
          'members':   result['members'],
        });
      } else {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to add members — please retry'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      debugPrint('[_AddVisitMemberSheet._submitAll] ERROR: $e');
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to add members — please retry'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  bool get _canProceed {
    if (_step == 2) return _queuedMembers.isNotEmpty;
    if (_step == 1) return _selectedTestIds.isNotEmpty;
    if (_mode == 'select') return _selectedFamilyMember != null;
    return _nameCtrl.text.trim().isNotEmpty && _mobileCtrl.text.trim().length == 10;
  }

  String get _headerTitle {
    if (_step == 2) return 'Review Members (${_queuedMembers.length})';
    if (_step == 1) {
      final n = _mode == 'select'
          ? (_selectedFamilyMember?['patient_name'] as String? ?? _nameCtrl.text.trim())
          : _nameCtrl.text.trim();
      return 'Select Tests for $n';
    }
    if (_mode == 'newPatient' && _availableMembers.isNotEmpty) return 'Add New Customer';
    return 'Add Visit Member';
  }

  bool get _showBackArrow =>
      _step == 1 ||
      _step == 2 ||
      (_step == 0 && _mode == 'newPatient' && _availableMembers.isNotEmpty);

  void _onBack() {
    if (_step == 2) {
      // Return to test selection for the last queued member, or to patient form if queue is empty
      if (_queuedMembers.isNotEmpty) {
        final last = _queuedMembers.removeLast();
        final tests = last['tests'] as List? ?? [];
        setState(() {
          _step = 1;
          _selectedTestIds
            ..clear()
            ..addAll(tests.map((t) => t['productId']?.toString() ?? '').where((id) => id.isNotEmpty));
        });
      } else {
        setState(() => _step = 0);
      }
    } else if (_step == 1) {
      setState(() { _step = 0; _selectedTestIds.clear(); _testSearch = ''; });
    } else if (_step == 0) {
      setState(() { _mode = 'select'; _mobileCtrl.clear(); _nameCtrl.clear();
                    _foundPatient = null; _searchedWithNoResult = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            decoration: BoxDecoration(
                color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              if (_showBackArrow) ...[
                GestureDetector(
                  onTap: _onBack,
                  child: const Icon(Icons.arrow_back_rounded, size: 20,
                      color: AppColors.textPrimary),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  _headerTitle,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          Expanded(child: switch (_step) {
            0 => _buildStep0(scroll),
            1 => _buildTestStep(scroll),
            _ => _buildReviewStep(scroll),
          }),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, bottom + 12),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isSaving ? null : switch (_step) {
                  0 => _canProceed ? _onNextStep : null,
                  1 => _canProceed ? _addToQueue : null,
                  _ => _canProceed ? _submitAll  : null,
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _canProceed
                      ? AppColors.brandGreen
                      : AppColors.brandGreen.withValues(alpha: 0.35),
                  disabledBackgroundColor: AppColors.brandGreen.withValues(alpha: 0.35),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _isSaving
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(
                        switch (_step) {
                          0 => 'Next: Select Tests',
                          1 => _selectedTestIds.isEmpty
                              ? 'Select at least one test'
                              : 'Add to Queue · ₹${_selectedTotal.toInt()}',
                          _ => 'Submit ${_queuedMembers.length} Member${_queuedMembers.length == 1 ? '' : 's'}'
                              ' · ₹${_queuedTotal.toInt()}',
                        },
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                      ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildStep0(ScrollController scroll) =>
      _mode == 'select' ? _buildSelectMode(scroll) : _buildNewPatientForm(scroll);

  // ── Step 0-A: Family member cards ────────────────────────────────────────

  Widget _buildSelectMode(ScrollController scroll) {
    if (_loadingFamily) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen),
      );
    }
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Select a family member',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        const SizedBox(height: 12),

        ..._availableMembers.map(_buildFamilyCard),

        const SizedBox(height: 4),
        const Divider(height: 24),

        // Add new customer option
        GestureDetector(
          onTap: () => setState(() => _mode = 'newPatient'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: AppColors.brandGreenSurface,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Icon(Icons.person_add_rounded,
                    size: 20, color: AppColors.brandGreen),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Add New Customer',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  SizedBox(height: 2),
                  Text('Search or create a new patient',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textHint),
            ]),
          ),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _buildFamilyCard(Map<String, dynamic> m) {
    final name     = (m['patient_name']   as String?) ?? '';
    final relation = (m['patient_relation'] as String?) ?? '';
    final mobile   = (m['patient_mobile'] as String?) ?? '';
    final isSelected = _selectedFamilyMember == m;
    final initial  = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final color    = _avatarColor(name);

    return GestureDetector(
      onTap: () => _selectFamilyMember(m),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.brandGreenSurface : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColors.brandGreen : AppColors.divider,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: color.withValues(alpha: 0.15),
            child: Text(initial,
                style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 17)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 3),
            Row(children: [
              if (relation.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(relation, style: TextStyle(
                      fontSize: 11, color: color, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(width: 6),
              ],
              if (mobile.isNotEmpty)
                Text(mobile, style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
            ]),
          ])),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 20, height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? AppColors.brandGreen : AppColors.divider,
                width: isSelected ? 2 : 1.5,
              ),
              color: Colors.white,
            ),
            child: isSelected
                ? Center(child: Container(
                    width: 10, height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.brandGreen,
                    ),
                  ))
                : null,
          ),
        ]),
      ),
    );
  }

  // ── Step 0-B: New patient form ────────────────────────────────────────────

  Widget _buildNewPatientForm(ScrollController scroll) {
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Mobile Number *',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _mobileCtrl,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              autofocus: true,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: '10-digit mobile number',
                hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 14),
                prefixIcon: const Icon(Icons.phone_outlined, size: 18, color: AppColors.textHint),
                counterText: '',
                filled: true, fillColor: AppColors.background,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.divider)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.divider)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: _isSearching ? null : _searchPatient,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                disabledBackgroundColor: AppColors.brandGreen.withValues(alpha: 0.5),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: _isSearching
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.search_rounded, size: 20, color: Colors.white),
            ),
          ),
        ]),

        if (_foundPatient != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.brandGreenSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.brandGreenLight),
            ),
            child: Row(children: [
              const Icon(Icons.person_pin_rounded, size: 16, color: AppColors.brandGreen),
              const SizedBox(width: 8),
              Expanded(child: Text(
                _foundPatient!['patient_name'] as String? ?? '',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                    color: AppColors.brandGreen),
              )),
              const Text('Existing patient',
                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ]),
          ),
        ] else if (_searchedWithNoResult) ...[
          const SizedBox(height: 8),
          const Row(children: [
            Icon(Icons.person_add_outlined, size: 14, color: AppColors.textSecondary),
            SizedBox(width: 6),
            Text('New patient — fill details below',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ]),
        ],

        const SizedBox(height: 14),

        _FormField(
          label: 'Full Name *',
          controller: _nameCtrl,
          hint: 'Enter full name',
          icon: Icons.person_outline,
          keyboardType: TextInputType.name,
        ),
        const SizedBox(height: 10),

        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Date of Birth',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: _pickDob,
            child: Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.divider),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                const Icon(Icons.cake_outlined, size: 18, color: AppColors.textHint),
                const SizedBox(width: 10),
                Expanded(child: Text(
                  _dobCtrl.text.isEmpty ? 'DD / MM / YYYY' : _dobCtrl.text,
                  style: TextStyle(fontSize: 14,
                      color: _dobCtrl.text.isEmpty
                          ? AppColors.textHint : AppColors.textPrimary),
                )),
                if (_age != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text('$_age yrs', style: const TextStyle(
                        fontSize: 12, color: AppColors.brandGreen,
                        fontWeight: FontWeight.w600)),
                  ),
                const SizedBox(width: 6),
                const Icon(Icons.calendar_month_outlined, size: 18,
                    color: AppColors.textSecondary),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 10),

        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Gender',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8, runSpacing: 6,
            children: ['Male', 'Female', 'Other'].map((g) => GestureDetector(
              onTap: () => setState(() => _gender = g),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: _gender == g ? AppColors.brandGreen : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: _gender == g ? AppColors.brandGreen : AppColors.divider),
                ),
                child: Text(g, style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500,
                    color: _gender == g ? Colors.white : AppColors.textSecondary)),
              ),
            )).toList(),
          ),
        ]),
        const SizedBox(height: 10),

        Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.background,
            border: Border.all(color: AppColors.divider),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Icon(Icons.group_outlined, size: 18, color: AppColors.textHint),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<String>(
                value: _relation,
                isExpanded: true,
                underline: const SizedBox(),
                hint: const Text('Relation to primary patient',
                    style: TextStyle(fontSize: 13, color: AppColors.textHint)),
                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                items: _relations.map((r) =>
                    DropdownMenuItem(value: r, child: Text(r))).toList(),
                onChanged: (v) => setState(() => _relation = v),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),

        _FormField(
          label: 'Health Condition / Notes',
          controller: _healthCtrl,
          hint: 'e.g. Diabetes, Hypertension, Thyroid…',
          icon: Icons.medical_information_outlined,
          maxLines: 2,
        ),
        const SizedBox(height: 20),
      ]),
    );
  }

  // ── Step 1: Test selection ────────────────────────────────────────────────

  Widget _buildTestStep(ScrollController scroll) {
    final filtered = _filteredTests;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          onChanged: (v) => setState(() => _testSearch = v),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Search test or package…',
            hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
            prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textHint),
            filled: true, fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
      Expanded(
        child: ListView.separated(
          controller: scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          itemCount: filtered.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final t = filtered[i];
            final checked = _selectedTestIds.contains(t['id']);
            return CheckboxListTile(
              value: checked,
              onChanged: (v) => setState(() {
                if (v!) { _selectedTestIds.add(t['id']!); }
                else     { _selectedTestIds.remove(t['id']); }
              }),
              activeColor: AppColors.brandGreen,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              title: Text(t['name'] ?? '',
                  style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
              subtitle: (t['category'] ?? '').isNotEmpty
                  ? Text(t['category']!,
                      style: const TextStyle(fontSize: 11, color: AppColors.brandGreen))
                  : null,
              secondary: Text('₹${t['price'] ?? '0'}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              controlAffinity: ListTileControlAffinity.leading,
            );
          },
        ),
      ),
    ]);
  }

  // ── Step 2: Queue review ──────────────────────────────────────────────────

  Widget _buildReviewStep(ScrollController scroll) {
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Info banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: AppColors.brandGreenSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.brandGreenLight),
          ),
          child: const Row(children: [
            Icon(Icons.info_outline_rounded, size: 16, color: AppColors.brandGreen),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Payment will be collected after submission from the Collect Payment section.',
                style: TextStyle(fontSize: 12, color: AppColors.brandGreen),
              ),
            ),
          ]),
        ),

        // Member cards
        ..._queuedMembers.asMap().entries.map((entry) {
          final i = entry.key;
          final m = entry.value;
          final name   = m['name'] as String? ?? '';
          final mobile = m['mobile'] as String? ?? '';
          final total  = (m['total'] as num?)?.toDouble() ?? 0.0;
          final tests  = m['tests'] as List? ?? [];
          final color  = _avatarColor(name);
          final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: color.withValues(alpha: 0.15),
                child: Text(initial,
                    style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(name,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary))),
                  Text('₹${total.toInt()}',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                ]),
                if (mobile.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(mobile,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
                const SizedBox(height: 6),
                Text('${tests.length} test${tests.length == 1 ? '' : 's'} selected',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ])),
              GestureDetector(
                onTap: () => setState(() => _queuedMembers.removeAt(i)),
                child: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                ),
              ),
            ]),
          );
        }),

        // "Add Another Member" — visible while under the 4-member cap
        if (_queuedMembers.length < 4) ...[
          const SizedBox(height: 4),
          GestureDetector(
            onTap: _addAnotherMember,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.brandGreenLight),
              ),
              child: const Row(children: [
                SizedBox(
                  width: 36, height: 36,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.all(Radius.circular(18)),
                    ),
                    child: Icon(Icons.person_add_rounded, size: 18, color: AppColors.brandGreen),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('Add Another Member',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500,
                        color: AppColors.brandGreen))),
                Icon(Icons.chevron_right_rounded, color: AppColors.brandGreen, size: 18),
              ]),
            ),
          ),
          const SizedBox(height: 8),
        ],

        // Total
        if (_queuedMembers.isNotEmpty) ...[
          const Divider(height: 24),
          Row(children: [
            const Text('Total to collect',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            const Spacer(),
            Text('₹${_queuedTotal.toInt()}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ]),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }
}