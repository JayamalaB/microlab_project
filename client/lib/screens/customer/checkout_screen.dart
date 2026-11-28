import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/package_pager.dart';
import 'package:microlab/services/razorpay_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/utils/app_messages.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';
import 'my_bookings_screen.dart';
import 'booking_widgets.dart';
import 'package:microlab/models.dart';

// ─── Family member added during checkout ──────────────────────────────────────

class _FamilyMember {
  final PatientModel patient;
  final List<TestModel> tests;
  final List<Uint8List> prescriptionBytes;
  final TextEditingController doctorCtrl;
  String doctorType; // 'self' | 'doctor'
  List<_CheckoutDoc> prescriptions;
  _FamilyMember({required this.patient, required this.tests, this.prescriptionBytes = const [], String? doctorName})
      : doctorCtrl = TextEditingController(text: doctorName ?? ''),
        doctorType = 'self',
        prescriptions = [];
  double get testsTotal => tests.fold(0.0, (s, t) => s + t.finalPrice);
  bool get anyDocRequired => tests.any((t) => t.docRequired);
  bool get isDoctor => doctorType == 'doctor';
  void dispose() => doctorCtrl.dispose();
}

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
  final VoidCallback? onBookingComplete;
  final VoidCallback? onMemberAdded;

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
    this.onBookingComplete,
    this.onMemberAdded,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  // ── Config ────────────────────────────────────────────────
  // Distance-based service charge estimated at booking time (backend calculates from pincode → lab km)
  // TODO: replace with GET /api/service-charge?pincode=&city=

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
  bool                        _loadingSlots        = false;
  String                      _slotsError          = '';
  bool                        _fallbackDateChanged = false;
  TimeInterval?               _selectedAppointmentTime;

  // Flattened list of all pickable times across all loaded slots.
  List<Map<String, dynamic>> get _allAvailableTimes {
    if (widget.branchId != null) {
      final times = <Map<String, dynamic>>[];
      for (final raw in _branchSlotsRaw) {
        final slotId     = raw['time_slot_id']?.toString() ?? '';
        final parentSlot = raw['slot_id'] != null ? (raw['slot_id'] as num).toInt() : null;
        final slotLabel  = raw['label'] as String? ?? '';
        final intervals  = (raw['timeIntervals'] as List?)?.cast<Map<String, dynamic>>() ?? [];
        if (intervals.isEmpty) {
          times.add({'time': raw['time'] as String? ?? '', 'label': slotLabel,
              'slotId': slotId, 'parentSlotId': parentSlot, 'interval': null});
        } else {
          for (final t in intervals) {
            times.add({'time': t['time'] as String? ?? '', 'label': t['label'] as String? ?? '',
                'slotId': slotId, 'parentSlotId': parentSlot, 'interval': t});
          }
        }
      }
      return times;
    }
    return _staticSlots.map((s) => {
      'time': s.time, 'label': s.label,
      'slotId': s.id, 'parentSlotId': null, 'interval': null,
    }).toList();
  }

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

  // ── Notes ─────────────────────────────────────────────────
  final TextEditingController _notesController = TextEditingController();

  // ── Doctor name (primary patient) ─────────────────────────
  String _doctorType = 'self'; // 'self' | 'doctor'
  bool get _isDoctor => _doctorType == 'doctor';
  final TextEditingController _doctorNameController = TextEditingController();

  // ── Address (mutable — user can edit in checkout) ─────────
  late String? _address;
  late String? _pincode;
  late String? _city;
  late double? _lat;
  late double? _lng;

  // ── Payment ───────────────────────────────────────────────
  // 'full' = pay tests + service charge now via Razorpay
  // 'pay_later' = ₹0 now, everything collected at home by technician
  String _paymentType = 'full';
  bool _isProcessing = false;

  // ── Checkout step (0 = Schedule, 1 = Details, 2 = Payment) ───
  int _currentStep = 0;

  // ── Family members (Home Collection only) ─────────────────
  final List<_FamilyMember> _familyMembers = [];

  // ── VIP: selected technician ─────────────────────────────
  TechnicianModel? _selectedTechnician;

  // ── VIP: mock available technicians (replace with GET /api/technicians?date=&slot=) ──
  final List<TechnicianModel> _availableTechnicians = const [
    TechnicianModel(id: 't1', name: 'Dr. Arjun Sharma', mobile: '9876500001', rating: 4.9, totalReviews: 142, experience: '6 years', specializations: ['Phlebotomy', 'Diabetes', 'General'], available: true),
    TechnicianModel(id: 't2', name: 'Priya Nair', mobile: '9876500002', rating: 4.7, totalReviews: 98, experience: '4 years', specializations: ['General', 'Thyroid', 'Paediatric'], available: true),
    TechnicianModel(id: 't3', name: 'Karthik Rajan', mobile: '9876500003', rating: 4.8, totalReviews: 115, experience: '5 years', specializations: ['Heart', 'Kidney', 'General'], available: true),
    TechnicianModel(id: 't4', name: 'Meena Devi', mobile: '9876500004', rating: 4.6, totalReviews: 76, experience: '3 years', specializations: ['Vitamins', 'Wellness', 'General'], available: false),
  ];

  bool get _isHomeCollection => widget.mode != 'Lab Test';

  // ── Home Collection service charge ─────────────────────────────────────
  double? _fareAmount;
  bool    _fareLoading = false;
  String? _fareError;

  Future<void> _loadFare() async {
    if (!_isHomeCollection) return;
    final bId = widget.branchId;
    final lat = _lat;
    final lng = _lng;
    if (bId == null || lat == null || lng == null) return;
    setState(() { _fareLoading = true; _fareError = null; });
    try {
      final result = await ApiService.getHomeCollectionFareQuote(
        branchId: bId, lat: lat, lng: lng,
      );
      if (mounted) {
        setState(() {
          _fareAmount  = (result['fare']?['finalFare'] as num?)?.toDouble();
          _fareLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _fareLoading = false; _fareError = 'Service charge unavailable'; });
      }
    }
  }

  // ── Computed ──────────────────────────────────────────────
  double get _testsTotal => widget.cart.fold(0, (s, t) => s + t.finalPrice);
  double get _familyTotal => _familyMembers.fold(0.0, (s, m) => s + m.testsTotal);
  double get _serviceCharge => _fareAmount ?? 0;
  double get _grandTotal => _testsTotal + _familyTotal + _serviceCharge;

  bool get _primaryNeedsPrescription => widget.cart.any((t) => t.docRequired);

  bool get _anyDocRequired =>
      _primaryNeedsPrescription ||
      _familyMembers.any((m) => m.anyDocRequired);

  // Pay Full locked when a doc is required but not yet verified by technician
  bool get _fullPaymentEnabled => !_anyDocRequired || _docVerified;

  double get _payableNow => _paymentType == 'full' ? _grandTotal : 0;
  double get _payableLater => _paymentType == 'full' ? 0 : _grandTotal;

  bool get _step0Complete {
    if (_selectedDate == null || _selectedSlot == null) return false;
    if (_currentSlotIntervals.isNotEmpty && _selectedAppointmentTime == null) return false;
    if (widget.isVip && _selectedTechnician == null) return false;
    return true;
  }

  bool get _step1Complete => !(_primaryNeedsPrescription && _prescriptions.isEmpty);

  bool get _canProceed => _step0Complete && _step1Complete;

  // ── Date picker (future only) ─────────────────────────────
  @override
  void initState() {
    super.initState();
    _address = widget.address;
    _pincode = widget.pincode;
    _city    = widget.city;
    _lat     = widget.patientLat;
    _lng     = widget.patientLng;
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
    _loadFare();
  }

  @override
  void dispose() {
    _notesController.dispose();
    _doctorNameController.dispose();
    for (final m in _familyMembers) m.dispose();
    clearRazorpay();
    super.dispose();
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
          if (list.isEmpty) {
            final fbData = body['fallback'] as Map<String, dynamic>?;
            if (fbData != null) {
              final fbLabel   = fbData['label'] as String? ?? '';
              final fbTime    = fbData['time']  as String? ?? '';
              final fbDateStr = fbData['date']  as String?;
              final fbDate    = fbDateStr != null ? DateTime.tryParse(fbDateStr) : null;
              // Surface the fallback slot through _branchSlotsRaw so the new grid shows it.
              final fbRaw = {'time_slot_id': '', 'slot_id': null, 'label': fbLabel,
                  'time': fbTime, 'timeIntervals': [], '_isFallback': true};
              setState(() {
                _branchSlotsRaw = [fbRaw];
                _branchSlots    = [];
                _loadingSlots   = false;
                _slotsError     = '';
                if (fbDate != null && fbDate != _selectedDate) {
                _fallbackDateChanged = true;
                _selectedDate        = fbDate;
              }
              });
            } else {
              setState(() { _branchSlotsRaw = []; _branchSlots = []; _loadingSlots = false; _slotsError = 'No upcoming slots available. Please contact us.'; });
            }
          } else {
            setState(() {
              _branchSlotsRaw = rawList;
              _branchSlots    = list;
              _loadingSlots   = false;
              _slotsError     = '';
            });
          }
        } else {
          debugPrint('   ⚠️  API returned success=false: ${body['message']}');
          setState(() { _loadingSlots = false; _slotsError = AppMessages.serverMessage(body['message'], fallback: _slotsLoadFailed); });
        }
      } else {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        debugPrint('   ❌ HTTP ${res.statusCode}: ${body['message']}');
        setState(() { _loadingSlots = false; _slotsError = AppMessages.serverMessage(body['message'], fallback: _slotsLoadFailed); });
      }
    } catch (e) {
      debugPrint('   ❌ exception : $e');
      if (!mounted) return;
      setState(() { _loadingSlots = false; _slotsError = AppMessages.friendlyError(e); });
    }
    debugPrint('────────────────────────────────────────────────────\n');
  }

  static const String _slotsLoadFailed = 'We couldn\'t load the available slots. Please try again.';

  void _selectTime(Map<String, dynamic> t) {
    final slotId     = t['slotId'] as String? ?? '';
    final parentSlot = t['parentSlotId'] as int?;
    final label      = t['label'] as String? ?? '';
    final time       = t['time'] as String? ?? '';
    final interval   = t['interval'] as Map<String, dynamic>?;
    setState(() {
      _selectedSlot = TimeSlot(id: slotId, label: label, time: time, parentSlotId: parentSlot);
      _selectedAppointmentTime = interval != null
          ? TimeInterval(time: interval['time'] as String? ?? '', label: interval['label'] as String? ?? '')
          : null;
      _selectedTechnician = null;
    });
  }

  // ── Date strip (3 days) ───────────────────────────────────
  Widget _buildDateStrip() {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    const dayAbbr   = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const monthAbbr = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                       'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final days = List.generate(3, (i) => today.add(Duration(days: i)));

    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final d     = days[i];
          final isSel = _selectedDate != null &&
              _selectedDate!.year == d.year &&
              _selectedDate!.month == d.month &&
              _selectedDate!.day == d.day;
          final sub = i == 0 ? 'Today' : i == 1 ? 'Tomorrow' : '${monthAbbr[d.month]} ${d.day}';
          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedDate        = d;
                _selectedSlot        = null;
                _selectedAppointmentTime = null;
                _selectedTechnician  = null;
                _branchSlots         = [];
                _branchSlotsRaw      = [];
                _slotsError          = '';
                _fallbackDateChanged = false;
              });
              if (widget.branchId != null) _loadBranchSlots(d);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 90,
              decoration: BoxDecoration(
                color: isSel ? AppColors.brandGreen : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSel ? AppColors.brandGreen : CxColors.border,
                  width: isSel ? 0 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(dayAbbr[d.weekday - 1],
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                        color: isSel ? Colors.white70 : CxColors.textSecondary)),
                  const SizedBox(height: 2),
                  Text(sub,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: isSel ? Colors.white : CxColors.textPrimary)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Time grid ─────────────────────────────────────────────
  Widget _buildTimeGrid() {
    if (_selectedDate == null) {
      // A quiet hint, not a box.
      return const Row(children: [
        Icon(Icons.touch_app_outlined, size: 15, color: CxColors.textHint),
        SizedBox(width: 6),
        Text('Select a date to see available times', style: CxText.caption),
      ]);
    }
    if (_loadingSlots) return const CxLoading(label: 'Finding available slots…');
    if (_slotsError.isNotEmpty) return CxBanner(tone: CxTone.error, message: _slotsError);

    final times = _allAvailableTimes;
    if (times.isEmpty) {
      return const CxBanner(
        tone: CxTone.warning,
        icon: Icons.event_busy_outlined,
        message: 'No slots available. Try another date.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_fallbackDateChanged)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: CxBanner(
              tone: CxTone.warning,
              message: 'No slots on your selected date. Appointment date updated to the next available day.',
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final pillW = (constraints.maxWidth - 12) / 3; // 2 × 6px gaps
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: times.map((t) {
                final slotId     = t['slotId'] as String? ?? '';
                final timeStr    = t['time'] as String? ?? '';
                final labelStr   = t['label'] as String? ?? timeStr;
                final isFallback = t['_isFallback'] == true;
                final isSel      = _selectedSlot?.id == slotId &&
                    (_selectedAppointmentTime == null
                        ? t['interval'] == null
                        : _selectedAppointmentTime!.time == timeStr);
                return SizedBox(
                  width: pillW,
                  child: _ChoicePill(
                    label: labelStr,
                    selected: isSel,
                    activeColor: isFallback ? AppColors.amber : AppColors.brandGreen,
                    onTap: () => _selectTime(t),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }



  // ── Prescription upload — multi-image ────────────────────
  // Shared Camera / Gallery chooser (same labels as before). It only returns
  // the choice; picking still goes through _pickPres exactly as before.
  Future<void> _showPresSourcePicker() async {
    final source = await showCxImageSourcePicker(context, title: 'Upload prescription');
    if (source == null || !mounted) return;
    _pickPres(source == CxImageSource.camera ? ImageSource.camera : ImageSource.gallery);
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

  // ── Family member prescription pickers ───────────────────
  Future<void> _showFamilyPresSourcePicker(_FamilyMember m) async {
    final source = await showCxImageSourcePicker(context, title: 'Upload prescription');
    if (source == null || !mounted) return;
    _pickFamilyPres(m, source == CxImageSource.camera ? ImageSource.camera : ImageSource.gallery);
  }

  Future<void> _pickFamilyPres(_FamilyMember m, ImageSource source) async {
    if (_isPicking || m.prescriptions.length >= _maxPrescrips) return;
    setState(() => _isPicking = true);
    try {
      if (source == ImageSource.gallery) {
        final images = await _picker.pickMultiImage(imageQuality: 80);
        if (images.isNotEmpty) {
          final toAdd = images.take(_maxPrescrips - m.prescriptions.length);
          final docs = await Future.wait(toAdd.map((f) async => _CheckoutDoc(
              bytes: await f.readAsBytes(), fileName: f.name, uploadedAt: DateTime.now())));
          setState(() => m.prescriptions.addAll(docs));
        }
      } else {
        final img = await _picker.pickImage(source: ImageSource.camera, imageQuality: 80);
        if (img != null) {
          final bytes = await img.readAsBytes();
          setState(() => m.prescriptions.add(_CheckoutDoc(
              bytes: bytes, fileName: img.name, uploadedAt: DateTime.now())));
        }
      }
    } catch (_) {}
    setState(() => _isPicking = false);
  }

  void _viewFamilyPres(_FamilyMember m, int index) {
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _PresViewerPage(images: m.prescriptions, initialIndex: index)));
  }

  void _deleteFamilyPres(_FamilyMember m, int index) {
    setState(() => m.prescriptions.removeAt(index));
  }

  // ── Edit address (Home Collection) ───────────────────────
  Future<void> _editAddress() async {
    final addrCtrl    = TextEditingController(text: _address);
    final pincodeCtrl = TextEditingController(text: _pincode);
    final cityCtrl    = TextEditingController(text: _city);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // CxSheetFrame keeps the sheet above the keyboard and the safe area.
      builder: (ctx) => CustomerThemeScope(
        child: CxSheetFrame(
          title: 'Edit Address',
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Address', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            TextField(controller: addrCtrl, maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: _addrInputDecor('Street / locality')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Pincode', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                const SizedBox(height: 6),
                TextField(controller: pincodeCtrl, keyboardType: TextInputType.number,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _addrInputDecor('6-digit pincode').copyWith(counterText: '')),
              ])),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('City', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                const SizedBox(height: 6),
                TextField(controller: cityCtrl, textCapitalization: TextCapitalization.words,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z ]'))],
                    decoration: _addrInputDecor('City')),
              ])),
            ]),
            const SizedBox(height: 20),
            CxButton(
              onPressed: () {
                final a = addrCtrl.text.trim();
                final p = pincodeCtrl.text.trim();
                final c = cityCtrl.text.trim();
                setState(() {
                  _address = a.isEmpty ? null : a;
                  _pincode = p.isEmpty ? null : p;
                  _city    = c.isEmpty ? null : c;
                });
                Navigator.pop(ctx);
              },
              icon: Icons.check_rounded,
              label: 'Save Address',
            ),
          ]),
        ),
      ),
    );
    addrCtrl.dispose(); pincodeCtrl.dispose(); cityCtrl.dispose();
  }

  // Borders, focus colour and padding come from the customer theme.
  InputDecoration _addrInputDecor(String hint) => InputDecoration(
    hintText: hint,
  );

  // ── Family: open add-member sheet (it loads tests page by page itself) ──
  Future<void> _showAddMemberSheet() async {
    final excludedIds = {widget.patientId, ..._familyMembers.map((m) => m.patient.patientId)};
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddMemberSheet(
        primaryPatientId:  widget.patientId,
        excludedPatientIds: excludedIds,
        onAdd: (m) => setState(() => _familyMembers.add(m)),
        onMemberAdded: widget.onMemberAdded,
      ),
    );
  }

  // ── Family booking confirmation ────────────────────────────
  Future<void> _confirmFamilyBooking(String razorpayPaymentId) async {
    final isPayNow = razorpayPaymentId != 'pay_later' && razorpayPaymentId.isNotEmpty;
    final slotId   = _selectedSlot != null ? int.tryParse(_selectedSlot!.id) : null;
    final dateStr  = _selectedDate != null
        ? '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}'
        : null;

    final members = <Map<String, dynamic>>[
      {
        'patientId':    widget.patientId,
        'items':        widget.cart.map((t) => {
          'packageId':   int.tryParse(t.id) ?? 0,
          'packageType': t.type,
          'finalPrice':  t.finalPrice,
        }).toList(),
        'totalAmount':   _testsTotal + _serviceCharge,
        'serviceCharge': _serviceCharge,
        'doctorName': _isDoctor ? _doctorNameController.text.trim() : 'Self',
      },
      ..._familyMembers.map((m) => {
        'patientId':    m.patient.patientId,
        'items':        m.tests.map((t) => {
          'packageId':   int.tryParse(t.id) ?? 0,
          'packageType': t.type,
          'finalPrice':  t.finalPrice,
        }).toList(),
        'totalAmount':   m.testsTotal,
        'serviceCharge': 0,
        'doctorName': m.isDoctor ? m.doctorCtrl.text.trim() : 'Self',
      }),
    ];

    final result = await ApiService.createFamilyBooking(
      members:             members,
      availableSlotId:     slotId,
      collectionDate:      dateStr,
      bookingType:         widget.mode == 'Home Collection' ? 'home_collection' : 'lab_visit',
      collectionAddress:   _address,
      collectionPincode:   _pincode,
      collectionCity:      _city,
      collectionLatitude:  _lat,
      collectionLongitude: _lng,
      branchId:            widget.branchId,
      paymentType:         isPayNow ? 'full' : 'pay_later',
      razorpayPaymentId:   isPayNow ? razorpayPaymentId : null,
      notes:               _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
    );

    if (!mounted) return;
    setState(() => _isProcessing = false);

    if (result == null || result['success'] != true) {
      AppMessages.error(context, AppMessages.serverMessage(result?['message'],
          fallback: 'We couldn\'t complete your booking. Please try again.'));
      return;
    }

    final bookings = (result['bookings'] as List? ?? []).cast<Map<String, dynamic>>();

    // Upload prescriptions for ALL members.
    // bookings[0] = primary patient, bookings[1..n] = family members in order.

    // Primary patient — prescriptions collected in the checkout screen (_prescriptions)
    if (_prescriptions.isNotEmpty && bookings.isNotEmpty) {
      final primaryBookingId  = bookings[0]['bookingId']      as int?;
      final primaryDocItemId  = bookings[0]['docRequiredItemId'] as int?;
      if (primaryBookingId != null) {
        try {
          final urls = <String>[];
          for (final doc in _prescriptions) {
            final url = await ApiService.uploadFile(doc.bytes, doc.fileName);
            if (url != null) urls.add(url);
          }
          if (urls.isNotEmpty) {
            await ApiService.savePrescription(
              bookingId:     primaryBookingId,
              patientId:     widget.patientId,
              bookingItemId: primaryDocItemId,
              imageUrls:     urls,
            );
          }
        } catch (_) {} // non-fatal
      }
    }

    // Family members — prescriptions collected in checkout screen (m.prescriptions)
    for (int i = 0; i < _familyMembers.length; i++) {
      final m = _familyMembers[i];
      if (m.prescriptions.isEmpty) continue;
      final memberBookingIndex = i + 1;
      if (memberBookingIndex >= bookings.length) continue;
      final memberBookingId  = bookings[memberBookingIndex]['bookingId']         as int?;
      final memberDocItemId  = bookings[memberBookingIndex]['docRequiredItemId'] as int?;
      if (memberBookingId == null) continue;
      try {
        final urls = <String>[];
        for (final doc in m.prescriptions) {
          final url = await ApiService.uploadFile(doc.bytes, doc.fileName);
          if (url != null) urls.add(url);
        }
        if (urls.isNotEmpty) {
          await ApiService.savePrescription(
            bookingId:     memberBookingId,
            patientId:     m.patient.patientId,
            bookingItemId: memberDocItemId,
            imageUrls:     urls,
          );
        }
      } catch (_) {} // non-fatal
    }

    final primaryBookingId = bookings.isNotEmpty ? bookings[0]['bookingId'] as int? : null;
    final isScheduled = result['isScheduled'] == true;

    if (primaryBookingId != null && widget.mode == 'Home Collection' && !isScheduled) {
      final address = [_address, _city, _pincode]
          .where((s) => s != null && s.isNotEmpty).join(', ');
      final socket = SocketService.instance;
      socket.registerPatientSocket(patientId: widget.patientId, bookingId: primaryBookingId);
      socket.emitBookingRequest(
        bookingId:       primaryBookingId,
        patientId:       widget.patientId,
        patientName:     widget.member.name,
        patientMobile:   widget.member.mobile,
        patientAddress:  address.isEmpty ? 'Home Collection' : address,
        patientLat:      _lat,
        patientLng:      _lng,
        hospital:        'MicroLab Home Collection',
        bookingType:     'lab',
        branchId:        widget.branchId,
        branchName:      widget.branch?.name,
        slotId:          _selectedSlot?.parentSlotId ?? int.tryParse(_selectedSlot?.id ?? ''),
        slotLabel:       _selectedSlot?.label,
        appointmentTime: _selectedAppointmentTime?.time ?? _selectedSlot?.time,
      );
    }

    final primaryRef = bookings.isNotEmpty ? (bookings[0]['bookingRef'] as String? ?? '') : '';
    final booking = BookingModel(
      id:            primaryRef,
      member:        widget.member,
      tests:         widget.cart,
      mode:          widget.mode,
      address:       _address,
      pincode:       _pincode,
      city:          _city,
      branch:        widget.branch,
      date:          _selectedDate!,
      timeSlot:      _selectedSlot?.label ?? '',
      paymentType:   _paymentType,
      serviceCharge: _serviceCharge,
      testsTotal:    _testsTotal,
      grandTotal:    _grandTotal,
      paidAmount:    _payableNow,
      status:        'Confirmed',
      createdAt:     DateTime.now(),
      docRequired:   _anyDocRequired,
      docVerified:   _docVerified,
      isVip:         widget.isVip,
      selectedTechnician: _selectedTechnician,
    );

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => isScheduled
            ? _BookingScheduledScreen(booking: booking)
            : _BookingSuccessScreen(
                booking:           booking,
                onBookingComplete: widget.onBookingComplete,
                familyCount:       _familyMembers.length,
              )),
      );
    }
  }

  // ── Open Razorpay checkout (or confirm directly for Pay Later) ──────────
  Future<void> _proceedToPayment() async {
    if (!_canProceed) return;

    // Validate doctor name — required only when 'Doctor' type is chosen
    if (_isDoctor && _doctorNameController.text.trim().isEmpty) {
      AppMessages.error(context, 'Please enter a doctor name for ${widget.member.name}.');
      return;
    }
    for (final m in _familyMembers) {
      if (m.isDoctor && m.doctorCtrl.text.trim().isEmpty) {
        AppMessages.error(context, 'Please enter a doctor name for ${m.patient.name}.');
        return;
      }
    }

    if (_paymentType == 'pay_later') {
      _confirmBooking('pay_later');
      return;
    }

    setState(() => _isProcessing = true);

    // Don't send the customer to pay for a time someone else just took.
    final slotId = int.tryParse(_selectedSlot?.id ?? '');
    if (slotId != null && !await ApiService.isSlotAvailable(slotId)) {
      if (!mounted) return;
      setState(() { _isProcessing = false; _selectedSlot = null; _selectedAppointmentTime = null; });
      AppMessages.error(context, 'This time was just booked by someone else. Please choose another time.');
      if (_selectedDate != null) _loadBranchSlots(_selectedDate!);
      return;
    }

    // TODO: fetch order_id from your backend first
    // POST /api/payment/create-order { amount: _payableNow, currency: 'INR' }
    // then use response['order_id'] below

    final options = {
      'key': AppConstants.razorpayKeyId,
      'amount': (_payableNow * 100).round(), // paise
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
    if (_familyMembers.isNotEmpty) {
      await _confirmFamilyBooking(razorpayPaymentId);
      return;
    }

    final address = [_address, _city, _pincode]
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
      'notes':          _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      'doctorName': _isDoctor ? _doctorNameController.text.trim() : 'Self',
      'items':          items,
      'paymentType':    isPayNow ? 'full' : 'pay_later',
      if (isPayNow) 'razorpayPaymentId': razorpayPaymentId,
      if (widget.branchId   != null) 'branchId': widget.branchId,
      if (_address    != null && _address!.isNotEmpty)   'collectionAddress': _address,
      if (_pincode    != null && _pincode!.isNotEmpty)   'collectionPincode': _pincode,
      if (_city       != null && _city!.isNotEmpty)      'collectionCity':    _city,
      if (_selectedDate     != null) 'collectionDate':
          '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}',
      if (_lat != null) 'collectionLatitude':  _lat,
      if (_lng != null) 'collectionLongitude': _lng,
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
    bool isScheduled = false;
    int? docBookingItemId; // booking_item_id of first doc-required item

    try {
      final url   = Uri.parse('${AppConstants.serverUrl}/api/bookings');
      final token = await ApiService.getToken();
      final res = await ApiService.authClient.post(
        url,
        headers: {
          'Content-Type':  'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 20)); // the server confirms the payment with Razorpay

      debugPrint('📥 [CHECKOUT] Response ${res.statusCode}: ${res.body}');

      if (res.statusCode != 201) {
        // Show the server's reason (e.g. outside the service area) when it
        // is a plain message; otherwise a general one.
        Object? serverMsg;
        try { serverMsg = (jsonDecode(res.body) as Map<String, dynamic>)['message']; } catch (_) {}
        if (!mounted) return;
        setState(() => _isProcessing = false);
        AppMessages.error(context, AppMessages.serverMessage(serverMsg,
            fallback: 'We couldn\'t complete your booking. Please try again.'));
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      bookingId   = data['bookingId']  as int;
      bookingRef  = data['bookingRef'] as String;
      isScheduled = data['isScheduled'] == true;

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
      AppMessages.error(context, 'We couldn\'t complete your booking. ${AppMessages.friendlyError(e)}');
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
      address: _address,
      pincode: _pincode,
      city: _city,
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

      if (widget.mode == 'Home Collection' && !isScheduled) {
        // Same-day booking: fire dispatch immediately in background.
        final socket = SocketService.instance;
        socket.registerPatientSocket(patientId: widget.patientId, bookingId: bookingId);
        socket.emitBookingRequest(
          bookingId:       bookingId,
          patientId:       widget.patientId,
          patientName:     widget.member.name,
          patientMobile:   widget.member.mobile,
          patientAddress:  address.isEmpty ? 'Home Collection' : address,
          patientLat:      _lat,
          patientLng:      _lng,
          hospital:        'MicroLab Home Collection',
          bookingType:     'lab',
          branchId:        widget.branchId,
          branchName:      widget.branch?.name,
          slotId:          _selectedSlot?.parentSlotId ?? int.tryParse(_selectedSlot?.id ?? ''),
          slotLabel:       _selectedSlot?.label,
          appointmentTime: _selectedAppointmentTime?.time ?? _selectedSlot?.time,
        );
      }
      // Future-date bookings: cron will dispatch on the appointment day.

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => isScheduled
              ? _BookingScheduledScreen(booking: booking)
              : _BookingSuccessScreen(
                  booking:           booking,
                  onBookingComplete: widget.onBookingComplete,
                  familyCount:       0,
                ),
        ),
      );
    }
  }

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  // ── Step indicator bar ────────────────────────────────────
  Widget _buildStepBar() {
    const labels = ['Schedule', 'Details', 'Payment'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.md, CxSpace.gutter, CxSpace.sm),
      child: Row(
        children: [
          for (int i = 0; i < 3; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 2,
                  color: i <= _currentStep ? AppColors.brandGreen : CxColors.border,
                ),
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _currentStep
                        ? AppColors.brandGreen
                        : i == _currentStep
                            ? AppColors.brandGreenSurface
                            : const Color(0xFFF5F5F5),
                    border: Border.all(
                      color: i <= _currentStep ? AppColors.brandGreen : CxColors.border,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: i < _currentStep
                        ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
                        : Text('${i + 1}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: i == _currentStep ? AppColors.brandGreen : CxColors.textHint,
                            )),
                  ),
                ),
                const SizedBox(height: 3),
                Text(labels[i],
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: i == _currentStep ? FontWeight.w700 : FontWeight.w500,
                      color: i == _currentStep ? AppColors.brandGreen : CxColors.textSecondary,
                    )),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Customer look for checkout and the sheets it opens.
    return CustomerThemeScope(
      child: Scaffold(
      backgroundColor: CxColors.page,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Checkout',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Center(
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: CxSize.contentMaxWidth),
        child: Column(
        children: [
          _buildStepBar(),
          Expanded(
            child: ListView(
            padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.sm, CxSpace.gutter, 140),
            children: [
          if (_currentStep == 0) ...[

          // ── Order Summary ─────────────────────────────────
          _SectionCard(
            title: 'Order Summary',
            icon: Icons.receipt_long_outlined,
            child: Column(
              children: [
                ...widget.cart.map((t) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      if (t.type == 'package') ...[
                        const Icon(Icons.inventory_2_outlined, size: 18, color: CxColors.brand),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.name, style: CxText.body.copyWith(fontWeight: FontWeight.w600)),
                            if (t.docRequired)
                              const Text('⚠ Prescription required',
                                  style: TextStyle(fontSize: 12, color: CxColors.warning, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      const SizedBox(width: CxSpace.sm),
                      Text('₹${t.finalPrice.toInt()}',
                          style: CxText.body.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                )),
              ],
            ),
          ),

          const SizedBox(height: CxSpace.sm),

          // ── Collection Info ───────────────────────────────
          _SectionCard(
            title: widget.mode == 'Lab Test' ? 'Lab Appointment' : widget.mode,
            icon: widget.mode == 'Home Collection' ? Icons.home_outlined : Icons.local_hospital_outlined,
            trailing: widget.mode == 'Home Collection'
                ? TextButton.icon(
                    onPressed: _editAddress,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('Edit'),
                    style: TextButton.styleFrom(
                      foregroundColor: CxColors.brand,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(48, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  )
                : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.mode == 'Home Collection') ...[
                  if (_address != null && _address!.isNotEmpty)
                    _InfoLine(Icons.location_on_outlined, _address!),
                  // Pincode / city only when the address doesn't already say them.
                  if ((_pincode != null && !(_address ?? '').contains(_pincode!)) ||
                      (_city != null && !(_address ?? '').toLowerCase().contains(_city!.toLowerCase())))
                    Row(children: [
                      if (_pincode != null)
                        Expanded(child: _InfoLine(Icons.pin_outlined, _pincode!)),
                      if (_pincode != null && _city != null)
                        const SizedBox(width: 12),
                      if (_city != null)
                        Expanded(child: _InfoLine(Icons.location_city_outlined, _city!)),
                    ]),
                  if (_lat == null) ...[
                    const SizedBox(height: CxSpace.sm),
                    const CxBanner(
                      tone: CxTone.warning,
                      icon: Icons.location_off_outlined,
                      message: 'Location not pinned on map — technician tracking will use address only.',
                    ),
                  ],
                ],
                if (widget.mode == 'Lab Test' && widget.branch != null) ...[
                  if (widget.branch != null) _InfoLine(Icons.local_hospital_outlined, widget.branch!.name),
                  if (widget.branch != null) _InfoLine(Icons.location_on_outlined, widget.branch!.address),
                ],
              ],
            ),
          ),

          const SizedBox(height: CxSpace.sm),

          // ── Schedule (Date strip + Time grid) ─────────────
          _SectionCard(
            title: 'Schedule',
            icon: Icons.calendar_today_outlined,
            required: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDateStrip(),
                const SizedBox(height: CxSpace.md),
                _buildTimeGrid(),
              ],
            ),
          ),
          ], // ── end page 0 ──────────────────────────────────
          if (_currentStep == 1) ...[

          const SizedBox(height: CxSpace.sm),

          // ── Prescription / Document (multi-image) ─────────
          if (_primaryNeedsPrescription || widget.isVip)
            _SectionCard(
              title: 'Prescription · ${widget.member.name}',
              icon: Icons.description_outlined,
              required: _primaryNeedsPrescription,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Info banner
                  CxBanner(
                    tone: CxTone.warning,
                    message: widget.mode == 'Lab Test'
                        ? 'A valid prescription is required for ${widget.member.name}. Upload it below — payment will be collected at the branch after verification.'
                        : 'A valid prescription is required for ${widget.member.name}. Upload it below — you cannot proceed without uploading.',
                  ),
                  const SizedBox(height: CxSpace.md),

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
                      style: CxText.caption,
                    ),
                    const SizedBox(height: 10),
                  ],

                  // Empty upload tile
                  if (_prescriptions.isEmpty)
                    Material(
                      color: CxColors.brandSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: CxRadius.mdAll,
                        side: BorderSide(color: CxColors.brand.withValues(alpha: 0.4), width: 1.5),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                      onTap: _isPicking ? null : _showPresSourcePicker,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 22),
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
                                    size: 30, color: AppColors.brandGreen),
                            const SizedBox(height: 8),
                            Text(
                              _isPicking ? 'Picking…' : 'Tap to upload prescription',
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.brandGreen),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Up to $_maxPrescrips images · JPG or PNG',
                              style: CxText.caption,
                            ),
                          ],
                        ),
                      ),
                      ),
                    ),

                  // Verification status
                  if (_prescriptions.isNotEmpty && !_docVerified) ...[
                    const SizedBox(height: 10),
                    CxBanner(
                      tone: CxTone.brand,
                      icon: Icons.hourglass_top_rounded,
                      title: 'Prescription uploaded',
                      message: widget.mode == 'Lab Test'
                          ? 'Bring original to the branch on appointment day'
                          : 'Awaiting technician verification',
                    ),
                  ],
                  if (_docVerified) ...[
                    const SizedBox(height: 10),
                    const CxBanner(
                      tone: CxTone.success,
                      icon: Icons.verified_outlined,
                      message: 'Document verified by technician',
                    ),
                  ],
                ],
              ),
            ),

          if (_anyDocRequired) const SizedBox(height: CxSpace.sm),

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
                    const CxBanner(
                      tone: CxTone.neutral,
                      message: 'Please select a date and time slot first to see available technicians.',
                    )
                  else ...[
                    Text(
                      'Available for ${_selectedSlot!.label} on ${_formatDate(_selectedDate!)}',
                      style: CxText.bodySecondary,
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
            const SizedBox(height: CxSpace.sm),
          ],

          // ── Additional Details (Doctor / Self + Notes) ───
          // (the card above already left the gap — no second one here)
          _SectionCard(
            title: 'Additional Details',
            icon: Icons.edit_note_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Self / Doctor toggle — label and chips on one line
                Row(children: [
                  Text('Referred by', style: CxText.bodySecondary.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  _DoctorTypeChip(
                    label: 'Self',
                    icon: Icons.person_outline_rounded,
                    selected: !_isDoctor,
                    onTap: () => setState(() {
                      _doctorType = 'self';
                      _doctorNameController.clear();
                    }),
                  ),
                  const SizedBox(width: 10),
                  _DoctorTypeChip(
                    label: 'Doctor',
                    icon: Icons.local_hospital_outlined,
                    selected: _isDoctor,
                    onTap: () => setState(() => _doctorType = 'doctor'),
                  ),
                ]),


                // Doctor name + optional prescription (only when Doctor chosen)
                if (_isDoctor) ...[
                  const SizedBox(height: CxSpace.md),
                  Row(children: [
                    Text('Doctor Name', style: CxText.bodySecondary.copyWith(fontWeight: FontWeight.w600)),
                    const Text(' *', style: TextStyle(color: CxColors.error, fontSize: 13)),
                  ]),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _doctorNameController,
                    maxLines: 1,
                    maxLength: 150,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.words,
                    style: CxText.body,
                    decoration: const InputDecoration(
                      hintText: 'Enter doctor\'s name',
                      prefixIcon: Icon(Icons.person_outline_rounded, size: 20, color: CxColors.textHint),
                      counterStyle: CxText.caption,
                    ),
                  ),
                  const SizedBox(height: CxSpace.sm),
                  Text('Prescription', style: CxText.bodySecondary.copyWith(fontWeight: FontWeight.w600)),
                  const Text('Optional', style: TextStyle(fontSize: 11, color: CxColors.textHint)),
                  const SizedBox(height: 8),
                  if (_prescriptions.isNotEmpty) ...[
                    SizedBox(
                      height: 100,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(right: 8),
                        itemCount: _prescriptions.length +
                            (_prescriptions.length < _maxPrescrips ? 1 : 0),
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          if (i == _prescriptions.length) {
                            return _PresAddMoreTile(onTap: _isPicking ? null : _showPresSourcePicker);
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
                    Text('${_prescriptions.length} of $_maxPrescrips uploaded', style: CxText.caption),
                    const SizedBox(height: 8),
                  ],
                  if (_prescriptions.isEmpty)
                    Material(
                      color: const Color(0xFFF5F5F5),
                      shape: RoundedRectangleBorder(
                        borderRadius: CxRadius.mdAll,
                        side: const BorderSide(color: CxColors.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _isPicking ? null : _showPresSourcePicker,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _isPicking
                                  ? const SizedBox(width: 18, height: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen))
                                  : const Icon(Icons.upload_file_outlined, size: 20, color: AppColors.brandGreen),
                              const SizedBox(width: 8),
                              Text(_isPicking ? 'Picking…' : 'Upload prescription (optional)',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                                      color: AppColors.brandGreen)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],

                // Notes — one line, grows while typing; the counter only
                // shows near the 300-character limit.
                const SizedBox(height: 10),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _notesController,
                  builder: (_, value, __) => TextField(
                    controller: _notesController,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 300,
                    textInputAction: TextInputAction.done,
                    textCapitalization: TextCapitalization.sentences,
                    style: CxText.body,
                    decoration: InputDecoration(
                      hintText: 'Notes — any special instructions (optional)',
                      prefixIcon: const Icon(Icons.notes_rounded, size: 18, color: CxColors.textHint),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                      counterText: value.text.length >= 250 ? null : '',
                      counterStyle: CxText.caption,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Family Members (Home Collection only) ─────────
          if (widget.mode == 'Home Collection') ...[
            const SizedBox(height: CxSpace.sm),
            _SectionCard(
              title: 'Family Members (Same Visit)',
              icon: Icons.group_outlined,
              trailing: _AddPill(label: 'Add', onTap: _showAddMemberSheet),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_familyMembers.isEmpty)
                    const Text(
                      'Share this visit — one service charge for everyone.',
                      style: CxText.caption,
                    ),
                  ..._familyMembers.map((m) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _FamilyMemberTile(
                        member: m,
                        onRemove: () { m.dispose(); setState(() => _familyMembers.remove(m)); },
                      ),
                      // Self / Doctor toggle for family member
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Referred by', style: CxText.bodySecondary.copyWith(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Row(children: [
                              _DoctorTypeChip(
                                label: 'Self',
                                icon: Icons.person_outline_rounded,
                                selected: !m.isDoctor,
                                onTap: () => setState(() {
                                  m.doctorType = 'self';
                                  m.doctorCtrl.clear();
                                }),
                              ),
                              const SizedBox(width: 10),
                              _DoctorTypeChip(
                                label: 'Doctor',
                                icon: Icons.local_hospital_outlined,
                                selected: m.isDoctor,
                                onTap: () => setState(() => m.doctorType = 'doctor'),
                              ),
                            ]),
                            if (m.isDoctor) ...[
                              const SizedBox(height: CxSpace.md),
                              Row(children: [
                                Text('Doctor Name', style: CxText.bodySecondary.copyWith(fontWeight: FontWeight.w600)),
                                const Text(' *', style: TextStyle(color: CxColors.error, fontSize: 13)),
                              ]),
                              const SizedBox(height: 6),
                              TextField(
                                controller: m.doctorCtrl,
                                maxLines: 1,
                                maxLength: 150,
                                textInputAction: TextInputAction.next,
                                textCapitalization: TextCapitalization.words,
                                style: CxText.body,
                                decoration: InputDecoration(
                                  hintText: 'Enter doctor\'s name',
                                  prefixIcon: const Icon(Icons.person_outline_rounded, size: 20, color: CxColors.textHint),
                                  counterStyle: CxText.caption,
                                ),
                              ),
                              const SizedBox(height: CxSpace.sm),
                              Text('Prescription', style: CxText.bodySecondary.copyWith(fontWeight: FontWeight.w600)),
                              const Text('Optional', style: TextStyle(fontSize: 11, color: CxColors.textHint)),
                              const SizedBox(height: 8),
                              if (m.prescriptions.isNotEmpty) ...[
                                SizedBox(
                                  height: 100,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.only(right: 8),
                                    itemCount: m.prescriptions.length +
                                        (m.prescriptions.length < _maxPrescrips ? 1 : 0),
                                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                                    itemBuilder: (_, i) {
                                      if (i == m.prescriptions.length) {
                                        return _PresAddMoreTile(onTap: _isPicking ? null : () => _showFamilyPresSourcePicker(m));
                                      }
                                      return _PresThumbnailCard(
                                        doc: m.prescriptions[i],
                                        onView: () => _viewFamilyPres(m, i),
                                        onDelete: () => _deleteFamilyPres(m, i),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text('${m.prescriptions.length} of $_maxPrescrips uploaded', style: CxText.caption),
                                const SizedBox(height: 8),
                              ],
                              if (m.prescriptions.isEmpty)
                                Material(
                                  color: const Color(0xFFF5F5F5),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: CxRadius.mdAll,
                                    side: const BorderSide(color: CxColors.border),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: _isPicking ? null : () => _showFamilyPresSourcePicker(m),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      child: Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          _isPicking
                                              ? const SizedBox(width: 18, height: 18,
                                                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen))
                                              : const Icon(Icons.upload_file_outlined, size: 20, color: AppColors.brandGreen),
                                          const SizedBox(width: 8),
                                          Text(_isPicking ? 'Picking…' : 'Upload prescription (optional)',
                                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                                                  color: AppColors.brandGreen)),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(height: CxSpace.sm),
                            ],
                          ],
                        ),
                      ),
                    ],
                  )),
                ],
              ),
            ),
          ],
          ], // ── end page 1 ──────────────────────────────────
          if (_currentStep == 2) ...[

          const SizedBox(height: CxSpace.sm),

          // ── Billing Summary ───────────────────────────────
          _SectionCard(
            title: 'Billing Summary',
            icon: Icons.calculate_outlined,
            child: Column(
              children: [
                _BillRow('${widget.member.name} (Tests)', '₹${_testsTotal.toInt()}'),
                ..._familyMembers.map((m) => _BillRow('${m.patient.name}', '₹${m.testsTotal.toInt()}')),
                if (_isHomeCollection)
                  _fareLoading
                    ? const _BillRow('Service Charge', '…')
                    : _fareError != null
                      ? _BillRow('Service Charge', _fareError!, sub: true)
                      : _fareAmount != null
                        ? _BillRow('Service Charge', '₹${_fareAmount!.toInt()}')
                        : const _BillRow('Service Charge', 'N/A', sub: true),
                const Divider(height: 16),
                _BillRow('Grand Total', '₹${_grandTotal.toInt()}', bold: true),
                const SizedBox(height: CxSpace.sm),
                // The amount the customer acts on, set apart.
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: const BoxDecoration(
                    color: CxColors.brandSurface,
                    borderRadius: CxRadius.mdAll,
                  ),
                  child: Column(children: [
                    _BillRow('Pay Now', '₹${_payableNow.toInt()}', bold: true, green: true),
                    if (_paymentType == 'pay_later')
                      _BillRow('Due at Collection', '₹${_payableLater.toInt()}', sub: true),
                  ]),
                ),
              ],
            ),
          ),

          const SizedBox(height: CxSpace.sm),

          // ── Payment Options (horizontal) ──────────────────
          _SectionCard(
            title: 'Payment Option',
            icon: Icons.payment_outlined,
            required: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(
                        child: _PaymentOptionCompact(
                          selected: _paymentType == 'full',
                          title: 'Pay Now',
                          amount: '₹${_grandTotal.toInt()}',
                          accentColor: _fullPaymentEnabled ? AppColors.brandGreen : AppColors.textHint,
                          enabled: _fullPaymentEnabled,
                          onTap: _fullPaymentEnabled ? () => setState(() => _paymentType = 'full') : null,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _PaymentOptionCompact(
                          selected: _paymentType == 'pay_later',
                          title: 'Pay Later',
                          amount: '₹0 now',
                          accentColor: AppColors.blue,
                          enabled: true,
                          onTap: () => setState(() => _paymentType = 'pay_later'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ], // ── end page 2 ──────────────────────────────────
            ],
            ),
          ),
        ],
        ),
        ),
      ),

      // ── Bottom: step nav ─────────────────────────────────
      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.md, CxSpace.gutter, MediaQuery.of(context).padding.bottom + CxSpace.md),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: CxColors.border)),
          boxShadow: [BoxShadow(color: Color(0x12000000), blurRadius: 14, offset: Offset(0, -3))],
        ),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: CxSize.contentMaxWidth),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Error hints
            if (_currentStep == 0 && !_step0Complete)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 16, color: CxColors.error),
                    const SizedBox(width: 6),
                    Flexible(child: Text(
                      _selectedDate == null
                          ? 'Please select a date'
                          : _selectedSlot == null
                              ? 'Please select a time slot'
                              : _currentSlotIntervals.isNotEmpty && _selectedAppointmentTime == null
                                  ? 'Please select an appointment time'
                                  : widget.isVip && _selectedTechnician == null
                                      ? 'Please choose your preferred technician'
                                      : '',
                      style: const TextStyle(fontSize: 13, color: CxColors.error, fontWeight: FontWeight.w500),
                      textAlign: TextAlign.center,
                    )),
                  ],
                ),
              ),
            if (_currentStep == 1 && !_step1Complete)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 16, color: CxColors.error),
                    const SizedBox(width: 6),
                    Flexible(child: Text(
                      'Upload prescription for ${widget.member.name} to continue',
                      style: const TextStyle(fontSize: 13, color: CxColors.error, fontWeight: FontWeight.w500),
                      textAlign: TextAlign.center,
                    )),
                  ],
                ),
              ),
            Row(children: [
              // Back button on steps 1 and 2
              if (_currentStep > 0) ...[
                OutlinedButton(
                  onPressed: () => setState(() => _currentStep--),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CxColors.textPrimary,
                    side: const BorderSide(color: CxColors.border),
                    shape: const RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 10),
              ],
              // Next / Pay button
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: _currentStep < 2
                      ? FilledButton(
                          onPressed: (_currentStep == 0 ? _step0Complete : _step1Complete)
                              ? () => setState(() => _currentStep++)
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: CxColors.brand,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: CxColors.border,
                            disabledForegroundColor: CxColors.textHint,
                            shape: const RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
                            textStyle: CxText.button,
                          ),
                          child: Text(_currentStep == 0 ? 'Next: Details →' : 'Review & Pay →'),
                        )
                      : FilledButton(
                          onPressed: _canProceed && !_isProcessing ? _proceedToPayment : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: CxColors.brand,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: _isProcessing ? CxColors.brand : CxColors.border,
                            disabledForegroundColor: _isProcessing ? Colors.white : CxColors.textHint,
                            shape: const RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
                            textStyle: CxText.button,
                          ),
                          child: _isProcessing
                              ? const SizedBox(width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                              : Text(
                                  _paymentType == 'pay_later'
                                      ? 'Confirm Booking · Pay Later'
                                      : _paymentType == 'cash'
                                          ? 'Confirm Booking · Pay Cash'
                                          : 'Pay ₹${_payableNow.toInt()} via Razorpay',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                ),
              ),
            ]),
          ],
          ),
          ),
        ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
        color: selected ? CxColors.brandSurface : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: CxRadius.lgAll,
          side: BorderSide(
            color: selected ? CxColors.brand : CxColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
        onTap: onTap,
        child: Padding(
        padding: const EdgeInsets.all(CxSpace.md),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: selected
                    ? CxColors.brand
                    : CxColors.brandSurface,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  technician.name.isNotEmpty
                      ? technician.name.split(' ').map((w) => w[0]).take(2).join()
                      : '?',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: selected ? Colors.white : CxColors.brand),
                ),
              ),
            ),
            const SizedBox(width: 12),

            // Details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(technician.name, style: CxText.cardTitle),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Icon(Icons.star_rounded,
                        size: 15, color: Color(0xFFFFB300)),
                    const SizedBox(width: 3),
                    Text('${technician.rating}  ·  ${technician.experience}',
                        style: CxText.caption),
                  ]),
                  const SizedBox(height: 3),
                  Text(technician.specializations.join(', '),
                      style: CxText.caption,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),

            // Radio
            Icon(
              selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
              color: selected ? CxColors.brand : CxColors.textHint,
            ),
          ],
        ),
        ),
        ),
        ),
      ),
    );
  }
}

