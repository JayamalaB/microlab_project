import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/razorpay_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/models/technician_booking.dart';
import 'technician_active_job_screen.dart';

// ─── Prescription doc model ──────────────────────────────────────────────────

class _TechPresDoc {
  final Uint8List bytes;
  final String fileName;
  final DateTime uploadedAt;
  _TechPresDoc({required this.bytes, required this.fileName, required this.uploadedAt});
}

// ─── Test catalogue ───────────────────────────────────────────────────────────

const List<Map<String, String>> _testCatalogue = [
  {'id': 't1',  'name': 'HbA1c',                    'category': 'Diabetes', 'price': '540'},
  {'id': 't2',  'name': 'Complete Blood Count (CBC)','category': 'General',  'price': '350'},
  {'id': 't3',  'name': 'Thyroid Profile',           'category': 'Thyroid',  'price': '765'},
  {'id': 't4',  'name': 'Lipid Profile',             'category': 'Heart',    'price': '500'},
  {'id': 't5',  'name': 'Fasting Glucose',           'category': 'Diabetes', 'price': '120'},
  {'id': 't6',  'name': 'Kidney Function Test',      'category': 'Kidney',   'price': '450'},
  {'id': 't7',  'name': 'Liver Function Test',       'category': 'Liver',    'price': '600'},
  {'id': 't8',  'name': 'Vitamin D3',                'category': 'Vitamins', 'price': '900'},
  {'id': 't9',  'name': 'Vitamin B12',               'category': 'Vitamins', 'price': '700'},
  {'id': 't10', 'name': 'Urine Routine',             'category': 'General',  'price': '150'},
  {'id': 't11', 'name': 'Diabetes Care Package',     'category': 'Package',  'price': '1440'},
  {'id': 't12', 'name': 'Full Body Checkup',         'category': 'Package',  'price': '2625'},
];

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
    status: 'Completed',
    label: 'Completed',
    description: 'Collection done — OTP verified',
    icon: Icons.task_alt_rounded,
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
  late List<Map<String, String>> _selectedTests;
  bool _showAddTest = false;
  String _searchQuery = '';

  // Document — multi-image upload
  final List<_TechPresDoc> _docUploads = [];
  bool _docIsPicking = false;
  bool _docVerified = false;
  static const int _docMaxFiles = 5;
  final ImagePicker _picker = ImagePicker();

  // Payment
  bool _isProcessingPayment = false;
  bool _paymentDone = false;

  // New customer form
  bool _showNewCustomerForm = false;
  final _ncNameCtrl    = TextEditingController();
  final _ncMobileCtrl  = TextEditingController();
  final _ncEmailCtrl   = TextEditingController();
  final _ncDobCtrl     = TextEditingController();
  final _ncRelCtrl     = TextEditingController();
  final _ncHealthCtrl  = TextEditingController();
  DateTime? _ncDob;
  int? _ncCalculatedAge;
  String? _ncGender;
  final List<String> _ncGenders = ['Male', 'Female', 'Other'];
  final List<String> _ncRelations = ['Self','Spouse','Father','Mother','Son','Daughter','Brother','Sister','Other'];
  late List<Map<String, String>> _additionalCustomerTests;
  bool _showAddCustTest = false;
  String _custTestSearch = '';

  // OTP
  final List<TextEditingController> _otpControllers =
      List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes =
      List.generate(4, (_) => FocusNode());
  bool _isVerifyingOtp = false;
  bool _otpError = false;

  // ── Computed ──────────────────────────────────────────────

  double get _testsTotal =>
      _selectedTests.fold(0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0));

  double get _serviceChargePaid => widget.booking.serviceChargePaid;

  double get _amountDue => _testsTotal;

  int get _currentStepIndex =>
      _journeySteps.indexWhere((s) => s.status == _currentStatus);

  bool get _isCompleted => _currentStatus == 'Completed';
  bool get _canAdvance => !_isCompleted;

  String? get _nextStatus {
    final idx = _currentStepIndex;
    if (idx < 0 || idx >= _journeySteps.length - 1) return null;
    return _journeySteps[idx + 1].status;
  }

  @override
  void initState() {
    super.initState();
    _currentStatus = widget.booking.status;
    _additionalCustomerTests = [];
    _selectedTests = widget.booking.testNames.map((name) {
      final match = _testCatalogue.firstWhere(
        (t) => t['name'] == name,
        orElse: () => {'id': name, 'name': name, 'category': 'General', 'price': '0'},
      );
      return Map<String, String>.from(match);
    }).toList();
  }

  void _saveNewCustomer() {
    final name    = _ncNameCtrl.text.trim();
    final mobile  = _ncMobileCtrl.text.trim();
    
    if (name.isEmpty || mobile.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill all required fields'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final tests   = List<Map<String, String>>.from(_additionalCustomerTests);

    final newBooking = TechnicianBooking(
      id: 'BK${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
      customerName: name,
      customerPhone: mobile,
      address: widget.booking.address,
      city: widget.booking.city,
      pincode: widget.booking.pincode,
      date: widget.booking.date,
      timeSlot: widget.booking.timeSlot,
      testNames: tests.map((t) => t['name'] ?? '').toList(),
      mode: widget.booking.mode,
      status: 'Confirmed',
      serviceChargePaid: 99.0,
      testsTotal: tests.fold(0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0)),
      assignedAt: DateTime.now(),
    );

    widget.onNewBooking?.call(newBooking);

    setState(() {
      _showNewCustomerForm = false;
      _ncNameCtrl.clear();
      _ncMobileCtrl.clear();
      _ncEmailCtrl.clear();
      _ncDobCtrl.clear();
      _ncRelCtrl.clear();
      _ncHealthCtrl.clear();
      _ncDob = null;
      _ncCalculatedAge = null;
      _ncGender = null;
      _additionalCustomerTests.clear();
      _showAddCustTest = false;
      _custTestSearch = '';
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$name added with ${tests.length} test(s) — visible in dashboard'),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  void dispose() {
    clearRazorpay();
    _ncNameCtrl.dispose();
    _ncMobileCtrl.dispose();
    _ncEmailCtrl.dispose();
    _ncDobCtrl.dispose();
    _ncRelCtrl.dispose();
    _ncHealthCtrl.dispose();
    for (final c in _otpControllers) c.dispose();
    for (final f in _otpFocusNodes) f.dispose();
    super.dispose();
  }

  // ── New customer DOB picker ───────────────────────────────

  Future<void> _pickNcDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _ncDob ?? DateTime(now.year - 30),
      firstDate: DateTime(now.year - 120),
      lastDate: now,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: AppColors.brandGreen),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      int age = now.year - picked.year;
      if (now.month < picked.month ||
          (now.month == picked.month && now.day < picked.day)) age--;
      setState(() {
        _ncDob = picked;
        _ncCalculatedAge = age;
        _ncDobCtrl.text =
            '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      });
    }
  }

  // ── Journey advance ───────────────────────────────────────

// ── Journey advance ───────────────────────────────────────

void _advanceStatus() {
  // If already completed, don't allow any further actions
  if (_currentStatus == 'Completed') {
    // Just pop the screen if it's completed
    Navigator.of(context).pop(true);
    return;
  }

  final next = _nextStatus;
  if (next == null) return;

  // Check if we're already in progress and trying to start again
  if (next == 'Journey Started' && _currentStatus == 'Journey Started') {
    // Resume the journey instead of starting a new one
    _resumeJourney();
    return;
  }

  // Completed: payment check → OTP dialog
  if (next == 'Completed') {
    if (!_paymentDone && _amountDue > 0) {
      _showCompleteSheet();
    } else {
      _showOtpDialog();
    }
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
        // If OTP was verified inside, propagate the completion signal up to
        // whoever opened this Manage Booking screen (e.g. the dashboard).
        if (wasCompleted == true && mounted) {
          // CRITICAL: Set status to Completed before popping
          setState(() => _currentStatus = 'Completed');
          // Pop with true to signal completion to parent
          Navigator.of(context).pop(true);
        } else if (wasCompleted == false && mounted) {
          // If not completed, make sure status is still Journey Started
          // This handles the case where user came back without completing
          setState(() => _currentStatus = 'Journey Started');
        }
      });
      break;

    case 'Destination Reached':
      setState(() => _currentStatus = 'Destination Reached');
      if (bookingId > 0) SocketService.instance.emitArrived(bookingId: bookingId);
      break;

    default:
      // Collection Started and any future intermediate steps — local state only
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
      // CRITICAL: Set status to Completed before popping
      setState(() => _currentStatus = 'Completed');
      // Signal completion to parent screen
      Navigator.of(context).pop(true);
    } else if (wasCompleted == false && mounted) {
      // If not completed, status stays as Journey Started
      // This handles the case where user came back without completing
      setState(() => _currentStatus = 'Journey Started');
    }
  });
}
 // ── OTP dialog ────────────────────────────────────────────

  void _showOtpDialog() {
    for (final c in _otpControllers) c.clear();
    setState(() => _otpError = false);

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
                  'An OTP has been sent to ${widget.booking.customerPhone.replaceRange(3, 7, '****')}. Ask the customer to share it.',
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
                  const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.error_outline, size: 13, color: Color(0xFFD32F2F)),
                    SizedBox(width: 4),
                    Text('Invalid OTP. Please try again.',
                        style: TextStyle(fontSize: 12, color: Color(0xFFD32F2F))),
                  ]),
                ],

                const SizedBox(height: 20),

                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
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
      _otpFocusNodes[0].requestFocus();
    });
  }

  Future<void> _verifyOtp(BuildContext ctx, StateSetter setDialogState) async {
    final otp = _otpControllers.map((c) => c.text).join();
    if (otp.length < 4) {
      setDialogState(() => _otpError = true);
      return;
    }

    setState(() => _isVerifyingOtp = true);
    setDialogState(() {});

    // Mock: any non-'0000' OTP succeeds
    await Future.delayed(const Duration(milliseconds: 1000));

    if (otp == '0000') {
      setState(() { _isVerifyingOtp = false; _otpError = true; });
      setDialogState(() {});
    } else {
      setState(() {
        _isVerifyingOtp = false;
        _currentStatus = 'Completed';
      });
      SocketService.instance.emitCollectionCompleted(
        bookingId: int.tryParse(widget.booking.id) ?? 0,
      );
      Navigator.pop(ctx);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('OTP verified — booking marked as Completed!'),
          backgroundColor: AppColors.brandGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        ));
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).pop(true); // signals completion to caller
        });
      }
    }
  }

  // ── Tests ─────────────────────────────────────────────────

  void _removeTest(String id) =>
      setState(() => _selectedTests.removeWhere((t) => t['id'] == id));

  void _addTest(Map<String, String> t) {
    if (_selectedTests.any((x) => x['id'] == t['id'])) return;
    setState(() {
      _selectedTests.add(Map<String, String>.from(t));
      _showAddTest = false;
      _searchQuery = '';
    });
  }

  List<Map<String, String>> get _filteredCatalogue {
    final already = _selectedTests.map((t) => t['id']).toSet();
    return _testCatalogue.where((t) {
      if (already.contains(t['id'])) return false;
      if (_searchQuery.isEmpty) return true;
      return (t['name']?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false) ||
          (t['category']?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);
    }).toList();
  }

  List<Map<String, String>> get _filteredCustCatalogue {
    final already = _additionalCustomerTests.map((t) => t['id']).toSet();
    return _testCatalogue.where((t) {
      if (already.contains(t['id'])) return false;
      if (_custTestSearch.isEmpty) return true;
      return (t['name']?.toLowerCase().contains(_custTestSearch.toLowerCase()) ?? false) ||
          (t['category']?.toLowerCase().contains(_custTestSearch.toLowerCase()) ?? false);
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
          final docs = await Future.wait(toAdd.map((f) async => _TechPresDoc(
              bytes: await f.readAsBytes(),
              fileName: f.name,
              uploadedAt: DateTime.now())));
          setState(() => _docUploads.addAll(docs));
        }
      } else {
        final image = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
        if (image != null) {
          final bytes = await image.readAsBytes();
          setState(() => _docUploads.add(_TechPresDoc(
              bytes: bytes, fileName: image.name, uploadedAt: DateTime.now())));
        }
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
    setState(() => _docIsPicking = false);
  }

  void _viewDocImage(int index) {
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _DocImageViewerPage(images: _docUploads, initialIndex: index)));
  }

  void _deleteDocImage(int index) {
    setState(() {
      _docUploads.removeAt(index);
      if (_docUploads.isEmpty) _docVerified = false;
    });
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
                subtitle: 'Collect ₹${_amountDue.toInt()} from customer (tests amount)',
                done: _paymentDone,
                locked: false,
                buttonLabel: _paymentDone ? 'Paid ✓' : 'Make Payment  ₹${_amountDue.toInt()}',
                buttonColor: _paymentDone ? AppColors.brandGreen : const Color(0xFF1565C0),
                onTap: _paymentDone
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _collectPayment(onDone: () {
                          setState(() => _paymentDone = true);
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
                done: _isCompleted,
                locked: !_paymentDone,
                buttonLabel: _isCompleted ? 'Verified ✓' : 'Verify OTP',
                buttonColor: AppColors.brandGreen,
                onTap: (!_paymentDone || _isCompleted)
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
        setState(() {
          _isProcessingPayment = false;
          _paymentDone = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Payment of ₹${_amountDue.toInt()} received · $paymentId'),
          backgroundColor: AppColors.brandGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
        onDone?.call();
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

  @override
  Widget build(BuildContext context) {
    final currentStep = _journeySteps.firstWhere(
      (s) => s.status == _currentStatus,
      orElse: () => _journeySteps.first,
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context, _isCompleted ? true : null),
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
  else if (_currentStatus != 'Completed')
    GestureDetector(
      onTap: _advanceStatus,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: step.color,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          _nextStatus == 'Completed'
              ? 'Complete ▸'
              : '${_journeySteps[i + 1].label} ▸',
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
            child: Column(
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
                    if (!_isCompleted) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => _removeTest(t['id'] ?? ''),
                        child: const Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                      ),
                    ],
                  ]),
                )),

                if (!_isCompleted && !_showAddTest)
                  GestureDetector(
                    onTap: () => setState(() => _showAddTest = true),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.brandGreenLight),
                      ),
                      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.add_circle_outline, size: 15, color: AppColors.brandGreen),
                        SizedBox(width: 6),
                        Text('Add Test / Package',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.brandGreen)),
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
                    onTap: () => _addTest(t),
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                        onDelete: () => _deleteDocImage(i),
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
                    onPressed: () => setState(() => _docVerified = true),
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
              child: Column(children: [
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
                      'Service charge ₹${_serviceChargePaid.toInt()} paid at booking. Collect tests amount: ₹${_amountDue.toInt()}',
                      style: const TextStyle(fontSize: 12, color: AppColors.brandGreen, height: 1.4),
                    )),
                  ]),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isProcessingPayment || _amountDue == 0 ? null : () => _collectPayment(onDone: null),
                    icon: _isProcessingPayment
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.payment_outlined, size: 18),
                    label: Text(
                      _amountDue == 0 
                          ? 'No Payment Required' 
                          : (_isProcessingPayment ? 'Processing…' : 'Collect ₹${_amountDue.toInt()} via Razorpay'),
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _amountDue == 0 ? AppColors.brandGreen : const Color(0xFF1565C0), 
                      foregroundColor: Colors.white,
                      elevation: 0, 
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ]),
            ),

          const SizedBox(height: 14),

          // ── Add New Customer ──────────────────────────────
          _SectionCard(
            title: 'Add New Customer',
            icon: Icons.person_add_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'If another person at this location also needs a blood test, add their details here.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 12),

                if (!_showNewCustomerForm)
                  GestureDetector(
                    onTap: () => setState(() => _showNewCustomerForm = true),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.brandGreenLight),
                      ),
                      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.add_rounded, size: 18, color: AppColors.brandGreen),
                        SizedBox(width: 6),
                        Text('Add New Customer',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
                      ]),
                    ),
                  ),

                if (_showNewCustomerForm) ...[
                  _FormField(
                    label: 'Full Name *',
                    controller: _ncNameCtrl,
                    hint: 'Enter customer name',
                    icon: Icons.person_outline,
                    keyboardType: TextInputType.name,
                  ),
                  const SizedBox(height: 10),

                  _FormField(
                    label: 'Mobile Number *',
                    controller: _ncMobileCtrl,
                    hint: '10-digit mobile number',
                    icon: Icons.phone_outlined,
                    keyboardType: TextInputType.phone,
                    maxLength: 10,
                  ),
                  const SizedBox(height: 10),

                  _FormField(
                    label: 'Email Address',
                    controller: _ncEmailCtrl,
                    hint: 'example@email.com',
                    icon: Icons.email_outlined,
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 10),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Date of Birth',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: _pickNcDate,
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
                            Expanded(
                              child: Text(
                                _ncDobCtrl.text.isEmpty ? 'DD/MM/YYYY' : _ncDobCtrl.text,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: _ncDobCtrl.text.isEmpty
                                        ? AppColors.textHint
                                        : AppColors.textPrimary),
                              ),
                            ),
                            if (_ncCalculatedAge != null)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.brandGreenSurface,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text('$_ncCalculatedAge yrs',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppColors.brandGreen,
                                        fontWeight: FontWeight.w600)),
                              ),
                            const SizedBox(width: 6),
                            const Icon(Icons.calendar_month_outlined,
                                size: 18, color: AppColors.textSecondary),
                          ]),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Gender',
                          style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8, runSpacing: 6,
                        children: ['Male', 'Female', 'Other'].map((g) => GestureDetector(
                          onTap: () => setState(() => _ncGender = g),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: _ncGender == g ? AppColors.brandGreen : Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _ncGender == g ? AppColors.brandGreen : AppColors.divider),
                            ),
                            child: Text(g,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: _ncGender == g ? Colors.white : AppColors.textSecondary)),
                          ),
                        )).toList(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  DropdownButtonFormField<String>(
                    value: _ncRelCtrl.text.isEmpty ? null : _ncRelCtrl.text,
                    isExpanded: true,
                    hint: const Text('Relation to patient',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: AppColors.textHint)),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.group_outlined, size: 18, color: AppColors.textHint),
                      filled: true, fillColor: AppColors.background,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.divider)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.divider)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    ),
                    items: _ncRelations.map((r) => DropdownMenuItem(value: r, child: Text(r, style: const TextStyle(fontSize: 13)))).toList(),
                    onChanged: (v) => setState(() => _ncRelCtrl.text = v ?? ''),
                  ),
                  const SizedBox(height: 12),

                  _FormField(
                    label: 'Health Condition / Notes',
                    controller: _ncHealthCtrl,
                    hint: 'e.g. Diabetes, Hypertension, Thyroid…',
                    icon: Icons.medical_information_outlined,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),

                  const Text('Tests for this customer',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  const SizedBox(height: 8),

                  if (_additionalCustomerTests.isEmpty)
                    const Text('No tests added yet.',
                        style: TextStyle(fontSize: 12, color: AppColors.textHint)),

                  ..._additionalCustomerTests.map((t) => Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Row(children: [
                      Expanded(child: Text(t['name'] ?? '',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
                      Text('₹${t['price'] ?? '0'}',
                          style: const TextStyle(fontSize: 12, color: AppColors.brandGreen, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setState(() => _additionalCustomerTests.removeWhere((x) => x['id'] == t['id'])),
                        child: const Icon(Icons.close_rounded, size: 16, color: AppColors.textHint),
                      ),
                    ]),
                  )),

                  const SizedBox(height: 6),
                  if (!_showAddCustTest)
                    GestureDetector(
                      onTap: () => setState(() => _showAddCustTest = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.brandGreenLight),
                        ),
                        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.add_circle_outline, size: 15, color: AppColors.brandGreen),
                          SizedBox(width: 6),
                          Text('Add Test', style: TextStyle(fontSize: 12, color: AppColors.brandGreen, fontWeight: FontWeight.w500)),
                        ]),
                      ),
                    ),

                  if (_showAddCustTest) ...[
                    const SizedBox(height: 8),
                    TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() => _custTestSearch = v),
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search test…',
                        hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textHint),
                        suffixIcon: GestureDetector(
                          onTap: () => setState(() { _showAddCustTest = false; _custTestSearch = ''; }),
                          child: const Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                        ),
                        filled: true, fillColor: AppColors.background,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.divider)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.divider)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 6),
                    ..._filteredCustCatalogue.take(5).map((t) => GestureDetector(
                      onTap: () => setState(() {
                        _additionalCustomerTests.add(Map<String, String>.from(t));
                        _showAddCustTest = false;
                        _custTestSearch = '';
                      }),
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

                  const SizedBox(height: 14),

                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() {
                          _showNewCustomerForm = false;
                          _ncNameCtrl.clear(); _ncMobileCtrl.clear();
                          _ncEmailCtrl.clear(); _ncDobCtrl.clear();
                          _ncRelCtrl.clear(); _ncHealthCtrl.clear();
                          _ncDob = null; _ncCalculatedAge = null;
                          _ncGender = null; _additionalCustomerTests.clear();
                          _showAddCustTest = false; _custTestSearch = '';
                        }),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                          side: const BorderSide(color: AppColors.divider),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: (_ncNameCtrl.text.trim().isNotEmpty &&
                                _ncMobileCtrl.text.trim().length == 10)
                            ? () => _saveNewCustomer()
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Save Customer',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ],
      ),

      bottomNavigationBar: _isCompleted
          ? null
          : Container(
              padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: const Text('Changes saved'),
                      backgroundColor: AppColors.brandGreen,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ));
                    Navigator.pop(context);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen, 
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text('Save Changes', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                ),
              ),
            ),
    );
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
  final int? maxLength;
  final int maxLines;

  const _FormField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType = TextInputType.text,
    this.maxLength,
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
            maxLength: maxLength,
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
              child: Image.memory(doc.bytes, fit: BoxFit.cover),
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
              itemBuilder: (_, i) => InteractiveViewer(
                maxScale: 5.0,
                child: Center(
                  child: Image.memory(widget.images[i].bytes, fit: BoxFit.contain),
                ),
              ),
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