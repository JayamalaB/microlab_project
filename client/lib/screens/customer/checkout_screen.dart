import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/razorpay_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'my_bookings_screen.dart';
import 'booking_widgets.dart';
import 'package:microlab/models.dart';

// ─── Prescription doc model ───────────────────────────────────────────────────

class _CheckoutDoc {
  final Uint8List bytes;
  final String fileName;
  final DateTime uploadedAt;
  _CheckoutDoc({required this.bytes, required this.fileName, required this.uploadedAt});
}

// ─── Checkout Screen ──────────────────────────────────────────────────────────

class CheckoutScreen extends StatefulWidget {
  final MemberModel member;
  final List<TestModel> cart;
  final String mode;
  final String? address;
  final String? pincode;
  final String? city;
  final BranchModel? branch;
  final bool isVip;
  final int patientId;
  final double? patientLat;
  final double? patientLng;
  // Branch-booking pre-fills (null = old flow, picker shown as usual)
  final DateTime? preSelectedDate;
  final String?   preSelectedSlotLabel;
  final int?      branchId;
  final String?   collectionDate;
  final int?      timeSlotId;

  const CheckoutScreen({
    super.key,
    required this.member,
    required this.cart,
    required this.mode,
    this.address,
    this.pincode,
    this.city,
    this.branch,
    this.isVip = false,
    this.patientId = 1,
    this.patientLat,
    this.patientLng,
    this.preSelectedDate,
    this.preSelectedSlotLabel,
    this.branchId,
    this.collectionDate,
    this.timeSlotId,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  // ── Config ────────────────────────────────────────────────
  // Distance-based service charge estimated at booking time (backend calculates from pincode → lab km)
  // TODO: replace with GET /api/service-charge?pincode=&city=
  static const double _estimatedServiceCharge = 79.0;

  // ── Date ─────────────────────────────────────────────────
  DateTime? _selectedDate;

  // ── Slots ─────────────────────────────────────────────────
  // Hardcoded list used when no branchId is set (old flow).
  static const List<TimeSlot> _staticSlots = [
    TimeSlot(id: '1', label: '10:00 AM', time: '10:00'),
    TimeSlot(id: '2', label: '12:00 PM', time: '12:00'),
    TimeSlot(id: '3', label: '1:00 PM',  time: '13:00'),
    TimeSlot(id: '4', label: '4:00 PM',  time: '16:00'),
    TimeSlot(id: '5', label: '5:00 PM',  time: '17:00'),
  ];
  // API-loaded slots used when branchId is provided.
  List<TimeSlot>              _branchSlots    = [];
  List<Map<String, dynamic>>  _branchSlotsRaw = []; // includes timeIntervals
  bool                        _loadingSlots   = false;
  String                      _slotsError     = '';
  TimeInterval?               _selectedAppointmentTime;

  List<TimeSlot> get _availableSlots =>
      widget.branchId != null ? _branchSlots : _staticSlots;

  // Appointment times available for the currently selected slot (empty = no duration configured)
  List<TimeInterval> get _currentSlotIntervals {
    if (_selectedSlot == null) return [];
    final raw = _branchSlotsRaw.firstWhere(
      (s) => s['slotId']?.toString() == _selectedSlot!.id,
      orElse: () => <String, dynamic>{},
    );
    final list = raw['timeIntervals'] as List? ?? [];
    return list.map<TimeInterval>((t) => TimeInterval(
      time:  t['time']  as String? ?? '',
      label: t['label'] as String? ?? '',
    )).toList();
  }

  TimeSlot? _selectedSlot;

  // ── Prescription / Document — multi-image upload ─────────
  final List<_CheckoutDoc> _prescriptions = [];
  bool _isPicking = false;
  bool _docVerified = false; // set by technician via API; mock as false
  static const int _maxPrescrips = 5;
  final ImagePicker _picker = ImagePicker();

  // ── Payment ───────────────────────────────────────────────
  // 'full' = pay tests + service charge now via Razorpay
  // 'pay_later' = ₹0 now, everything collected at home by technician
  String _paymentType = 'full';
  bool _isProcessing = false;

  // ── VIP: selected technician ─────────────────────────────
  TechnicianModel? _selectedTechnician;

  // ── VIP: mock available technicians (replace with GET /api/technicians?date=&slot=) ──
  final List<TechnicianModel> _availableTechnicians = const [
    TechnicianModel(id: 't1', name: 'Dr. Arjun Sharma', mobile: '9876500001', rating: 4.9, totalReviews: 142, experience: '6 years', specializations: ['Phlebotomy', 'Diabetes', 'General'], available: true),
    TechnicianModel(id: 't2', name: 'Priya Nair', mobile: '9876500002', rating: 4.7, totalReviews: 98, experience: '4 years', specializations: ['General', 'Thyroid', 'Paediatric'], available: true),
    TechnicianModel(id: 't3', name: 'Karthik Rajan', mobile: '9876500003', rating: 4.8, totalReviews: 115, experience: '5 years', specializations: ['Heart', 'Kidney', 'General'], available: true),
    TechnicianModel(id: 't4', name: 'Meena Devi', mobile: '9876500004', rating: 4.6, totalReviews: 76, experience: '3 years', specializations: ['Vitamins', 'Wellness', 'General'], available: false),
  ];

  // ── Computed ──────────────────────────────────────────────
  double get _testsTotal => widget.cart.fold(0, (s, t) => s + t.finalPrice);
  double get _serviceCharge => widget.mode == 'Lab Test' ? 0 : _estimatedServiceCharge;
  double get _grandTotal => _testsTotal + _serviceCharge;

  bool get _anyDocRequired => widget.cart.any((t) => t.docRequired);

  // Pay Full locked when a doc is required but not yet verified by technician
  bool get _fullPaymentEnabled => !_anyDocRequired || _docVerified;

  double get _payableNow => _paymentType == 'full' ? _grandTotal : 0;
  double get _payableLater => _paymentType == 'full' ? 0 : _grandTotal;

  bool get _canProceed {
    if (_selectedDate == null || _selectedSlot == null) return false;
    // If this slot has specific appointment times, one must be selected
    if (_currentSlotIntervals.isNotEmpty && _selectedAppointmentTime == null) return false;
    if (widget.isVip && _selectedTechnician == null) return false;
    return true;
  }

  // ── Date picker (future only) ─────────────────────────────
  @override
  void initState() {
    super.initState();
    if (_anyDocRequired) _paymentType = 'pay_later';

    debugPrint('\n🧾 [CHECKOUT INIT] ──────────────────────────────────');
    debugPrint('   mode        : ${widget.mode}');
    debugPrint('   patientId   : ${widget.patientId}');
    debugPrint('   branchId    : ${widget.branchId ?? '⚠️ null — static slots will be used'}');
    debugPrint('   branch name : ${widget.branch?.name ?? '—'}');
    debugPrint('   cart items  : ${widget.cart.length}');
    debugPrint('   slot mode   : ${widget.branchId != null ? 'API (branch slots)' : 'STATIC (hardcoded)'}');
    debugPrint('   date range  : ${widget.branchId != null ? 'today onward' : 'tomorrow onward'}');

    if (widget.preSelectedDate != null) {
      _selectedDate = widget.preSelectedDate;
      debugPrint('   pre-date    : $_selectedDate');
    }
    if (widget.preSelectedSlotLabel != null) {
      final id = widget.timeSlotId?.toString() ?? '0';
      _selectedSlot = TimeSlot(id: id, label: widget.preSelectedSlotLabel!, time: '');
      debugPrint('   pre-slot    : ${widget.preSelectedSlotLabel}');
    }
    debugPrint('────────────────────────────────────────────────────\n');
  }

  @override
  void dispose() {
    clearRazorpay();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now      = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));
    // Branch flow allows same-day booking; old flow starts from tomorrow
    final firstDate = widget.branchId != null ? now : tomorrow;
    debugPrint('\n📅 [DATE PICKER] branchId=${widget.branchId} → firstDate=${firstDate.toIso8601String().substring(0,10)} (${widget.branchId != null ? 'today allowed' : 'tomorrow earliest'})');
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? firstDate,
      firstDate: firstDate,
      lastDate: now.add(const Duration(days: 30)),
      helpText: 'SELECT APPOINTMENT DATE',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppColors.brandGreen,
            onPrimary: Colors.white,
            surface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      debugPrint('   picked      : ${picked.toIso8601String().substring(0,10)}');
      setState(() {
        _selectedDate            = picked;
        _selectedSlot            = null;
        _selectedAppointmentTime = null;
        _selectedTechnician      = null;
        _branchSlots             = [];
        _branchSlotsRaw          = [];
        _slotsError              = '';
      });
      if (widget.branchId != null) {
        debugPrint('   → branchId=${widget.branchId} — loading API slots');
        _loadBranchSlots(picked);
      } else {
        debugPrint('   → no branchId — static slots shown (${_staticSlots.length} options)');
      }
    } else {
      debugPrint('   picker dismissed — no date selected');
    }
  }

  String _toApiDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _loadBranchSlots(DateTime date) async {
    final dateStr = _toApiDate(date);
    debugPrint('\n🕐 [LOAD SLOTS] ─────────────────────────────────────');
    debugPrint('   branchId    : ${widget.branchId}');
    debugPrint('   date        : $dateStr');

    setState(() { _loadingSlots = true; _slotsError = ''; });

    try {
      final uri = Uri.parse('${AppConstants.serverUrl}/api/slots')
          .replace(queryParameters: {
            'branch_id': widget.branchId.toString(),
            'date':      dateStr,
            'slot_type': widget.mode == 'Home Collection' ? 'home_collection' : 'lab_visit',
          });
      debugPrint('   → GET $uri');

      final res  = await http.get(uri).timeout(const Duration(seconds: 10));
      debugPrint('   ← status    : ${res.statusCode}');
      debugPrint('   ← body      : ${res.body}');

      if (!mounted) return;

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['success'] == true) {
          final rawList = (body['slots'] as List).cast<Map<String, dynamic>>();
          final list = rawList.map((m) => TimeSlot(
            id:          m['time_slot_id']?.toString() ?? '',
            label:       m['label']       as String? ?? '',
            time:        m['time']        as String? ?? '',
            parentSlotId: m['slot_id'] != null ? (m['slot_id'] as num).toInt() : null,
          )).toList();
          debugPrint('   ✅ slots     : ${list.length} available');
          for (final s in list) { debugPrint('      • [${s.id}] ${s.label} (${s.time})'); }
          setState(() {
            _branchSlotsRaw = rawList;
            _branchSlots    = list;
            _loadingSlots   = false;
            _slotsError     = list.isEmpty ? 'No slots available for this date. Try another date.' : '';
          });
        } else {
          debugPrint('   ⚠️  API returned success=false: ${body['message']}');
          setState(() { _loadingSlots = false; _slotsError = body['message'] as String? ?? 'Could not load slots.'; });
        }
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        debugPrint('   ❌ HTTP ${res.statusCode}: ${body['message']}');
        setState(() { _loadingSlots = false; _slotsError = body['message'] as String? ?? 'Could not load slots.'; });
      }
    } catch (e) {
      debugPrint('   ❌ exception : $e');
      if (!mounted) return;
      setState(() { _loadingSlots = false; _slotsError = 'Could not reach server. Check your connection.'; });
    }
    debugPrint('────────────────────────────────────────────────────\n');
  }

  // ── Slot section body ─────────────────────────────────────
  Widget _buildSlotBody() {
    if (_selectedDate == null) {
      return const Text(
        'Please select a date first',
        style: TextStyle(fontSize: 12, color: AppColors.textHint, fontStyle: FontStyle.italic),
      );
    }
    if (_loadingSlots) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen),
        ),
      );
    }
    if (_slotsError.isNotEmpty) {
      return Text(
        _slotsError,
        style: const TextStyle(fontSize: 12, color: AppColors.textHint, fontStyle: FontStyle.italic),
      );
    }
    if (_availableSlots.isEmpty) {
      return const Text(
        'No slots available. Try another date.',
        style: TextStyle(fontSize: 12, color: AppColors.textHint, fontStyle: FontStyle.italic),
      );
    }
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _availableSlots.map((slot) {
        final isSelected = _selectedSlot?.id == slot.id;
        return GestureDetector(
          onTap: () => setState(() {
            _selectedSlot            = slot;
            _selectedAppointmentTime = null; // reset when slot changes
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? AppColors.brandGreen : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? AppColors.brandGreen : AppColors.divider,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Text(slot.label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isSelected ? Colors.white : AppColors.textPrimary)),
          ),
        );
      }).toList(),
    );
  }

  // ── Prescription upload — multi-image ────────────────────
  void _showPresSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, MediaQuery.of(context).padding.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
                color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
          ),
          _PresSourceTile(Icons.camera_alt_outlined, 'Camera', 'Take a photo now',
              () { Navigator.pop(context); _pickPres(ImageSource.camera); }),
          const SizedBox(height: 8),
          _PresSourceTile(Icons.photo_library_outlined, 'Gallery', 'Choose from your photos',
              () { Navigator.pop(context); _pickPres(ImageSource.gallery); }),
          const SizedBox(height: 4),
        ]),
      ),
    );
  }

  Future<void> _pickPres(ImageSource source) async {
    if (_isPicking || _prescriptions.length >= _maxPrescrips) return;
    setState(() => _isPicking = true);
    try {
      if (source == ImageSource.gallery) {
        final images = await _picker.pickMultiImage(imageQuality: 80);
        if (images.isNotEmpty) {
          final toAdd = images.take(_maxPrescrips - _prescriptions.length);
          final docs = await Future.wait(toAdd.map((f) async => _CheckoutDoc(
              bytes: await f.readAsBytes(),
              fileName: f.name,
              uploadedAt: DateTime.now())));
          setState(() => _prescriptions.addAll(docs));
        }
      } else {
        final img = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
        if (img != null) {
          final bytes = await img.readAsBytes();
          setState(() => _prescriptions.add(_CheckoutDoc(
              bytes: bytes, fileName: img.name, uploadedAt: DateTime.now())));
        }
      }
    } catch (_) {}
    setState(() => _isPicking = false);
  }

  void _viewPres(int index) {
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _PresViewerPage(images: _prescriptions, initialIndex: index)));
  }

  void _deletePres(int index) {
    setState(() => _prescriptions.removeAt(index));
  }

  // ── Open Razorpay checkout (or confirm directly for Pay Later) ──────────
  void _proceedToPayment() {
    if (!_canProceed) return;

    if (_paymentType == 'pay_later') {
      _confirmBooking('pay_later');
      return;
    }

    setState(() => _isProcessing = true);

    // TODO: fetch order_id from your backend first
    // POST /api/payment/create-order { amount: _payableNow, currency: 'INR' }
    // then use response['order_id'] below

    final options = {
      'key': 'rzp_test_SonqjjPurqlLci', // replace with your Razorpay key
      'amount': (_payableNow * 100).toInt(), // paise
      'name': 'MicroLab',
      'description': widget.cart.map((t) => t.name).join(', '),
      'prefill': {
        'contact': widget.member.mobile,
        'email': widget.member.email ?? '',
        'name': widget.member.name,
      },
      'notes': {
        'booking_mode': widget.mode,
        'customer_name': widget.member.name,
        'tests': widget.cart.map((t) => t.name).join(', '),
      },
      'theme': {
        'color': '#0A5C4A',
      },
      'retry': {
        'enabled': true,
        'max_count': 2,
      },
    };

    openRazorpay(
      options: options,
      onSuccess: (paymentId) => _confirmBooking(paymentId),
      onError: (message) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            message == 'Payment cancelled'
                ? 'Payment cancelled'
                : 'Payment failed: $message'),
          backgroundColor: message == 'Payment cancelled'
              ? AppColors.textSecondary
              : Colors.red[700],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      },
    );
  }

  // ── Confirm booking after Razorpay success ───────────
  Future<void> _confirmBooking(String razorpayPaymentId) async {
    setState(() => _isProcessing = true);

    final address = [widget.address, widget.city, widget.pincode]
        .where((s) => s != null && s.isNotEmpty)
        .join(', ');

    // Build items list from cart
    final items = widget.cart.map((t) => {
      'packageId':   int.tryParse(t.id) ?? 0,
      'packageType': t.type == 'package' ? 'package' : 'test',
      'finalPrice':  t.finalPrice,
    }).toList();

    final isPayNow = razorpayPaymentId != 'pay_later' && razorpayPaymentId.isNotEmpty;

    final payload = <String, dynamic>{
      'patientId':      widget.patientId,
      'bookingType':    widget.mode == 'Home Collection' ? 'home_collection' : 'lab_visit',
      'totalAmount':    _grandTotal,
      'discountAmount': 0,
      'sourceChannel':  'mobile_app',
      'notes':          null,
      'items':          items,
      'paymentType':    isPayNow ? 'full' : 'pay_later',
      if (isPayNow) 'razorpayPaymentId': razorpayPaymentId,
      if (widget.branchId   != null) 'branchId': widget.branchId,
      if (_selectedDate     != null) 'collectionDate':
          '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}',
      if (widget.patientLat != null) 'collectionLatitude':  widget.patientLat,
      if (widget.patientLng     != null) 'collectionLongitude': widget.patientLng,
      if (_selectedSlot != null && int.tryParse(_selectedSlot!.id) != null)
        'availableSlotId': int.parse(_selectedSlot!.id),
    };

    debugPrint('\n📤 [CHECKOUT] POST /api/bookings');
    debugPrint('   patientId   : ${widget.patientId}');
    debugPrint('   bookingType : ${payload['bookingType']}');
    debugPrint('   totalAmount : ₹$_grandTotal');
    debugPrint('   items       : ${items.length} — ${items.map((i) => 'pkg${i['packageId']}(₹${i['finalPrice']})').join(', ')}');
    debugPrint('   razorpay_id : $razorpayPaymentId');

    int bookingId;
    String bookingRef;
    int? docBookingItemId; // booking_item_id of first doc-required item

    try {
      final url   = Uri.parse('${AppConstants.serverUrl}/api/bookings');
      final token = await ApiService.getToken();
      final res = await http.post(
        url,
        headers: {
          'Content-Type':  'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 10));

      debugPrint('📥 [CHECKOUT] Response ${res.statusCode}: ${res.body}');

      if (res.statusCode != 201) {
        throw Exception('Server returned ${res.statusCode}');
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      bookingId  = data['bookingId']  as int;
      bookingRef = data['bookingRef'] as String;

      final bookingItems = (data['bookingItems'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      final docItem = bookingItems.firstWhere(
        (i) => i['docRequired'] == true,
        orElse: () => bookingItems.isNotEmpty ? bookingItems.first : <String, dynamic>{},
      );
      docBookingItemId = docItem['bookingItemId'] as int?;

      debugPrint('✅ [CHECKOUT] Booking created — bookingId=$bookingId ref=$bookingRef bookingItemId=$docBookingItemId');
    } catch (e) {
      debugPrint('❌ [CHECKOUT] API call failed: $e');
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Booking failed: $e'),
        backgroundColor: Colors.red[700],
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    // Upload prescriptions and insert into ip_booking_documents
    if (_prescriptions.isNotEmpty) {
      try {
        final urls = <String>[];
        for (final doc in _prescriptions) {
          final url = await ApiService.uploadFile(doc.bytes, doc.fileName);
          if (url != null) urls.add(url);
        }
        if (urls.isNotEmpty) {
          await ApiService.savePrescription(
            bookingId:     bookingId,
            patientId:     widget.patientId,
            bookingItemId: docBookingItemId,
            imageUrls:     urls,
          );
          debugPrint('📎 [CHECKOUT] ${urls.length} prescription(s) saved for booking $bookingId');
        }
      } catch (e) {
        debugPrint('⚠️ [CHECKOUT] Prescription upload failed (non-fatal): $e');
      }
    }

    final booking = BookingModel(
      id: bookingRef,
      member: widget.member,
      tests: widget.cart,
      mode: widget.mode,
      address: widget.address,
      pincode: widget.pincode,
      city: widget.city,
      branch: widget.branch,
      date: _selectedDate!,
      timeSlot: _selectedSlot?.label ?? '',
      paymentType: _paymentType,
      serviceCharge: _serviceCharge,
      testsTotal: _testsTotal,
      grandTotal: _grandTotal,
      paidAmount: _payableNow,
      status: 'Confirmed',
      createdAt: DateTime.now(),
      docRequired: _anyDocRequired,
      docVerified: _docVerified,
      isVip: widget.isVip,
      selectedTechnician: _selectedTechnician,
    );

    if (mounted) {
      setState(() => _isProcessing = false);

      if (widget.mode == 'Home Collection') {
        // Fire technician dispatch in background — patient sees confirmation immediately.
        final socket = SocketService.instance;
        socket.registerPatientSocket(patientId: widget.patientId, bookingId: bookingId);
        socket.emitBookingRequest(
          bookingId:       bookingId,
          patientId:       widget.patientId,
          patientName:     widget.member.name,
          patientMobile:   widget.member.mobile,
          patientAddress:  address.isEmpty ? 'Home Collection' : address,
          patientLat:      widget.patientLat,
          patientLng:      widget.patientLng,
          hospital:        'MicroLab Home Collection',
          bookingType:     'lab',
          branchId:        widget.branchId,
          branchName:      widget.branch?.name,
          slotId:          _selectedSlot?.parentSlotId ?? int.tryParse(_selectedSlot?.id ?? ''),
          slotLabel:       _selectedSlot?.label,
          appointmentTime: _selectedAppointmentTime?.time,
        );
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => _BookingSuccessScreen(booking: booking)),
      );
    }
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
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
        title: const Text('Checkout',
            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [

          // ── Order Summary ─────────────────────────────────
          _SectionCard(
            title: 'Order Summary',
            icon: Icons.receipt_long_outlined,
            child: Column(
              children: [
                ...widget.cart.map((t) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                          color: t.type == 'package'
                              ? AppColors.brandGreen
                              : const Color(0xFF1565C0),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name,
                                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary)),
                            if (t.docRequired)
                              const Text('Prescription required',
                                  style: TextStyle(fontSize: 11, color: Color(0xFFE65100))),
                          ],
                        ),
                      ),
                      Text('₹${t.finalPrice.toInt()}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                    ],
                  ),
                )),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ── Collection Info ───────────────────────────────
          _SectionCard(
            title: widget.mode,
            icon: widget.mode == 'Home Collection' ? Icons.home_outlined : Icons.local_hospital_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.mode == 'Home Collection') ...[
                  if (widget.address != null && widget.address!.isNotEmpty)
                    _InfoLine(Icons.home_outlined, widget.address!),
                  Row(children: [
                    if (widget.pincode != null)
                      Expanded(child: _InfoLine(Icons.pin_outlined, widget.pincode!)),
                    if (widget.pincode != null && widget.city != null)
                      const SizedBox(width: 12),
                    if (widget.city != null)
                      Expanded(child: _InfoLine(Icons.location_city_outlined, widget.city!)),
                  ]),
                ],
                if (widget.mode == 'Lab Test' && widget.branch != null) ...[
                  if (widget.branch != null) _InfoLine(Icons.local_hospital_outlined, widget.branch!.name),
                  if (widget.branch != null) _InfoLine(Icons.location_on_outlined, widget.branch!.address),
                ],
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ── Date Selection ────────────────────────────────
          _SectionCard(
            title: 'Appointment Date',
            icon: Icons.calendar_today_outlined,
            required: true,
            child: GestureDetector(
              onTap: _pickDate,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  color: _selectedDate != null ? AppColors.brandGreenSurface : AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _selectedDate != null ? AppColors.brandGreen : AppColors.divider,
                    width: _selectedDate != null ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.event_outlined,
                        size: 20,
                        color: _selectedDate != null ? AppColors.brandGreen : AppColors.textHint),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _selectedDate != null ? _formatDate(_selectedDate!) : 'Select appointment date',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: _selectedDate != null ? FontWeight.w500 : FontWeight.w400,
                            color: _selectedDate != null ? AppColors.textPrimary : AppColors.textHint),
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down_rounded,
                        color: _selectedDate != null ? AppColors.brandGreen : AppColors.textHint),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 14),

          // ── Time Slot ─────────────────────────────────────
          _SectionCard(
            title: 'Time Slot',
            icon: Icons.schedule_outlined,
            required: true,
            child: _buildSlotBody(),
          ),

          // ── Appointment Time (shown when slot has intervals) ─
          if (_selectedSlot != null && _currentSlotIntervals.isNotEmpty) ...[
            const SizedBox(height: 14),
            _SectionCard(
              title: 'Appointment Time',
              icon: Icons.access_time_outlined,
              required: true,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _currentSlotIntervals.map((interval) {
                  final isSel = _selectedAppointmentTime?.time == interval.time;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedAppointmentTime = interval),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSel ? AppColors.brandGreen : Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSel ? AppColors.brandGreen : AppColors.divider,
                          width: isSel ? 1.5 : 1,
                        ),
                      ),
                      child: Text(interval.label,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isSel ? Colors.white : AppColors.textPrimary)),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],

          const SizedBox(height: 14),

          // ── Prescription / Document (multi-image) ─────────
          // Required when any test needs it; also always shown for VIP
          if (_anyDocRequired || widget.isVip)
            _SectionCard(
              title: 'Prescription / Document',
              icon: Icons.description_outlined,
              required: _anyDocRequired,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Info banner
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _anyDocRequired
                          ? const Color(0xFFFFF3E0)
                          : AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _anyDocRequired
                            ? const Color(0xFFFFCC02).withValues(alpha: 0.4)
                            : AppColors.brandGreenLight,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _anyDocRequired
                              ? Icons.info_outline_rounded
                              : Icons.upload_file_outlined,
                          size: 14,
                          color: _anyDocRequired
                              ? const Color(0xFFE65100)
                              : AppColors.brandGreen,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _anyDocRequired
                                ? (widget.mode == 'Lab Test'
                                    ? 'One or more tests require a prescription. Upload up to $_maxPrescrips images. Payment will be collected at the branch after verification.'
                                    : 'One or more tests require a prescription. Upload up to $_maxPrescrips images. Full payment unlocks after technician verification.')
                                : 'Upload your prescription or any relevant documents (optional). Up to $_maxPrescrips images.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: _anyDocRequired
                                  ? const Color(0xFF795548)
                                  : AppColors.brandGreen,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Thumbnail grid
                  if (_prescriptions.isNotEmpty) ...[
                    SizedBox(
                      height: 112,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(top: 8, right: 8),
                        itemCount: _prescriptions.length +
                            (_prescriptions.length < _maxPrescrips ? 1 : 0),
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          if (i == _prescriptions.length) {
                            return _PresAddMoreTile(
                              onTap: _isPicking ? null : _showPresSourcePicker,
                            );
                          }
                          return _PresThumbnailCard(
                            doc: _prescriptions[i],
                            onView: () => _viewPres(i),
                            onDelete: () => _deletePres(i),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_prescriptions.length} of $_maxPrescrips image${_prescriptions.length == 1 ? '' : 's'} uploaded',
                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // Empty upload tile
                  if (_prescriptions.isEmpty)
                    GestureDetector(
                      onTap: _isPicking ? null : _showPresSourcePicker,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _anyDocRequired
                                ? AppColors.brandGreen
                                : AppColors.divider,
                            width: _anyDocRequired ? 1.5 : 1,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _isPicking
                                ? const SizedBox(
                                    width: 24, height: 24,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppColors.brandGreen))
                                : const Icon(Icons.upload_file_outlined,
                                    size: 28, color: AppColors.brandGreen),
                            const SizedBox(height: 8),
                            Text(
                              _isPicking ? 'Picking…' : 'Tap to upload prescription',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.brandGreen),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Up to $_maxPrescrips images · JPG or PNG',
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.textHint),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // Verification status
                  if (_prescriptions.isNotEmpty && !_docVerified) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.brandGreenLight),
                      ),
                      child: Row(children: [
                        const Icon(Icons.hourglass_top_rounded, size: 14, color: AppColors.brandGreen),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Prescription uploaded',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.brandGreen)),
                              Text(
                                  widget.mode == 'Lab Test'
                                      ? 'Bring original to the branch on appointment day'
                                      : 'Awaiting technician verification',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                      ]),
                    ),
                  ],
                  if (_docVerified) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.brandGreen),
                      ),
                      child: const Row(children: [
                        Icon(Icons.verified_outlined, size: 16, color: AppColors.brandGreen),
                        SizedBox(width: 8),
                        Expanded(child: Text('Document verified by technician',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.brandGreen))),
                      ]),
                    ),
                  ],
                ],
              ),
            ),

          if (_anyDocRequired) const SizedBox(height: 14),

          // ── Payment Options ───────────────────────────────
          _SectionCard(
            title: 'Payment Option',
            icon: Icons.payment_outlined,
            required: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Service charge info banner
                if (widget.mode != 'Lab Test')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.brandGreenLight),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.directions_car_outlined, size: 14, color: AppColors.brandGreen),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Service charge of ₹${_serviceCharge.toInt()} is estimated based on travel distance. Final amount is confirmed when the technician starts the journey.',
                            style: const TextStyle(fontSize: 12, color: AppColors.brandGreen, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Option 1: Pay Full Amount Now
                _PaymentOptionTile(
                  selected: _paymentType == 'full',
                  title: 'Pay Full Amount Now',
                  subtitle: _fullPaymentEnabled
                      ? 'Pay ₹${_grandTotal.toInt()}${widget.mode == 'Lab Test' ? '' : ' (tests + service charge)'} · Nothing due at collection'
                      : (widget.mode == 'Lab Test'
                          ? 'Prescription required — payment collected at branch after verification'
                          : 'Available after technician verifies your prescription'),
                  amount: '₹${_grandTotal.toInt()} now',
                  badge: _fullPaymentEnabled ? 'RECOMMENDED' : 'LOCKED',
                  badgeColor: _fullPaymentEnabled ? AppColors.brandGreen : AppColors.textHint,
                  enabled: _fullPaymentEnabled,
                  onTap: _fullPaymentEnabled ? () => setState(() => _paymentType = 'full') : null,
                ),
                const SizedBox(height: 10),

                // Option 2: Pay Later
                _PaymentOptionTile(
                  selected: _paymentType == 'pay_later',
                  title: 'Pay Later',
                  subtitle: widget.mode == 'Lab Test'
                      ? 'Pay ₹${_grandTotal.toInt()} at the branch · No payment needed now'
                      : 'Pay ₹${_grandTotal.toInt()} at the time of collection · No payment needed now',
                  amount: '₹0 now',
                  badge: 'FLEXIBLE',
                  badgeColor: AppColors.blue,
                  enabled: true,
                  onTap: () => setState(() => _paymentType = 'pay_later'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ── VIP: Technician Selection ─────────────────────
          if (widget.isVip) ...[
            _SectionCard(
              title: 'Choose Technician',
              icon: Icons.medical_services_outlined,
              required: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_selectedDate == null || _selectedSlot == null)
                    const Text(
                      'Please select a date and time slot first to see available technicians.',
                      style: TextStyle(fontSize: 12, color: AppColors.textHint, fontStyle: FontStyle.italic),
                    )
                  else ...[
                    Text(
                      'Available for ${_selectedSlot!.label} on ${_formatDate(_selectedDate!)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                    // TODO: replace with GET /api/technicians?date=_selectedDate&slot=_selectedSlot.time
                    ..._availableTechnicians
                        .where((t) => t.available)
                        .map((t) => _TechnicianTile(
                      technician: t,
                      selected: _selectedTechnician?.id == t.id,
                      onTap: t.available
                          ? () => setState(() => _selectedTechnician = t)
                          : null,
                    )),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          // ── Billing Summary ───────────────────────────────
          _SectionCard(
            title: 'Billing Summary',
            icon: Icons.calculate_outlined,
            child: Column(
              children: [
                _BillRow('Tests Total', '₹${_testsTotal.toInt()}'),
                if (_serviceCharge > 0)
                  _BillRow('Service Charge (est.)', '+ ₹${_serviceCharge.toInt()}', sub: true),
                const Divider(height: 20),
                _BillRow('Grand Total', '₹${_grandTotal.toInt()}', bold: true),
                const SizedBox(height: 8),
                _BillRow('Pay Now', '₹${_payableNow.toInt()}', bold: true, green: true),
                if (_paymentType == 'pay_later')
                  _BillRow('Due at Collection', '₹${_payableLater.toInt()}', sub: true),
              ],
            ),
          ),
        ],
      ),

      // ── Bottom Pay Button ─────────────────────────────────
      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_canProceed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _selectedDate == null
                      ? 'Please select a date'
                      : _selectedSlot == null
                          ? 'Please select a time slot'
                          : _currentSlotIntervals.isNotEmpty && _selectedAppointmentTime == null
                              ? 'Please select an appointment time'
                              : widget.isVip && _selectedTechnician == null
                                  ? 'Please choose your preferred technician'
                                  : '',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFD32F2F)),
                  textAlign: TextAlign.center,
                ),
              ),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _canProceed && !_isProcessing ? _proceedToPayment : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _paymentType == 'pay_later'
                      ? AppColors.brandGreen
                      : const Color(0xFF1565C0),
                  disabledBackgroundColor: (_paymentType == 'pay_later'
                      ? AppColors.brandGreen
                      : const Color(0xFF1565C0)).withValues(alpha: 0.35),
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: _isProcessing
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                    : Text(
                        _paymentType == 'pay_later'
                            ? 'Confirm Booking · Pay Later'
                            : 'Pay ₹${_payableNow.toInt()} via Razorpay',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



// ─── Technician Tile ──────────────────────────────────────────────────────────

class _TechnicianTile extends StatelessWidget {
  final TechnicianModel technician;
  final bool selected;
  final VoidCallback? onTap;

  const _TechnicianTile({
    required this.technician,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppColors.brandGreenSurface : AppColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.brandGreen : AppColors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.brandGreen
                    : AppColors.brandGreenSurface,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  technician.name.isNotEmpty
                      ? technician.name.split(' ').map((w) => w[0]).take(2).join()
                      : '?',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : AppColors.brandGreen),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(technician.name,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? AppColors.brandGreen
                              : AppColors.textPrimary)),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Icon(Icons.star_rounded,
                        size: 12, color: Color(0xFFFFB300)),
                    const SizedBox(width: 3),
                    Text('${technician.rating}  ·  ${technician.experience}',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ]),
                  const SizedBox(height: 3),
                  Text(technician.specializations.join(', '),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textHint),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),

            // Radio circle
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 20, height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.brandGreen : AppColors.divider,
                  width: selected ? 5 : 1.5,
                ),
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Payment Option Tile ──────────────────────────────────────────────────────