// ─── Compact horizontal payment option card ───────────────────────────────────

class _PaymentOptionCompact extends StatelessWidget {
  final bool selected;
  final String title;
  final String amount;
  final Color accentColor;
  final bool enabled;
  final VoidCallback? onTap;

  const _PaymentOptionCompact({
    required this.selected,
    required this.title,
    required this.amount,
    required this.accentColor,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = !enabled ? CxColors.border : selected ? accentColor : CxColors.border;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
        color: !enabled
            ? CxColors.surfaceMuted
            : selected ? accentColor.withValues(alpha: 0.07) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: CxRadius.lgAll,
          side: BorderSide(color: borderColor, width: selected ? 1.6 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                  color: !enabled ? CxColors.border : selected ? accentColor : CxColors.textHint,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: !enabled ? CxColors.textHint : CxColors.textPrimary)),
                      Text(amount,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: !enabled ? CxColors.textHint : accentColor)),
                    ],
                  ),
                ),
                if (!enabled)
                  const Icon(Icons.lock_outline_rounded, size: 16, color: CxColors.textHint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Small "+ Add" pill for a section header ─────────────────────────────────

class _AddPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _AddPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Add family member',
        excludeSemantics: true,
        child: Material(
          color: CxColors.brandSurface,
          shape: const StadiumBorder(side: BorderSide(color: CxColors.brand)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.person_add_alt_1_outlined, size: 16, color: CxColors.brand),
                  const SizedBox(width: 4),
                  Text(label,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CxColors.brand)),
                ]),
              ),
            ),
          ),
        ),
      );
}