class _PaymentOptionTile extends StatelessWidget {
  final bool selected;
  final String title;
  final String subtitle;
  final String amount;
  final String badge;
  final Color badgeColor;
  final bool enabled;
  final VoidCallback? onTap;

  const _PaymentOptionTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.badge,
    required this.badgeColor,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: !enabled
              ? const Color(0xFFF5F5F5)
              : selected
                  ? badgeColor.withOpacity(0.05)
                  : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: !enabled
                ? AppColors.divider
                : selected
                    ? badgeColor
                    : AppColors.divider,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 20, height: 20,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: !enabled ? AppColors.divider : selected ? badgeColor : AppColors.divider,
                  width: selected ? 5 : 1.5,
                ),
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: !enabled
                                  ? AppColors.textHint
                                  : selected
                                      ? badgeColor
                                      : AppColors.textPrimary)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: badgeColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(badge,
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
                                color: badgeColor, letterSpacing: 0.5)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: TextStyle(fontSize: 12,
                          color: !enabled ? AppColors.textHint : AppColors.textSecondary,
                          height: 1.4)),
                  const SizedBox(height: 6),
                  Text(amount,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                          color: !enabled ? AppColors.textHint : badgeColor)),
                ],
              ),
            ),
            if (!enabled)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.textHint),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Booking Success (Lab Test / static) ─────────────────────────────────────

class _BookingSuccessScreen extends StatelessWidget {
  final BookingModel booking;
  const _BookingSuccessScreen({required this.booking});

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                children: [
                  // Success banner
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppColors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 72, height: 72,
                          decoration: const BoxDecoration(
                            color: AppColors.brandGreenSurface, shape: BoxShape.circle),
                          child: const Icon(Icons.check_circle_outline_rounded,
                              size: 40, color: AppColors.brandGreen),
                        ),
                        const SizedBox(height: 16),
                        const Text('Booking Confirmed!',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        const SizedBox(height: 6),
                        Text(booking.id,
                            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, letterSpacing: 0.5)),
                        const SizedBox(height: 16),
                        BookingStatusBadge(status: booking.status),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  _SectionCard(
                    title: 'Booking Details',
                    icon: Icons.info_outline_rounded,
                    child: Column(
                      children: [
                        _ConfirmRow(Icons.person_outline, 'Customer', booking.member.name),
                        _ConfirmRow(Icons.event_outlined, 'Date', _formatDate(booking.date)),
                        _ConfirmRow(Icons.schedule_outlined, 'Time Slot', booking.timeSlot),
                        _ConfirmRow(
                          booking.mode == 'Home Collection' ? Icons.home_outlined : Icons.local_hospital_outlined,
                          'Mode', booking.mode,
                        ),
                        if (booking.isVip && booking.selectedTechnician != null)
                          _ConfirmRow(Icons.medical_services_outlined,
                              'Technician', booking.selectedTechnician!.name),
                        if (booking.mode == 'Home Collection' && booking.city != null)
                          _ConfirmRow(Icons.location_on_outlined, 'Location',
                              '${booking.city}${booking.pincode != null ? ', ${booking.pincode}' : ''}'),
                        if (booking.mode == 'Lab Test' && booking.branch != null)
                          if (booking.branch != null) _ConfirmRow(Icons.local_hospital_outlined, 'Branch', booking.branch!.name),
                        if (booking.selectedTechnician != null)
                          _ConfirmRow(Icons.medical_services_outlined, 'Technician',
                              '${booking.selectedTechnician!.name}  ★ ${booking.selectedTechnician!.rating}'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  _SectionCard(
                    title: 'Tests Booked',
                    icon: Icons.science_outlined,
                    child: Column(
                      children: booking.tests.map((t) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            Container(width: 6, height: 6,
                              decoration: BoxDecoration(
                                color: t.type == 'package' ? AppColors.brandGreen : const Color(0xFF1565C0),
                                shape: BoxShape.circle)),
                            const SizedBox(width: 10),
                            Expanded(child: Text(t.name,
                                style: const TextStyle(fontSize: 13, color: AppColors.textPrimary))),
                            Text('₹${t.finalPrice.toInt()}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      )).toList(),
                    ),
                  ),

                  const SizedBox(height: 14),

                  _SectionCard(
                    title: 'Payment',
                    icon: Icons.payment_outlined,
                    child: Column(
                      children: [
                        _ConfirmRow(Icons.receipt_outlined, 'Tests Total', '₹${booking.testsTotal.toInt()}'),
                        if (booking.serviceCharge > 0)
                          _ConfirmRow(Icons.add_circle_outline, 'Service Charge', '+ ₹${booking.serviceCharge.toInt()}'),
                        _ConfirmRow(Icons.calculate_outlined, 'Grand Total', '₹${booking.grandTotal.toInt()}'),
                        const Divider(height: 16),
                        _ConfirmRow(Icons.check_circle_outline, 'Paid Now',
                            booking.paymentType == 'pay_later' ? '₹0' : '₹${booking.paidAmount.toInt()}',
                            valueColor: AppColors.brandGreen),
                        if (booking.paymentType == 'pay_later')
                          _ConfirmRow(Icons.schedule_outlined, 'Due at Collection',
                              '₹${booking.grandTotal.toInt()}${booking.mode == 'Lab Test' ? '' : ' (tests + service charge)'}',
                              valueColor: const Color(0xFFE65100)),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),

                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.brandGreenLight),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("What's next?",
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
                        const SizedBox(height: 10),
                        if (booking.mode == 'Lab Test') ...[
                          const _NextStep('1', 'Visit the branch at your selected date and time slot'),
                          const _NextStep('2', 'Carry any required prescriptions or documents'),
                          const _NextStep('3', 'Follow the pre-test instructions for your tests'),
                          const _NextStep('4', 'Reports will be shared within the promised time'),
                        ] else ...[
                          const _NextStep('1', 'A technician has been allocated to your booking'),
                          const _NextStep('2', 'You will receive a call 1 hour before the appointment'),
                          const _NextStep('3', 'Keep your samples ready as per test requirements'),
                          const _NextStep('4', 'Reports will be shared within the promised time'),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Container(
              padding: EdgeInsets.fromLTRB(16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
              color: Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.brandGreen,
                        side: const BorderSide(color: AppColors.brandGreen, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Back to Home', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.push(context, MaterialPageRoute(
                          builder: (_) => MyBookingsScreen(initialBooking: booking)));
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('My Bookings', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
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
}


// ─── Reusable widgets ─────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final bool required;
  const _SectionCard({required this.title, required this.icon, required this.child, this.required = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 16, color: AppColors.brandGreen),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              if (required)
                const Text(' *', style: TextStyle(color: Color(0xFFD32F2F), fontSize: 14)),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoLine(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppColors.textHint),
            const SizedBox(width: 6),
            Flexible(child: Text(text, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
          ],
        ),
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
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(
                fontSize: sub ? 12 : 13,
                color: sub ? AppColors.textSecondary : AppColors.textPrimary)),
            Text(value, style: TextStyle(
                fontSize: sub ? 12 : 14,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                color: green ? AppColors.brandGreen : AppColors.textPrimary)),
          ],
        ),
      );
}

class _ConfirmRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  const _ConfirmRow(this.icon, this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: AppColors.brandGreen),
            const SizedBox(width: 10),
            SizedBox(width: 110,
              child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
            Expanded(
              child: Text(value, style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w500,
                  color: valueColor ?? AppColors.textPrimary)),
            ),
          ],
        ),
      );
}

class _NextStep extends StatelessWidget {
  final String number;
  final String text;
  const _NextStep(this.number, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20, height: 20,
              decoration: const BoxDecoration(color: AppColors.brandGreen, shape: BoxShape.circle),
              child: Center(child: Text(number,
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700))),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text,
                style: const TextStyle(fontSize: 12, color: AppColors.brandGreen, height: 1.4))),
          ],
        ),
      );
}