// ─── Doctor type toggle chip ──────────────────────────────────────────────────

class _DoctorTypeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _DoctorTypeChip({required this.label, required this.icon,
      required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? CxColors.brandSurface : Colors.white,
        borderRadius: CxRadius.lgAll,
        border: Border.all(
          color: selected ? CxColors.brand : CxColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18,
            color: selected ? CxColors.brand : CxColors.textSecondary),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? CxColors.brand : CxColors.textPrimary)),
      ]),
    ),
  );
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
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
      color: !enabled
          ? CxColors.surfaceMuted
          : selected
              ? badgeColor.withValues(alpha: 0.06)
              : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: CxRadius.lgAll,
        side: BorderSide(
          color: !enabled
              ? CxColors.border
              : selected
                  ? badgeColor
                  : CxColors.border,
          width: selected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(CxSpace.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                color: !enabled ? CxColors.border : selected ? badgeColor : CxColors.textHint,
                size: 22,
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
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: !enabled
                                  ? CxColors.textHint
                                  : CxColors.textPrimary)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.1),
                          borderRadius: CxRadius.pill,
                        ),
                        child: Text(badge,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                                color: badgeColor, letterSpacing: 0.4)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle,
                      style: TextStyle(fontSize: 13,
                          color: !enabled ? CxColors.textHint : CxColors.textSecondary,
                          height: 1.4)),
                  const SizedBox(height: 8),
                  Text(amount,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700,
                          color: !enabled ? CxColors.textHint : badgeColor)),
                ],
              ),
            ),
            if (!enabled)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.lock_outline_rounded, size: 18, color: CxColors.textHint),
              ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

// ─── Booking result screens: shared hero card ─────────────────────────────────

class _ResultHero extends StatelessWidget {
  final IconData icon;
  final CxTone tone;
  final String title;
  final String? reference;
  final String? message;
  final Widget? footer;
  const _ResultHero({required this.icon, required this.tone, required this.title,
      this.reference, this.message, this.footer});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(CxSpace.xxl, 28, CxSpace.xxl, CxSpace.xxl),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: CxRadius.lgAll,
          border: Border.all(color: CxColors.border),
          boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 2))],
        ),
        child: Column(
          children: [
            Container(
              width: 84, height: 84,
              decoration: BoxDecoration(color: tone.surface, shape: BoxShape.circle),
              child: Icon(icon, size: 46, color: tone.color),
            ),
            const SizedBox(height: CxSpace.lg),
            Text(title, textAlign: TextAlign.center, style: CxText.pageTitle.copyWith(fontSize: 22)),
            if (reference != null) ...[
              const SizedBox(height: 6),
              CxChip(label: reference!, icon: Icons.tag_rounded, tone: CxTone.neutral),
            ],
            if (message != null) ...[
              const SizedBox(height: CxSpace.sm),
              Text(message!, textAlign: TextAlign.center, style: CxText.bodySecondary),
            ],
            if (footer != null) ...[const SizedBox(height: CxSpace.lg), footer!],
          ],
        ),
      );
}