// ─── Prescription upload widgets ──────────────────────────────────────────────

class _PresThumbnailCard extends StatelessWidget {
  final _CheckoutDoc doc;
  final VoidCallback onView;
  final VoidCallback onDelete;
  const _PresThumbnailCard({
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
            top: -6, right: -6,
            child: GestureDetector(
              onTap: onDelete,
              child: Container(
                width: 22, height: 22,
                decoration: const BoxDecoration(
                    color: Color(0xFFD32F2F), shape: BoxShape.circle),
                child: const Icon(Icons.close_rounded, size: 13, color: Colors.white),
              ),
            ),
          ),
          Positioned(
            bottom: 6, right: 6,
            child: Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.fullscreen_rounded, size: 14, color: Colors.white),
            ),
          ),
        ]),
      );
}

class _PresAddMoreTile extends StatelessWidget {
  final VoidCallback? onTap;
  const _PresAddMoreTile({this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 96, height: 96,
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

class _PresSourceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _PresSourceTile(this.icon, this.title, this.subtitle, this.onTap);

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
              width: 40, height: 40,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreenSurface, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: AppColors.brandGreen),
            ),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Text(subtitle,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ]),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textHint),
          ]),
        ),
      );
}

// ─── Full-screen prescription viewer ─────────────────────────────────────────

class _PresViewerPage extends StatefulWidget {
  final List<_CheckoutDoc> images;
  final int initialIndex;
  const _PresViewerPage({required this.images, required this.initialIndex});

  @override
  State<_PresViewerPage> createState() => _PresViewerPageState();
}

class _PresViewerPageState extends State<_PresViewerPage> {
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