// Bottom actions on the result screens.
class _ResultActions extends StatelessWidget {
  final VoidCallback onHome;
  final VoidCallback onBookings;
  const _ResultActions({required this.onHome, required this.onBookings});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.md, CxSpace.gutter, MediaQuery.of(context).padding.bottom + CxSpace.md),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: CxColors.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: CxButton.secondary(onPressed: onHome, icon: Icons.home_outlined, label: 'Back to Home'),
            ),
            const SizedBox(width: CxSpace.md),
            Expanded(
              child: CxButton(onPressed: onBookings, icon: Icons.calendar_month_outlined, label: 'My Bookings'),
            ),
          ],
        ),
      );
}

Widget _testsBookedList(List<TestModel> tests) => Column(
      children: tests.map((t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            CxIconBadge(
              icon: t.type == 'package' ? Icons.inventory_2_outlined : Icons.science_outlined,
              tone: t.type == 'package' ? CxTone.brand : CxTone.info,
              size: 32,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(t.name, style: CxText.body)),
            Text('₹${t.finalPrice.toInt()}',
                style: CxText.body.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      )).toList(),
    );

// ─── Booking Success (Lab Test / static) ─────────────────────────────────────

class _BookingSuccessScreen extends StatelessWidget {
  final BookingModel booking;
  final VoidCallback? onBookingComplete;
  final int familyCount;
  const _BookingSuccessScreen({required this.booking, this.onBookingComplete, this.familyCount = 0});

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return CustomerThemeScope(
      child: Scaffold(
      backgroundColor: CxColors.page,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: CxSize.contentMaxWidth),
                child: ListView(
                padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.xxl, CxSpace.gutter, CxSpace.xxl),
                children: [
                  // Success banner
                  _ResultHero(
                    icon: Icons.check_circle_rounded,
                    tone: CxTone.success,
                    title: 'Booking Confirmed!',
                    reference: booking.referenceNo,
                    footer: BookingStatusBadge(status: booking.status),
                  ),

                  if (familyCount > 0) ...[
                    const SizedBox(height: CxSpace.md),
                    CxBanner(
                      tone: CxTone.brand,
                      icon: Icons.group_outlined,
                      message: '$familyCount more family member${familyCount == 1 ? '' : 's'} added to this visit',
                    ),
                  ],

                  const SizedBox(height: CxSpace.md),

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
                        if (booking.mode == 'Home Collection') ...[
                          if (booking.address != null && booking.address!.isNotEmpty)
                            _ConfirmRow(Icons.home_outlined, 'Address', booking.address!),
                          if (booking.city != null || booking.pincode != null)
                            _ConfirmRow(Icons.location_on_outlined, 'Location',
                                [booking.city, booking.pincode]
                                    .where((s) => s != null && s.isNotEmpty)
                                    .join(', ')),
                        ],
                        if (booking.mode == 'Lab Test' && booking.branch != null)
                          if (booking.branch != null) _ConfirmRow(Icons.local_hospital_outlined, 'Branch', booking.branch!.name),
                        if (booking.selectedTechnician != null)
                          _ConfirmRow(Icons.medical_services_outlined, 'Technician',
                              '${booking.selectedTechnician!.name}  ★ ${booking.selectedTechnician!.rating}'),
                      ],
                    ),
                  ),

                  const SizedBox(height: CxSpace.md),

                  _SectionCard(
                    title: 'Tests Booked',
                    icon: Icons.science_outlined,
                    child: _testsBookedList(booking.tests),
                  ),

                  const SizedBox(height: CxSpace.md),

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
                              valueColor: CxColors.warning),
                      ],
                    ),
                  ),

                  const SizedBox(height: CxSpace.md),

                  _NextStepsCard(
                    title: "What's next?",
                    tone: CxTone.brand,
                    steps: booking.mode == 'Lab Test'
                        ? const [
                            _NextStep('1', 'Visit the branch at your selected date and time slot'),
                            _NextStep('2', 'Carry any required prescriptions or documents'),
                            _NextStep('3', 'Follow the pre-test instructions for your tests'),
                            _NextStep('4', 'Reports will be shared within the promised time'),
                          ]
                        : const [
                            _NextStep('1', 'A technician has been allocated to your booking'),
                            _NextStep('2', 'You will receive a call 1 hour before the appointment'),
                            _NextStep('3', 'Keep your samples ready as per test requirements'),
                            _NextStep('4', 'Reports will be shared within the promised time'),
                          ],
                  ),
                ],
              ),
                ),
              ),
            ),

            _ResultActions(
              onHome: () {
                onBookingComplete?.call();
                Navigator.popUntil(context, (route) => route.isFirst);
              },
              onBookings: () {
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => MyBookingsScreen(initialBooking: booking)));
              },
            ),
          ],
        ),
      ),
      ),
    );
  }
}


// ─── Booking Scheduled (future-date — cron will dispatch on the day) ──────────

class _BookingScheduledScreen extends StatelessWidget {
  final BookingModel booking;
  const _BookingScheduledScreen({required this.booking});

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return CustomerThemeScope(
      child: Scaffold(
      backgroundColor: CxColors.page,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: CxSize.contentMaxWidth),
                child: ListView(
                padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.xxl, CxSpace.gutter, CxSpace.xxl),
                children: [
                  // Scheduled banner
                  _ResultHero(
                    icon: Icons.event_available_rounded,
                    tone: CxTone.info,
                    title: 'Booking Confirmed!',
                    reference: booking.referenceNo,
                    message: 'A technician will be assigned closer to your appointment time.',
                  ),

                  const SizedBox(height: CxSpace.md),

                  _SectionCard(
                    title: 'Booking Details',
                    icon: Icons.info_outline_rounded,
                    child: Column(
                      children: [
                        _ConfirmRow(Icons.person_outline, 'Customer', booking.member.name),
                        _ConfirmRow(Icons.event_outlined, 'Date', _formatDate(booking.date)),
                        _ConfirmRow(Icons.schedule_outlined, 'Time Slot', booking.timeSlot),
                        _ConfirmRow(Icons.home_outlined, 'Mode', booking.mode),
                        if (booking.mode == 'Home Collection' && booking.city != null)
                          _ConfirmRow(Icons.location_on_outlined, 'Location',
                              '${booking.city}${booking.pincode != null ? ', ${booking.pincode}' : ''}'),
                      ],
                    ),
                  ),

                  const SizedBox(height: CxSpace.md),

                  _SectionCard(
                    title: 'Tests Booked',
                    icon: Icons.science_outlined,
                    child: _testsBookedList(booking.tests),
                  ),

                  const SizedBox(height: CxSpace.md),

                  // What happens next
                  const _NextStepsCard(
                    title: 'What happens next?',
                    tone: CxTone.info,
                    steps: [
                      _NextStep('1', 'Your booking is confirmed and saved'),
                      _NextStep('2', 'A technician will be assigned ~1 hour before your slot'),
                      _NextStep('3', 'You will receive a call before the technician arrives'),
                      _NextStep('4', 'Keep your samples ready as per test requirements'),
                    ],
                  ),
                ],
              ),
                ),
              ),
            ),

            _ResultActions(
              onHome: () => Navigator.pop(context),
              onBookings: () {
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => MyBookingsScreen(initialBooking: booking)));
              },
            ),
          ],
        ),
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
  final Widget? trailing;
  const _SectionCard({required this.title, required this.icon, required this.child, this.required = false, this.trailing});

  @override
  // Compact card: 14px padding, 28px icon, 8px under the title. The title
  // takes all the free space (the old Flexible + Spacer split it in half,
  // cutting "Home Collection" to "Home Collec…").
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: CxRadius.lgAll,
          border: Border.all(color: CxColors.border),
          boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CxIconBadge(icon: icon, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(text: title, children: [
                    if (required)
                      const TextSpan(text: ' *', style: TextStyle(color: CxColors.error, fontWeight: FontWeight.w700)),
                  ]),
                  style: CxText.sectionTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: 8),
            child,
          ],
        ),
      );
}

// A selectable time pill (slots and appointment times).
class _ChoicePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color activeColor;
  final bool highlight;
  const _ChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.activeColor = AppColors.brandGreen,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? activeColor : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: CxRadius.mdAll,
            side: BorderSide(
              color: selected ? activeColor : (highlight ? activeColor : CxColors.border),
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Center(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? Colors.white
                            : (highlight ? activeColor : CxColors.textPrimary))),
              ),
            ),
          ),
        ),
      );
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoLine(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 17, color: CxColors.textHint),
            ),
            const SizedBox(width: CxSpace.sm),
            Flexible(child: Text(text, overflow: TextOverflow.ellipsis, maxLines: 2,
                style: CxText.body)),
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
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(
                fontSize: sub ? 13 : 14,
                fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                color: sub ? CxColors.textSecondary : CxColors.textPrimary))),
            const SizedBox(width: 8),
            Text(value, style: TextStyle(
                fontSize: sub ? 13 : (bold ? 16 : 14),
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                color: green ? CxColors.brand : CxColors.textPrimary)),
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
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 18, color: CxColors.textHint),
            ),
            const SizedBox(width: 10),
            SizedBox(width: 110,
              child: Text(label, style: CxText.bodySecondary)),
            Expanded(
              child: Text(value, style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600,
                  color: valueColor ?? CxColors.textPrimary)),
            ),
          ],
        ),
      );
}

class _NextStepsCard extends StatelessWidget {
  final String title;
  final CxTone tone;
  final List<_NextStep> steps;
  const _NextStepsCard({required this.title, required this.tone, required this.steps});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(CxSpace.lg),
        decoration: BoxDecoration(color: tone.surface, borderRadius: CxRadius.lgAll),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: CxText.sectionTitle.copyWith(color: tone.color)),
            const SizedBox(height: CxSpace.md),
            for (final s in steps) _NextStep(s.number, s.text, color: tone.color),
          ],
        ),
      );
}

class _NextStep extends StatelessWidget {
  final String number;
  final String text;
  final Color color;
  const _NextStep(this.number, this.text, {this.color = AppColors.brandGreen});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Center(child: Text(number,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
            ),
            const SizedBox(width: CxSpace.md),
            Expanded(child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text, style: CxText.body),
            )),
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
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
          Semantics(
            button: true,
            label: 'View prescription image',
            child: GestureDetector(
              onTap: onView,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  borderRadius: CxRadius.mdAll,
                  border: Border.all(color: CxColors.border),
                ),
                child: ClipRRect(
                  borderRadius: CxRadius.mdAll,
                  child: Image.memory(doc.bytes, fit: BoxFit.cover),
                ),
              ),
            ),
          ),
          Positioned(
            top: -8, right: -8,
            child: Semantics(
              button: true,
              label: 'Remove image',
              child: GestureDetector(
                onTap: onDelete,
                child: Container(
                  width: 28, height: 28,
                  decoration: BoxDecoration(
                    color: CxColors.error,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 6, right: 6,
            child: IgnorePointer(
              child: Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.fullscreen_rounded, size: 14, color: Colors.white),
              ),
            ),
          ),
        ]);
}

class _PresAddMoreTile extends StatelessWidget {
  final VoidCallback? onTap;
  const _PresAddMoreTile({this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: CxColors.brandSurface,
        shape: RoundedRectangleBorder(
          borderRadius: CxRadius.mdAll,
          side: BorderSide(color: CxColors.brand.withValues(alpha: 0.5), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
        onTap: onTap,
        child: const SizedBox(
          width: 96, height: 96,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.add_photo_alternate_outlined, size: 28, color: AppColors.brandGreen),
            SizedBox(height: 4),
            Text('Add more',
                style: TextStyle(
                    fontSize: 12,
                    color: AppColors.brandGreen,
                    fontWeight: FontWeight.w600)),
          ]),
        ),
        ),
      );
}

class _PresSourceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _PresSourceTile(this.icon, this.title, this.subtitle, this.onTap);

  // Same look as the shared option card; tap behaviour unchanged.
  @override
  Widget build(BuildContext context) => CxOptionCard(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: onTap,
      );
}

// ─── Family member tile (shown in checkout list) ──────────────────────────────

class _FamilyMemberTile extends StatelessWidget {
  final _FamilyMember member;
  final VoidCallback onRemove;
  const _FamilyMemberTile({required this.member, required this.onRemove});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(CxSpace.md, 10, 4, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: CxRadius.mdAll,
          border: Border.all(color: CxColors.border),
        ),
        child: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: CxColors.brandSurface,
            child: Text(member.patient.name.isNotEmpty ? member.patient.name[0].toUpperCase() : '?',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: CxColors.brand)),
          ),
          const SizedBox(width: CxSpace.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(member.patient.name, style: CxText.cardTitle),
              Text(
                '${member.tests.length} test${member.tests.length == 1 ? '' : 's'} · ₹${member.testsTotal.toInt()}',
                style: CxText.bodySecondary,
              ),
              if (member.anyDocRequired) ...[
                const SizedBox(height: 3),
                Row(children: [
                  Icon(
                    member.prescriptionBytes.isNotEmpty
                        ? Icons.check_circle_rounded
                        : Icons.error_outline_rounded,
                    size: 14,
                    color: member.prescriptionBytes.isNotEmpty
                        ? CxColors.brand
                        : CxColors.warning,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    member.prescriptionBytes.isNotEmpty
                        ? 'Prescription uploaded'
                        : 'Prescription required',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: member.prescriptionBytes.isNotEmpty
                          ? CxColors.brand
                          : CxColors.warning,
                    ),
                  ),
                ]),
              ],
            ]),
          ),
          CxIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Remove ${member.patient.name}',
            color: CxColors.textSecondary,
            onPressed: onRemove,
          ),
        ]),
      );
}

// ─── Add family member bottom sheet ───────────────────────────────────────────

class _AddMemberSheet extends StatefulWidget {
  final int primaryPatientId;
  final Set<int> excludedPatientIds;
  final void Function(_FamilyMember) onAdd;
  final VoidCallback? onMemberAdded;

  const _AddMemberSheet({
    required this.primaryPatientId,
    required this.excludedPatientIds,
    required this.onAdd,
    this.onMemberAdded,
  });

  @override
  State<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends State<_AddMemberSheet> {
  bool _loadingPatients = true;
  List<PatientModel> _patients = [];
  PatientModel? _selected;
  // Selected tests by id. Kept apart from the loaded page, so a test picked
  // before a new search is still counted in the total and the booking.
  final Map<String, TestModel> _selectedTests = {};
  Iterable<String> get _selectedTestIds => _selectedTests.keys;
  int _step = 0; // 0 = pick patient, 1 = pick tests, 2 = upload prescription

  // ── Create new member inline ──────────────────────────────
  bool _showNewMemberForm = false;
  final _newNameCtrl   = TextEditingController();
  final _newMobileCtrl = TextEditingController();
  String? _newGender;
  String? _newRelation;
  bool _savingNewMember = false;
  DateTime? _newDob;
  String? _nameError;
  String? _mobileError;
  String? _dobError;
  String? _genderError;
  static const _genders   = ['Male', 'Female', 'Other'];
  static const _relations = ['Spouse', 'Father', 'Mother', 'Son', 'Daughter', 'Brother', 'Sister', 'Other'];

  // Tests load one page at a time, searched on the server.
  final PackagePager _pager = PackagePager();
  final TextEditingController _testSearchCtrl = TextEditingController();

  final List<Uint8List> _prescriptionBytes = [];
  bool _isPicking = false;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadPatients();
    _pager.addListener(_onPagerChanged);
    _pager.refresh();
    _testSearchCtrl.addListener(() => _pager.setSearch(_testSearchCtrl.text));
  }

  void _onPagerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pager.removeListener(_onPagerChanged);
    _pager.dispose();
    _testSearchCtrl.dispose();
    _newNameCtrl.dispose();
    _newMobileCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPatients() async {
    final all = await ApiService.getPatients();
    if (!mounted) return;
    setState(() {
      _patients = all.where((p) =>
        p.patientId != widget.primaryPatientId &&
        !widget.excludedPatientIds.contains(p.patientId)
      ).toList();
      _loadingPatients = false;
    });
  }

  double get _selectedTotal =>
    _selectedTests.values.fold(0.0, (s, t) => s + t.finalPrice);

  bool get _needsPrescriptionStep =>
    _selectedTests.values.any((t) => t.docRequired);

  void _showPresSourcePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CustomerThemeScope(
        child: CxSheetFrame(
          title: 'Upload Prescription',
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _PresSourceTile(Icons.camera_alt_rounded, 'Take Photo',
                'Open camera to capture prescription',
                () { Navigator.pop(context); _pickPres(ImageSource.camera); }),
            const SizedBox(height: CxSpace.md),
            _PresSourceTile(Icons.photo_library_outlined, 'Choose from Gallery',
                'Select one or more images',
                () { Navigator.pop(context); _pickPres(ImageSource.gallery); }),
          ]),
        ),
      ),
    );
  }

  Future<void> _pickPres(ImageSource source) async {
    if (_isPicking || _prescriptionBytes.length >= 5) return;
    setState(() => _isPicking = true);
    try {
      if (source == ImageSource.camera) {
        final img = await _picker.pickImage(source: ImageSource.camera, imageQuality: 85);
        if (img != null) {
          final bytes = await img.readAsBytes();
          setState(() => _prescriptionBytes.add(bytes));
        }
      } else {
        final images = await _picker.pickMultiImage(imageQuality: 80);
        if (images.isNotEmpty) {
          final toAdd = images.take(5 - _prescriptionBytes.length);
          final bytes = await Future.wait(toAdd.map((f) => f.readAsBytes()));
          setState(() => _prescriptionBytes.addAll(bytes));
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _isPicking = false);
  }

  void _viewPresImage(int index) {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => _BytesViewerPage(images: List.from(_prescriptionBytes), initialIndex: index),
    ));
  }

  Future<void> _saveNewMember() async {
    final name   = _newNameCtrl.text.trim();
    final mobile = _newMobileCtrl.text.trim();
    final nameErr   = name.isEmpty   ? 'Name is required' : null;
    final mobileErr = mobile.isEmpty ? 'Mobile number is required'
                    : mobile.length != 10 ? 'Enter a valid 10-digit mobile number' : null;
    final dobErr    = _newDob == null ? 'Date of birth is required' : null;
    final genderErr = _newGender == null ? 'Please select a gender' : null;
    if (nameErr != null || mobileErr != null || dobErr != null || genderErr != null) {
      setState(() { _nameError = nameErr; _mobileError = mobileErr; _dobError = dobErr; _genderError = genderErr; });
      return;
    }
    final dobStr = '${_newDob!.year}-${_newDob!.month.toString().padLeft(2, '0')}-${_newDob!.day.toString().padLeft(2, '0')}';
    setState(() => _savingNewMember = true);
    try {
      final result = await ApiService.savePatient({
        'name':          name,
        'mobile':        mobile,
        'gender':        _newGender!,
        'date_of_birth': dobStr,
        'location':      '-',
        'address':       '-',
        if (_newRelation != null) 'relation': _newRelation,
      });
      if (!mounted) return;
      if (result['success'] == true) {
        _newNameCtrl.clear();
        _newMobileCtrl.clear();
        setState(() {
          _newDob             = null;
          _newGender          = null;
          _newRelation        = null;
          _showNewMemberForm  = false;
          _savingNewMember    = false;
        });
        await _loadPatients();
        widget.onMemberAdded?.call();
        // Auto-select the newly created member (last in list after reload)
        if (mounted && _patients.isNotEmpty) {
          setState(() => _selected = _patients.firstWhere(
            (p) => p.name.toLowerCase() == name.toLowerCase(),
            orElse: () => _patients.last,
          ));
        }
      } else {
        if (mounted) setState(() => _savingNewMember = false);
        if (mounted) AppMessages.error(context, result['message']?.toString() ?? 'Could not save member');
      }
    } catch (_) {
      if (mounted) setState(() => _savingNewMember = false);
    }
  }

  void _confirm() {
    if (_selected == null || _selectedTestIds.isEmpty) return;
    final tests = _selectedTests.values.toList();
    widget.onAdd(_FamilyMember(
      patient: _selected!,
      tests: tests,
      prescriptionBytes: List.from(_prescriptionBytes),
    ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bottom = mq.padding.bottom;
    return CustomerThemeScope(
      // Keeps the sheet (and its button) above the on-screen keyboard.
      child: Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, scroll) => Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: CxSize.sheetMaxWidth),
        child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: CxRadius.sheetTop,
        ),
        child: Column(children: [
          // Handle
          const CxSheetHandleBar(),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(CxSpace.sm, 0, CxSpace.lg, 0),
            child: Row(children: [
              if (_step >= 1)
                IconButton(
                  tooltip: 'Back',
                  onPressed: () => setState(() {
                    if (_step == 2) {
                      _step = 1;
                      _prescriptionBytes.clear();
                    } else {
                      _step = 0;
                      _selectedTests.clear();
                    }
                  }),
                  icon: const Icon(Icons.arrow_back_rounded, size: 22, color: AppColors.textPrimary),
                )
              else
                const SizedBox(width: CxSpace.md),
              Expanded(
                child: Text(
                  _step == 0
                      ? 'Select Family Member'
                      : _step == 1
                          ? 'Select Tests for ${_selected!.name}'
                          : 'Upload Prescription',
                  style: CxText.sheetTitle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
          const SizedBox(height: CxSpace.sm),
          const Divider(height: 1),
          // Body
          Expanded(child: _step == 0
              ? _buildPatientStep(scroll)
              : _step == 1
                  ? _buildTestStep(scroll)
                  : _buildPrescriptionStep(scroll)),
          // Button
          Container(
            padding: EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.md, CxSpace.gutter,
                (mq.viewInsets.bottom > 0 ? 0 : bottom) + CxSpace.md),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: CxColors.border)),
            ),
            child: CxButton(
                onPressed: _step == 0
                    ? (_selected == null ? null : () => setState(() => _step = 1))
                    : _step == 1
                        ? (_selectedTestIds.isEmpty
                            ? null
                            : () { _needsPrescriptionStep ? setState(() => _step = 2) : _confirm(); })
                        : (_prescriptionBytes.isEmpty ? null : _confirm),
                label: _step == 0
                      ? 'Next: Select Tests'
                      : _step == 1
                          ? (_selectedTestIds.isEmpty
                              ? 'Select at least one test'
                              : (_needsPrescriptionStep ? 'Next: Upload Prescription' : 'Add to Booking · ₹${_selectedTotal.toInt()}'))
                          : (_prescriptionBytes.isEmpty
                              ? 'Upload prescription to continue'
                              : 'Add to Booking · ₹${_selectedTotal.toInt()}'),
            ),
          ),
        ]),
      ),
        ),
      ),
      ),
      ),
    );
  }

  Widget _buildPatientStep(ScrollController scroll) {
    if (_loadingPatients) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(32),
        child: CircularProgressIndicator(color: AppColors.brandGreen, strokeWidth: 2),
      ));
    }

    // ── Inline create form ───────────────────────────────────
    if (_showNewMemberForm) {
      return SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Name
          RichText(text: const TextSpan(style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary), children: [
            TextSpan(text: 'Name'),
            TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ])),
          const SizedBox(height: 6),
          TextField(
            controller: _newNameCtrl,
            textCapitalization: TextCapitalization.words,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z ]'))],
            onChanged: (_) { if (_nameError != null) setState(() => _nameError = null); },
            decoration: _inputDecor('Full name').copyWith(
              errorText: _nameError,
              errorStyle: const TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(height: 14),
          // Mobile
          RichText(text: const TextSpan(style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary), children: [
            TextSpan(text: 'Mobile'),
            TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ])),
          const SizedBox(height: 6),
          TextField(
            controller: _newMobileCtrl,
            keyboardType: TextInputType.phone,
            maxLength: 10,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) { if (_mobileError != null) setState(() => _mobileError = null); },
            decoration: _inputDecor('10-digit mobile number').copyWith(
              counterText: '',
              errorText: _mobileError,
              errorStyle: const TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(height: 14),
          // Date of Birth
          RichText(text: const TextSpan(style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary), children: [
            TextSpan(text: 'Date of Birth'),
            TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ])),
          const SizedBox(height: 6),
          Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: CxRadius.mdAll,
              side: BorderSide(color: _dobError != null ? CxColors.error : CxColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _newDob ?? DateTime(2000),
                firstDate: DateTime(1900),
                lastDate: DateTime.now(),
              );
              if (picked != null) setState(() { _newDob = picked; _dobError = null; });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
              child: Row(children: [
                Icon(Icons.calendar_today_outlined, size: 18,
                    color: _dobError != null ? CxColors.error : CxColors.textHint),
                const SizedBox(width: 10),
                Text(
                  _newDob != null
                      ? '${_newDob!.day.toString().padLeft(2,'0')}/${_newDob!.month.toString().padLeft(2,'0')}/${_newDob!.year}'
                      : 'DD/MM/YYYY',
                  style: TextStyle(
                    fontSize: 14,
                    color: _newDob != null ? AppColors.textPrimary : AppColors.textHint,
                  ),
                ),
              ]),
            ),
            ),
          ),
          if (_dobError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(_dobError!, style: const TextStyle(fontSize: 12, color: CxColors.error)),
            ),
          const SizedBox(height: 14),
          // Gender
          RichText(text: const TextSpan(style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary), children: [
            TextSpan(text: 'Gender'),
            TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ])),
          const SizedBox(height: 6),
          Row(children: _genders.map((g) {
            final sel = _newGender == g;
            return Expanded(child: Padding(
              padding: EdgeInsets.only(right: g != _genders.last ? 8 : 0),
              child: _ChoicePill(
                label: g,
                selected: sel,
                onTap: () => setState(() { _newGender = g; _genderError = null; }),
              ),
            ));
          }).toList()),
          if (_genderError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Text(_genderError!, style: const TextStyle(fontSize: 12, color: CxColors.error)),
            ),
          const SizedBox(height: 14),
          // Relation
          const Text('Relation (optional)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _newRelation,
            hint: const Text('Select relation', style: TextStyle(color: AppColors.textHint, fontSize: 13)),
            decoration: _inputDecor(null),
            items: _relations.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
            onChanged: (v) => setState(() => _newRelation = v),
          ),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: CxButton.secondary(
              onPressed: () => setState(() { _showNewMemberForm = false; _newNameCtrl.clear(); _newMobileCtrl.clear(); _newDob = null; _newGender = null; _newRelation = null; _nameError = null; _mobileError = null; _dobError = null; _genderError = null; }),
              label: 'Cancel',
            )),
            const SizedBox(width: CxSpace.md),
            Expanded(child: CxButton(
              onPressed: _savingNewMember ? null : _saveNewMember,
              loading: _savingNewMember,
              label: 'Save Member',
            )),
          ]),
        ]),
      );
    }

    // ── Patient list ─────────────────────────────────────────
    // One bordered list of compact rows, then a small "Add new member" link.
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(CxSpace.gutter, 10, CxSpace.gutter, CxSpace.md),
      children: [
        if (_patients.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: CxRadius.lgAll,
              border: Border.all(color: CxColors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (var i = 0; i < _patients.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: CxColors.border),
                _memberRow(_patients[i]),
              ],
            ]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _showNewMemberForm = true),
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
            label: const Text('Add new member'),
            style: TextButton.styleFrom(
              foregroundColor: CxColors.brand,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(48, 44),
              textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ],
    );
  }

  // One family member row (~48px): avatar, name · relation, radio.
  Widget _memberRow(PatientModel p) {
    final isSel = _selected?.patientId == p.patientId;
    final name = p.name;
    final relation = p.relation;
    return Semantics(
      button: true,
      selected: isSel,
      child: Material(
        color: isSel ? CxColors.brandSurface : Colors.white,
        child: InkWell(
          onTap: () => setState(() => _selected = p),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                  color: isSel ? AppColors.brandGreen : AppColors.brandGreenSurface,
                  shape: BoxShape.circle,
                ),
                child: Center(child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                      color: isSel ? Colors.white : AppColors.brandGreen),
                )),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: name,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                    if (relation != null && relation.isNotEmpty)
                      TextSpan(text: ' · $relation',
                          style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                isSel ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                color: isSel ? CxColors.brand : CxColors.textHint,
                size: 22,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // Borders, focus colour and padding come from the customer theme.
  InputDecoration _inputDecor(String? hint) => InputDecoration(
    hintText: hint,
  );

  Widget _buildTestStep(ScrollController scroll) {
    final tests = _pager.items;
    Widget list;
    if (_pager.loading) {
      list = const CxLoading(label: 'Loading tests…');
    } else if (tests.isEmpty) {
      list = _pager.failed
          ? CxErrorState(
              title: 'Couldn\'t load tests',
              retryLabel: 'Try again',
              onRetry: _pager.refresh,
            )
          : CxEmptyState(
              icon: Icons.search_off_rounded,
              title: _pager.search.trim().isEmpty ? 'No tests available.' : 'No tests found',
            );
    } else {
      // One extra row at the end: the next page's spinner, or "Show more"
      // when a page failed or the list is too short to scroll.
      final extraRow = _pager.hasMore ? 1 : 0;
      list = NotificationListener<ScrollNotification>(
        onNotification: _pager.onScroll,
        child: ListView.separated(
          controller: scroll,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          itemCount: tests.length + extraRow,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            if (i >= tests.length) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: _pager.loadingMore
                      ? const SizedBox(width: 22, height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen))
                      : CxButton.secondary(
                          onPressed: _pager.loadMore,
                          icon: Icons.expand_more_rounded,
                          compact: true,
                          label: 'Show more (${_pager.total - tests.length} more)',
                        ),
                ),
              );
            }
            return _buildTestTile(tests[i]);
          },
        ),
      );
    }

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(CxSpace.gutter, 10, CxSpace.gutter, 2),
        child: TextField(
          controller: _testSearchCtrl,
          textInputAction: TextInputAction.search,
          style: CxText.body,
          decoration: const InputDecoration(
            hintText: 'Search tests & packages…',
            prefixIcon: Icon(Icons.search_rounded, size: 20, color: CxColors.textHint),
            prefixIconConstraints: BoxConstraints(minWidth: 40, minHeight: 40),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ),
      if (_selectedTests.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.sm, CxSpace.gutter, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: CxChip(
              label: '${_selectedTests.length} selected · ₹${_selectedTotal.toInt()}',
              icon: Icons.check_circle_outline_rounded,
              tone: CxTone.brand,
            ),
          ),
        ),
      Expanded(child: list),
    ]);
  }

  // Compact pick row (~44px): checkbox, name (+ Package tag), price.
  Widget _buildTestTile(TestModel t) {
    final checked = _selectedTests.containsKey(t.id);
    void toggle() => setState(() {
          if (checked) {
            _selectedTests.remove(t.id);
          } else {
            _selectedTests[t.id] = t;
          }
        });
    return Semantics(
      button: true,
      selected: checked,
      child: Material(
        color: checked ? CxColors.brandSurface : Colors.white,
        child: InkWell(
          onTap: toggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
              child: Row(children: [
                SizedBox(
                  width: 40,
                  child: Checkbox(
                    value: checked,
                    onChanged: (_) => toggle(),
                    activeColor: AppColors.brandGreen,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.name, style: CxText.body.copyWith(fontWeight: FontWeight.w600, height: 1.3)),
                    if (t.type == 'package')
                      const Text('Package',
                          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
                  ]),
                ),
                const SizedBox(width: 8),
                Text('₹${t.finalPrice.toInt()}',
                    style: CxText.body.copyWith(fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrescriptionStep(ScrollController scroll) {
    return SingleChildScrollView(
      controller: scroll,
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Mandatory banner
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: const BoxDecoration(
            color: CxColors.warningSurface,
            borderRadius: CxRadius.mdAll,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.description_outlined, size: 18, color: CxColors.warning),
            const SizedBox(width: 10),
            const Expanded(child: Text(
              'A valid prescription is required for the selected test(s). Please upload before proceeding.',
              style: TextStyle(fontSize: 13, color: CxColors.textPrimary, height: 1.4),
            )),
            if (_prescriptionBytes.isNotEmpty)
              Text('${_prescriptionBytes.length}/5',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: CxColors.warning)),
          ]),
        ),
        const SizedBox(height: 14),
        // Thumbnail horizontal strip
        SizedBox(
          height: 104,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(top: 8),
            children: [
              ..._prescriptionBytes.asMap().entries.map((e) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Stack(clipBehavior: Clip.none, children: [
                  GestureDetector(
                    onTap: () => _viewPresImage(e.key),
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
                  Positioned(top: -8, right: -8, child: Semantics(
                    button: true,
                    label: 'Remove image',
                    child: GestureDetector(
                    onTap: () => setState(() => _prescriptionBytes.removeAt(e.key)),
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: CxColors.error,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.close_rounded, size: 14, color: Colors.white),
                    ),
                  ))),
                ]),
              )),
              if (_prescriptionBytes.length < 5)
                Material(
                  color: CxColors.brandSurface,
                  shape: RoundedRectangleBorder(
                    borderRadius: CxRadius.mdAll,
                    side: BorderSide(color: CxColors.brand.withValues(alpha: 0.5), width: 1.5),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                  onTap: _isPicking ? null : _showPresSourcePicker,
                  child: SizedBox(
                    width: 88, height: 88,
                    child: _isPicking
                        ? const Center(child: SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)))
                        : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(
                              _prescriptionBytes.isEmpty ? Icons.upload_file_outlined : Icons.add_photo_alternate_outlined,
                              size: 28,
                              color: CxColors.brand,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _prescriptionBytes.isEmpty ? 'Upload' : 'Add more',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: CxColors.brand,
                              ),
                            ),
                          ]),
                  ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _prescriptionBytes.isEmpty
              ? 'Tap the tile above to upload via camera or gallery'
              : '${_prescriptionBytes.length} image${_prescriptionBytes.length == 1 ? '' : 's'} uploaded · tap to view',
          style: CxText.caption,
        ),
      ]),
    );
  }
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

// ─── Full-screen viewer for in-memory Uint8List images ────────────────────────

class _BytesViewerPage extends StatefulWidget {
  final List<Uint8List> images;
  final int initialIndex;

  const _BytesViewerPage({required this.images, required this.initialIndex});

  @override
  State<_BytesViewerPage> createState() => _BytesViewerPageState();
}

class _BytesViewerPageState extends State<_BytesViewerPage> {
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
