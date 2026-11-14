import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/razorpay_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/models/technician_booking.dart';
import 'package:microlab/models.dart' show BranchModel;
import 'package:microlab/utils/app_messages.dart';
import 'technician_active_job_screen.dart';
// ₹ amount for display — whole rupees as "1229", and paise kept as
// "1229.50" (never cut off, so a due like ₹0.50 doesn't show as ₹0).
String _inr(num v) {
  final r = (v * 100).round() / 100;
  return r == r.truncateToDouble() ? r.toInt().toString() : r.toStringAsFixed(2);
}

// Popped by TechnicianBookingDetailScreen (see _exitScreen) when the
// technician leaves mid-journey from an instance that was itself opened from
// the live map/active-job screen. Every intermediate layer that pushed
// TechnicianActiveJobScreen or TechnicianBookingDetailScreen — in either
// file — must check for this exact value in its own `.then()` and, if seen,
// immediately pop itself with the same value rather than running its normal
// completion handling. That cascades the exit signal upward through however
// many layers actually exist, ending at the Dashboard's own top-level
// `.then()`, which doesn't recognise this value and simply treats it as "not
// completed" — stopping the cascade exactly where it should. A fixed
// "pop N times" shortcut can't work here because the real distance back to
// the Dashboard varies: TechnicianActiveJobScreen can be reached either
// directly from the Dashboard, or from inside Manage Booking itself.
const kExitToDashboard = 'exit_to_dashboard';

// ─── Prescription doc model ──────────────────────────────────────────────────

class _TechPresDoc {
  final int? docId;         // null while uploading; set once saved to server
  final Uint8List? bytes;   // local bytes present only while uploading
  final String? url;        // remote URL set after upload completes
  final String fileName;
  final DateTime uploadedAt;
  bool isUploading;
  String docStatus;
  // Which patient this document belongs to — the booking's own primary
  // patient, or a family member's, when this visit has more than one.
  // Populated from ip_booking_documents.patient_id on fetch, or defaults to
  // the primary patient for docs the technician uploads from this screen.
  final int? patientId;

  _TechPresDoc({
    this.docId,
    this.bytes,
    this.url,
    required this.fileName,
    required this.uploadedAt,
    this.isUploading = false,
    this.docStatus = 'pending_review',
    this.patientId,
  });

  bool get isVerified => docStatus == 'verified';
}

// (Test catalogue is now loaded from the server — see _loadItems)

// ─── Journey steps ────────────────────────────────────────────────────────────

// Parts of the sample-collection photo flow, shown on the photo box.
enum _ProofStep { camera, uploading, saving }

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
  // True when this screen was pushed on top of the live map/active-job
  // screen (technician_active_job_screen.dart) rather than directly from the
  // Dashboard. Lets the exit actions (back / Save Changes) skip past that
  // screen straight to the Dashboard when the technician leaves mid-journey
  // — but only then: reaching full completion (Handed to Lab) must still pop
  // just this screen, so the active-job screen's own completion choreography
  // (brief "handed over" status, haptic, delayed self-pop) keeps running.
  final bool cameFromActiveJob;
  const TechnicianBookingDetailScreen({
    super.key,
    required this.booking,
    this.onNewBooking,
    this.cameFromActiveJob = false,
  });

  @override
  State<TechnicianBookingDetailScreen> createState() =>
      _TechnicianBookingDetailScreenState();
}

class _TechnicianBookingDetailScreenState
    extends State<TechnicianBookingDetailScreen> with WidgetsBindingObserver {

  late String _currentStatus;
  List<Map<String, String>> _selectedTests = [];
  // IDs of tests that existed in the booking at screen open — used to block
  // deletion of paid original tests without affecting newly added ones.
  Set<String> _originalItemIds = {};
  bool _itemsLoading = true;
  List<Map<String, String>> _catalogueItems = [];
  bool _showAddTest = false;
  String _searchQuery = '';
  // "Add Test / Package" multi-select: ticked catalogue ids, added together
  // by _addSelectedTests.
  final Set<String> _pendingTestIds = {};
  bool _addingTests = false;

  // Hand Over to Lab — branch list for the "received branch/lab" picker,
  // fetched lazily (only when that dialog is actually about to open, not on
  // screen load) since it's only needed at the very end of the journey.
  List<BranchModel> _labBranches = [];

  // Document — multi-image upload
  final List<_TechPresDoc> _docUploads = [];
  bool _docIsPicking = false;
  // Which booking's photo is currently being captured/uploaded, if any —
  // only one camera capture can be in flight at a time. Keyed by BOOKING id,
  // not patient id: every patient on a visit has their own booking id and
  // it is always known, while the primary patient's patient id can be
  // missing (e.g. this screen opened from the live map). Comparing a null
  // patient id against "nothing capturing" (null == null) made that box
  // spin on "Opening camera…" forever with its tap disabled.
  int? _capturingProofBookingId;
  // Booking whose photo is being removed (✕ on the thumbnail), if any.
  int? _removingProofBookingId;
  // Which part of the capture is running — drives the box's label
  // ("Opening camera…" / "Uploading photo…" / "Saving photo…").
  _ProofStep _proofStep = _ProofStep.camera;
  // Bumped whenever a capture starts or is cancelled; a camera result or
  // upload that finishes for an older value is ignored.
  int _proofCaptureToken = 0;
  // Sample-collection proof photo — one per patient on this visit (primary +
  // family members), keyed by that patient's own booking_id (the photo is
  // stored per booking server-side, see ip_booking_documents). Never a
  // single shared value — otherwise the last patient photographed would
  // overwrite every other patient's display.
  final Map<int, String?> _proofUrlByBookingId = {};
  bool _collectionProofLoading = true;
  bool _docVerified  = false;
  bool _docsLoading  = true;
  // Whether the PRIMARY patient's selected test/package requires a prescription.
  // Initialized from widget.booking.docRequired; recalculated once items load.
  late bool _docRequired;
  // Same requirement, tracked per patient on this visit (primary + family
  // members) — keyed by patient_id. Populated for the primary from the same
  // items load as _docRequired, and for each family member by fetching their
  // own booking's items (see _loadFamilyDocRequirements). A family member's
  // requirement is otherwise invisible: their tests live on a different
  // booking_id than this screen's own, so _docRequired alone never sees it.
  final Map<int, bool> _patientDocRequired = {};
  bool get _anyDocRequired => _patientDocRequired.values.any((v) => v);
  static const int _docMaxFiles = 5;
  final ImagePicker _picker = ImagePicker();

  // Payment — live values fetched from server in initState, overriding immutable widget.booking fields
  bool _isProcessingPayment = false;
  // Family visit with 2+ members still owing: how the customer chose to pay
  // — null (not asked yet), 'combined' (one payment for everyone) or
  // 'individual' (each member separately, in any order). See _startPayment.
  String? _familyPayMode;
  bool _isReloading = false;
  double _sessionPaymentCollected = 0.0;
  late String _livePaymentStatus;  // refreshed from server; starts from widget value
  late double _liveAmountPaid;     // refreshed from server; starts from widget value
  // Fixed at booking creation (tests + service charge at that time) — used to
  // back out the true service charge amount via _serviceCharge below.
  double _totalAmount = 0.0;
  // Additional charge the technician entered on site (amount + reason) —
  // already inside _totalAmount on the server, so it is backed out of
  // _serviceCharge and added back as its own line in _amountDue.
  double _additionalCharge = 0.0;
  String? _additionalChargeReason;
  bool _savingAdditionalCharge = false;
  // Charge packages on this visit, each {chargeId, bookingId, productId, name,
  // testCode, price, reason}, and the visit's service charge product name —
  // from _loadAdditionalCharges.
  List<Map<String, dynamic>> _chargePackages = [];
  String? _serviceChargeProductName;
  // Service charge collected on the spot (server: services/serviceCharge.js):
  // {status, productName, oneWayKm, roundTripKm, amount}. status null = booked
  // before this change (booking-time charge, shown as before); 'pending' /
  // 'calculated' = shown after arrival; 'applied' = in the bill;
  // 'no_product' = the technician adds a charge package.
  Map<String, dynamic>? _serviceChargeInfo;
  // Products for the "Add charge package" sheet, loaded on first use.
  List<Map<String, dynamic>> _chargeCatalogue = [];

  // Visit members linked to this booking (refreshed after each add)
  List<Map<String, dynamic>> _linkedPatients = [];
  // Each family member's own tests/packages + collection checklist state,
  // keyed by their own booking_id (never this screen's own booking_id) —
  // same Map<String,String> row shape as _selectedTests, populated by
  // _loadFamilyDocRequirements alongside its existing doc-required check.
  final Map<int, List<Map<String, String>>> _familyItems = {};
  // Tracks refund owed per family booking when a paid test is removed and
  // amount_due would go below zero — the overshoot is the refund amount.
  final Map<int, double> _familyPendingRefund = {};

  // OTP
  final List<TextEditingController> _otpControllers =
      List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _otpFocusNodes =
      List.generate(4, (_) => FocusNode());
  bool _isVerifyingOtp  = false;
  // Why nothing was paid, when the technician verifies the OTP without any
  // payment toward the visit — sent with the OTP and saved by the server like
  // a partial-payment reason.
  String? _noPaymentReason;
  bool _isResendingOtp  = false;
  bool _otpError        = false;
  String _otpErrorText  = 'Invalid OTP. Please try again.';

  // ── Computed ──────────────────────────────────────────────

  double get _testsTotal =>
      _selectedTests.fold(0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0));

  // Sum of only the tests that existed when the booking was first created —
  // used (not _testsTotal, which includes tests added later at the door) to
  // back out the true, stable service charge amount below.
  double get _originalItemsTotal => _selectedTests
      .where((t) => _originalItemIds.contains(t['id']))
      .fold(0.0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0));

  // total_amount is fixed at booking creation (original tests + service
  // charge). Subtracting the original tests' total isolates the service
  // charge — stable regardless of tests added/removed after that point.
  double get _serviceCharge {
    final sc = _totalAmount - _originalItemsTotal - _additionalCharge;
    return sc < 0.0 ? 0.0 : sc;
  }

  double get _amountDue {
    final due = (_testsTotal + _serviceCharge + _additionalCharge) - (_liveAmountPaid + _sessionPaymentCollected);
    // Rounded to paise so float leftovers (e.g. 0.0000001) never count as due.
    final r = (due * 100).round() / 100;
    return r < 0.0 ? 0.0 : r;
  }

  // Additional charges can be entered on site — from Destination Reached up
  // to Sample Collected (same window the server allows). From OTP Verified
  // the visit is finalised.
  bool get _canEditAdditionalCharge => const [
        'Destination Reached', 'Collection Started', 'Sample Collected',
      ].contains(_currentStatus);

  bool get _paymentDone => _amountDue <= 0.0;

  // All patients on this visit — the booking's own primary patient plus any
  // family members added at booking time. Drives the per-patient prescription
  // grouping so each document renders only under its actual patient, and a
  // patient with none shows "No Prescription Uploaded" instead of another
  // member's upload.
  List<Map<String, dynamic>> get _visitPatients => [
        {
          'id':        widget.booking.patientId,
          'name':      widget.booking.customerName,
          'isPrimary': true,
          'bookingId': int.tryParse(widget.booking.id),
        },
        ..._linkedPatients.map((p) => {
              'id':        (p['patient_id'] as num?)?.toInt(),
              'name':      (p['patient_name'] as String? ?? 'Family Member').toUpperCase(),
              'isPrimary': false,
              'bookingId': (p['booking_id'] as num?)?.toInt(),
            }),
      ];

  // True once any payment — full or partial — has been recorded for this
  // visit. The completion gate only requires SOME payment to have been
  // collected, not the full amount: any remaining balance is settled later
  // (e.g. at report delivery), so it must not block finishing this visit.
  bool get _paymentInitiated =>
      _paymentDone || _liveAmountPaid > 0 || _sessionPaymentCollected > 0;

  // Gate for Enter OTP / Handed to Lab on a visit (single or family): open
  // once ANY payment has been recorded toward the visit — the main booking or
  // any family member, full or partial, in single or individual payment mode.
  // Remaining balances are collected later, the same rule as a single
  // booking. (Previously every family member had to have paid something,
  // so a partial single payment that only reached the main patient kept the
  // OTP step locked.)
  bool get _visitPaymentStarted =>
      _paymentInitiated ||
      _linkedPatients.any((c) {
        final status = c['payment_status'] as String?;
        return status == 'paid' || status == 'partial';
      });

  int get _currentStepIndex =>
      _journeySteps.indexWhere((s) => s.status == _currentStatus);

  bool get _isCompleted => _currentStatus == 'Handed to Lab';
  // Visit is finalized after OTP Verified — no more edits allowed from this point.
  bool get _isFinalized => _currentStatus == 'OTP Verified' || _currentStatus == 'Handed to Lab';
  bool get _canAdvance  => !_isCompleted;
  // Collection checklist becomes visible once the journey has reached
  // "Collection Started" — purely a display gate, does not affect whether
  // "Sample Collected" can be tapped (that stays independent of checklist state).
  bool get _showCollectionChecklist {
    final started = _journeySteps.indexWhere((s) => s.status == 'Collection Started');
    return started != -1 && _currentStepIndex >= started;
  }

  String? get _nextStatus {
    final idx = _currentStepIndex;
    if (idx < 0 || idx >= _journeySteps.length - 1) return null;
    return _journeySteps[idx + 1].status;
  }

  // The one action available right now — used by BOTH the button in the
  // Journey Status card and the bottom bar button, so the two always show
  // the same name and do the same thing. null when there is nothing to do.
  //   • Journey Started → Resume (reopens the live map)
  //   • otherwise       → the next step (OTP step reads "Enter OTP")
  //   • Handed to Lab   → no step left (the bottom button shows "Done")
  ({String label, VoidCallback onTap})? get _currentAction {
    if (!_canAdvance) return null;
    if (_currentStatus == 'Journey Started') {
      return (label: 'Resume Journey', onTap: _resumeJourney);
    }
    final idx = _currentStepIndex;
    if (_nextStatus == null || idx < 0) return null;
    final nextLabel = _journeySteps[idx + 1].label;
    return (
      label: nextLabel == 'OTP Verified' ? 'Enter OTP' : nextLabel,
      onTap: _advanceStatus,
    );
  }

  @override
  void initState() {
    super.initState();
    _currentStatus        = widget.booking.status;
    _livePaymentStatus    = widget.booking.paymentStatus;
    _liveAmountPaid       = widget.booking.amountPaid;
    _docRequired          = widget.booking.docRequired;
    if (widget.booking.patientId != null) {
      _patientDocRequired[widget.booking.patientId!] = _docRequired;
    }
    WidgetsBinding.instance.addObserver(this);
    _loadItems();
    _loadDocs();
    _loadCollectionProof();
    _loadLinkedPatients();
    _refreshPaymentInfo();
    _loadAdditionalCharges();
    // A collection photo taken just before Android closed the app (see
    // _recoverLostProofPhoto) is uploaded now instead of being lost.
    _recoverLostProofPhoto();
  }

  // Coming back from the camera app. Normally the photo arrives right
  // away; if it hasn't a few seconds later, Android closed our screen while
  // the camera was open and the result went missing — recover it instead of
  // leaving "Opening camera…" spinning.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_capturingProofBookingId == null || _proofStep != _ProofStep.camera) return;
    final token = _proofCaptureToken;
    Future.delayed(const Duration(seconds: 5), () {
      if (!mounted || token != _proofCaptureToken) return;
      if (_capturingProofBookingId == null || _proofStep != _ProofStep.camera) return;
      debugPrint('[CollectionProof] no camera result 5s after resume — trying lost-data recovery');
      _recoverLostProofPhoto(fromResume: true);
    });
  }

  // Every booking on this visit that can carry an additional charge — this
  // screen's own booking plus family members with their own booking.
  List<({int bookingId, String name, double amount, String? reason, bool isMain})>
      get _additionalChargeTargets {
    final mainId = int.tryParse(widget.booking.id);
    return [
      if (mainId != null)
        (bookingId: mainId, name: widget.booking.customerName,
         amount: _additionalCharge, reason: _additionalChargeReason, isMain: true),
      for (final p in _linkedPatients)
        if ((p['booking_id'] as num?) != null)
          (bookingId: (p['booking_id'] as num).toInt(),
           name: p['patient_name'] as String? ?? 'Visit Member',
           amount: double.tryParse(p['additional_charge_amount']?.toString() ?? '') ?? 0.0,
           reason: p['additional_charge_reason'] as String?,
           isMain: false),
    ];
  }

  // Charge packages on this visit and the service charge product name, for
  // the Billing Summary and the charge cards.
  Future<void> _loadAdditionalCharges() async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    if (bookingId == 0) return;
    final data = await ApiService.getAdditionalCharges(bookingId);
    if (!mounted || data == null) return;
    setState(() {
      _chargePackages           = (data['charges'] as List? ?? []).cast<Map<String, dynamic>>();
      _serviceChargeProductName = data['serviceChargeProductName'] as String?;
      _serviceChargeInfo        = data['serviceCharge'] as Map<String, dynamic>?;
    });
  }

  double _packagesTotalFor(int bookingId) => _chargePackages
      .where((c) => (c['bookingId'] as num?)?.toInt() == bookingId)
      .fold(0.0, (s, c) => s + ((c['price'] as num?)?.toDouble() ?? 0.0));

  // The part of a booking's additional charge typed in with an older app
  // version (amount + reason) — what is left after its charge packages.
  double _typedChargeFor(int bookingId, double additionalCharge) {
    final typed = ((additionalCharge - _packagesTotalFor(bookingId)) * 100).round() / 100;
    return typed > 0 ? typed : 0.0;
  }

  // New totals from an add/remove reply: this screen's own booking is
  // updated in place, a family member's by reloading the visit members.
  Future<void> _applyChargeResult(int bookingId, Map<String, dynamic> res) async {
    if (bookingId == int.tryParse(widget.booking.id)) {
      setState(() {
        _totalAmount       = double.tryParse(res['totalAmount']?.toString() ?? '') ?? _totalAmount;
        _additionalCharge  = double.tryParse(res['additionalChargeAmount']?.toString() ?? '') ?? _additionalCharge;
        _livePaymentStatus = res['paymentStatus'] as String? ?? _livePaymentStatus;
      });
    } else {
      await _loadLinkedPatients();
    }
    await _loadAdditionalCharges();
  }

  // "Add charge package": the technician picks one or more products (prices
  // set by the server) with an optional reason. Goes on the main patient's
  // booking, like the additional charge before it.
  Future<void> _addChargePackages() async {
    final mainId = int.tryParse(widget.booking.id);
    if (mainId == null) return;
    if (_chargeCatalogue.isEmpty) {
      setState(() => _savingAdditionalCharge = true);
      final packages = await ApiService.getChargePackages();
      if (!mounted) return;
      setState(() {
        _chargeCatalogue        = packages;
        _savingAdditionalCharge = false;
      });
      if (packages.isEmpty) {
        AppMessages.error(context, 'We couldn\'t load the packages. Please try again.');
        return;
      }
    }

    final choice = await showModalBottomSheet<({List<int> productIds, String reason})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ChargePackageSheet(packages: _chargeCatalogue, patientName: widget.booking.customerName),
    );
    if (choice == null || !mounted) return;

    setState(() => _savingAdditionalCharge = true);
    final res = await ApiService.addAdditionalCharges(
      bookingId:  mainId,
      productIds: choice.productIds,
      reason:     choice.reason,
    );
    if (!mounted) return;
    setState(() => _savingAdditionalCharge = false);
    if (res['success'] != true) {
      AppMessages.error(context, AppMessages.serverMessage(res['message'],
          fallback: 'We couldn\'t add the charge package. Please try again.'));
      // A package that went inactive meanwhile: fetch a fresh list next time.
      _chargeCatalogue = [];
      return;
    }
    await _applyChargeResult(mainId, res);
    if (!mounted) return;
    AppMessages.success(context, choice.productIds.length == 1
        ? 'Charge package added'
        : '${choice.productIds.length} charge packages added');
  }

  Future<bool> _confirmRemoveCharge(String name, double amount) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove charge?'),
        content: Text('$name · ₹${_inr(amount)} will be taken off the bill.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _removeChargePackage(Map<String, dynamic> charge) async {
    final bookingId = (charge['bookingId'] as num?)?.toInt();
    final chargeId  = (charge['chargeId'] as num?)?.toInt();
    if (bookingId == null || chargeId == null) return;
    final name  = charge['name'] as String? ?? 'Charge package';
    final price = (charge['price'] as num?)?.toDouble() ?? 0.0;
    if (!await _confirmRemoveCharge(name, price) || !mounted) return;

    setState(() => _savingAdditionalCharge = true);
    final res = await ApiService.removeAdditionalCharge(bookingId: bookingId, chargeId: chargeId);
    if (!mounted) return;
    setState(() => _savingAdditionalCharge = false);
    if (res['success'] != true) {
      AppMessages.error(context, AppMessages.serverMessage(res['message'],
          fallback: 'We couldn\'t remove the charge. Please try again.'));
      await _loadAdditionalCharges();
      return;
    }
    await _applyChargeResult(bookingId, res);
    if (!mounted) return;
    AppMessages.success(context, '$name removed');
  }

  // Removes a charge typed in with an older app version (amount 0 clears it).
  Future<void> _removeTypedCharge(int bookingId, double amount) async {
    if (!await _confirmRemoveCharge('Additional charge', amount) || !mounted) return;
    setState(() => _savingAdditionalCharge = true);
    final res = await ApiService.setAdditionalCharge(bookingId: bookingId, amount: 0, reason: '');
    if (!mounted) return;
    setState(() => _savingAdditionalCharge = false);
    if (res['success'] != true) {
      AppMessages.error(context, AppMessages.serverMessage(res['message'],
          fallback: 'We couldn\'t remove the charge. Please try again.'));
      return;
    }
    if (bookingId == int.tryParse(widget.booking.id)) _additionalChargeReason = null;
    await _applyChargeResult(bookingId, res);
    if (!mounted) return;
    AppMessages.success(context, 'Additional charge removed');
  }

  String _memberNameFor(int? bookingId) {
    if (bookingId == int.tryParse(widget.booking.id)) return widget.booking.customerName;
    final p = _linkedPatients.firstWhere(
        (p) => (p['booking_id'] as num?)?.toInt() == bookingId, orElse: () => const {});
    return (p['patient_name'] as String? ?? 'Visit Member').toUpperCase();
  }

  // The service charge line(s) of the Billing Summary. Collected on the spot:
  // shown with its package, km up & down and amount once it is in the bill
  // (after arrival); before that "After arrival"; no package for the km → ask
  // the technician to add one. Bookings from before this change: as before.
  List<Widget> _serviceChargeRows() {
    final info   = _serviceChargeInfo;
    final status = info?['status'] as String?;
    double? km(String key) => (info?[key] as num?)?.toDouble();

    if (status == null) {
      if (_serviceCharge <= 0) return const [];
      return [
        const SizedBox(height: 4),
        _BillRow(_serviceChargeProductName ?? 'Service Charge', '₹${_inr(_serviceCharge)}', sub: true),
      ];
    }
    if (status == 'applied') {
      final roundTrip = km('roundTripKm');
      final oneWay    = km('oneWayKm');
      return [
        const SizedBox(height: 4),
        _BillRow('Service Charge — ${info?['productName'] ?? 'Home Collection'}',
            '₹${_inr((info?['amount'] as num?)?.toDouble() ?? _serviceCharge)}', sub: true),
        if (roundTrip != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${roundTrip.toStringAsFixed(2)} km up & down'
                '${oneWay != null ? ' (${oneWay.toStringAsFixed(2)} km × 2)' : ''}',
                style: const TextStyle(fontSize: 11, color: AppColors.textHint),
              ),
            ),
          ),
      ];
    }
    final arrived = _canEditAdditionalCharge || _isFinalized;
    if (status == 'no_product' && arrived) {
      final roundTrip = km('roundTripKm');
      return [
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF8E1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFFFE082)),
          ),
          child: Text(
            'No service charge package for '
            '${roundTrip != null ? '${roundTrip.toStringAsFixed(2)} km up & down' : 'this distance'}. '
            'Please add one with "Add charge package".',
            style: const TextStyle(fontSize: 12, color: Color(0xFFE65100)),
          ),
        ),
      ];
    }
    return const [
      SizedBox(height: 4),
      _BillRow('Service Charge', 'After arrival', sub: true),
    ];
  }

  // Whole-visit bill, like the customer's checkout Billing Summary: each
  // patient's tests, the service charge (by its package name), every charge
  // added on site, then total, paid and due. Uses the same figures as the
  // payment buttons (_testsTotal, _serviceCharge, _amountDue and each family
  // booking's own total / amount due), so the two always agree.
  Widget _billingSummaryCard() {
    final members = _linkedPatients.where((p) => (p['booking_id'] as num?) != null).toList();
    double amountOf(Object? v) => double.tryParse(v?.toString() ?? '') ?? 0.0;

    final mainTotal = _testsTotal + _serviceCharge + _additionalCharge;
    final mainPaid  = _liveAmountPaid + _sessionPaymentCollected;
    var grandTotal  = mainTotal;
    var totalDue    = _amountDue;
    var paid        = mainPaid > mainTotal ? mainTotal : mainPaid;
    for (final m in members) {
      final total = amountOf(m['total_amount']);
      final due   = amountOf(m['amount_due']);
      grandTotal += total;
      totalDue   += due;
      paid       += (total - due) > 0 ? total - due : 0.0;
    }
    final typed = _additionalChargeTargets
        .map((t) => (name: t.name, amount: _typedChargeFor(t.bookingId, t.amount)))
        .where((t) => t.amount > 0)
        .toList();
    final showMember = members.isNotEmpty;

    return _SectionCard(
      title: 'Billing Summary',
      icon: Icons.calculate_outlined,
      child: Column(children: [
        _BillRow('${widget.booking.customerName} (Tests)', '₹${_inr(_testsTotal)}'),
        for (final m in members) ...[
          const SizedBox(height: 4),
          _BillRow('${(m['patient_name'] as String? ?? 'Visit Member').toUpperCase()} (Tests)',
              '₹${_inr(amountOf(m['total_amount']) - amountOf(m['additional_charge_amount']))}'),
        ],
        ..._serviceChargeRows(),
        for (final c in _chargePackages) ...[
          const SizedBox(height: 4),
          _BillRow(
            '+ ${c['name'] ?? 'Charge package'}'
                '${showMember ? ' · ${_memberNameFor((c['bookingId'] as num?)?.toInt())}' : ''}',
            '₹${_inr((c['price'] as num?)?.toDouble() ?? 0.0)}',
            sub: true,
          ),
        ],
        for (final t in typed) ...[
          const SizedBox(height: 4),
          _BillRow('+ Additional charge${showMember ? ' · ${t.name}' : ''}', '₹${_inr(t.amount)}', sub: true),
        ],
        const Divider(height: 20),
        _BillRow('Grand Total', '₹${_inr(grandTotal)}', bold: true),
        if (paid > 0) ...[
          const SizedBox(height: 4),
          _BillRow('Paid', '₹${_inr(paid)}', sub: true),
        ],
        const SizedBox(height: 6),
        _BillRow(totalDue > 0 ? 'Amount Due' : 'Fully Paid', '₹${_inr(totalDue)}', bold: true, green: true),
      ]),
    );
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
        _livePaymentStatus      = data['payment_status'] as String? ?? _livePaymentStatus;
        _liveAmountPaid         = double.tryParse(data['amount_paid']?.toString() ?? '') ?? _liveAmountPaid;
        _totalAmount            = double.tryParse(data['total_amount']?.toString() ?? '') ?? _totalAmount;
        _additionalCharge       = double.tryParse(data['additional_charge_amount']?.toString() ?? '') ?? 0.0;
        _additionalChargeReason = data['additional_charge_reason'] as String?;
        // Server value now includes everything paid — session tracking is redundant
        _sessionPaymentCollected = 0.0;
      });
    } catch (e) {
      debugPrint('[_refreshPaymentInfo] $e');
    }
  }

  // Manual "Reload" — re-pulls payment status (this booking + any family
  // members added this visit) from the server so a payment the patient just
  // made on their own phone shows up without leaving/reopening the screen.
  // Deliberately does NOT touch _currentStatus/docs/session-collected-amount —
  // only the server-sourced payment fields that _paymentInitiated/
  // _visitPaymentStarted read, so the technician's in-progress journey state
  // is never reset by a reload.
  Future<void> _reloadBookingData() async {
    if (_isReloading) return;
    setState(() => _isReloading = true);
    try {
      await Future.wait([
        _refreshPaymentInfo(),
        _loadLinkedPatients(),
        _loadItems(),
        _loadAdditionalCharges(),
      ]);
    } finally {
      if (mounted) setState(() => _isReloading = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Booking details refreshed'),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Future<void> _loadDocs() async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    debugPrint('[_loadDocs] fetching prescriptions for bookingId=$bookingId');
    if (bookingId == 0) {
      if (mounted) setState(() => _docsLoading = false);
      return;
    }
    try {
      final docs = await ApiService.getPrescriptions(bookingId);
      debugPrint('[_loadDocs] received ${docs.length} doc(s) — '
          'patientIds=${docs.map((d) => d['patient_id']).toSet()}');
      if (!mounted) return;
      setState(() {
        for (final d in docs) {
          _docUploads.add(_TechPresDoc(
            docId:      (d['doc_id'] as num?)?.toInt(),
            url:        d['file_path'] as String?,
            fileName:   d['file_name'] as String? ?? 'document',
            uploadedAt: DateTime.tryParse(d['created_at']?.toString() ?? '') ?? DateTime.now(),
            docStatus:  d['doc_status'] as String? ?? 'pending_review',
            patientId:  (d['patient_id'] as num?)?.toInt(),
          ));
        }
        _docVerified = _docUploads.isNotEmpty && _docUploads.every((d) => d.isVerified);
        _docsLoading = false;
      });
      debugPrint('[_loadDocs] render state — _docUploads=${_docUploads.length} _docVerified=$_docVerified');
    } catch (e) {
      debugPrint('[_loadDocs] ERROR: $e');
      if (mounted) setState(() => _docsLoading = false);
    }
  }

  Future<void> _loadCollectionProof() async {
    final bookingId = int.tryParse(widget.booking.id) ?? 0;
    if (bookingId == 0) {
      if (mounted) setState(() => _collectionProofLoading = false);
      return;
    }
    try {
      final doc = await ApiService.getCollectionProofPhoto(bookingId);
      if (!mounted) return;
      setState(() {
        _proofUrlByBookingId[bookingId] = doc?['file_path'] as String?;
        _collectionProofLoading = false;
      });
    } catch (e) {
      debugPrint('[_loadCollectionProof] ERROR: $e');
      if (mounted) setState(() => _collectionProofLoading = false);
    }
  }

  // Each family member has their own booking_id, so their collection-proof
  // photo (see _loadCollectionProof for the primary) must be fetched and
  // keyed separately — otherwise every patient would show whichever photo
  // happened to load last.
  Future<void> _loadFamilyCollectionProofs(List<Map<String, dynamic>> patients) async {
    for (final p in patients) {
      final bid = (p['booking_id'] as num?)?.toInt();
      if (bid == null) continue;
      try {
        final doc = await ApiService.getCollectionProofPhoto(bid);
        if (mounted) {
          setState(() => _proofUrlByBookingId[bid] = doc?['file_path'] as String?);
        }
      } catch (e) {
        debugPrint('[_loadFamilyCollectionProofs] booking=$bid ERROR: $e');
      }
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
          // Per-item collection checklist state — reuses the pre-existing,
          // admin-owned item_status column, so its lowercase vocabulary
          // ('completed'/'pending') is used as-is, no true/false translation.
          'collected':     i['item_status']?.toString() ?? 'pending',
        }).toList();
        _originalItemIds = items.map((i) => i['product_id']?.toString() ?? '').toSet();
        _catalogueItems  = catalogue;
        _itemsLoading    = false;
        // Recalculate from actual items — covers tests added/removed during
        // the visit. Scoped to this booking's own items only; family
        // members' own requirements are tracked separately (see
        // _loadFamilyDocRequirements) since their tests live on their own
        // booking_id, not this one.
        _docRequired = items.any((i) {
          final v = i['doc_required'];
          return v == 1 || v == true || v == '1' || v == 'yes';
        });
        if (widget.booking.patientId != null) {
          _patientDocRequired[widget.booking.patientId!] = _docRequired;
        }
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
      _loadFamilyDocRequirements(patients);
      _loadFamilyCollectionProofs(patients);
    } catch (e) {
      debugPrint('[_loadLinkedPatients] ERROR: $e');
    }
  }

  // Each family member's tests live on their OWN booking_id, never this
  // screen's own — so their prescription requirement is otherwise invisible
  // to _docRequired/_patientDocRequired. Fetches each member's own items
  // (same endpoint _loadItems already uses for the primary) to find out.
  Future<void> _loadFamilyDocRequirements(List<Map<String, dynamic>> patients) async {
    for (final p in patients) {
      final pid = (p['patient_id'] as num?)?.toInt();
      final bid = (p['booking_id'] as num?)?.toInt();
      if (pid == null || bid == null) continue;
      try {
        final items = await ApiService.getBookingItems(bid);
        final needsDoc = items.any((i) {
          final v = i['doc_required'];
          return v == 1 || v == true || v == '1' || v == 'yes';
        });
        final rows = items.map((i) => {
          'bookingItemId': i['booking_item_id']?.toString() ?? '',
          'id':            i['product_id']?.toString() ?? '',
          'name':          i['name']?.toString()     ?? '',
          'category':      i['category']?.toString() ?? 'General',
          'price':         double.tryParse(i['price']?.toString() ?? '0')?.toStringAsFixed(0) ?? '0',
          'collected':     i['item_status']?.toString() ?? 'pending',
        }).toList();
        if (mounted) {
          setState(() {
            _patientDocRequired[pid] = needsDoc;
            _familyItems[bid] = rows;
          });
        }
      } catch (e) {
        debugPrint('[_loadFamilyDocRequirements] patient=$pid ERROR: $e');
      }
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
    WidgetsBinding.instance.removeObserver(this);
    clearRazorpay();
    for (final c in _otpControllers) c.dispose();
    for (final f in _otpFocusNodes) f.dispose();
    super.dispose();
  }

  // ── Exit ────────────────────────────────────────────────────
  // Shared by the back arrow, the system back gesture, and the bottom
  // Save Changes/Done button — all three must behave identically.
  void _exitScreen() {
    // Full completion (Handed to Lab) always pops with `true` — every layer
    // above (map screen, any earlier Manage Booking instance) already reacts
    // to `true` with its own completion choreography, so this alone already
    // cascades correctly today; nothing else to signal.
    if (_isCompleted) {
      Navigator.of(context).pop(true);
      return;
    }
    // Entered directly from the Dashboard — a single plain pop already lands
    // there, no cascade needed.
    if (!widget.cameFromActiveJob) {
      Navigator.of(context).pop(null);
      return;
    }
    // Leaving mid-journey via a screen that was itself opened from the live
    // map/active-job screen. The real distance back to the Dashboard isn't
    // fixed — that screen can itself have been opened from another Manage
    // Booking instance — so instead of guessing a pop count, signal every
    // layer above to cascade the same exit upward (see kExitToDashboard).
    Navigator.of(context).pop(kExitToDashboard);
  }

  // ── Journey advance ───────────────────────────────────────

void _advanceStatus() {
  if (_currentStatus == 'Handed to Lab') return;

  final next = _nextStatus;
  if (next == null) return;

  // OTP step: some payment (full or partial) must be recorded toward the
  // visit first — see _visitPaymentStarted. A remaining balance doesn't
  // block this, only a complete absence of payment does.
  if (next == 'OTP Verified') {
    if (!_visitPaymentStarted) {
      _showCompleteSheet();
    } else {
      _showOtpDialog();
    }
    return;
  }

  // Final step: confirm, then emit handed_to_lab. No payment check here —
  // the OTP step before it already required a payment or a no-payment reason.
  if (next == 'Handed to Lab') {
    _showHandOverToLabDialog();
    return;
  }

  // Prescription gate: mandatory for EVERY patient on the visit whose test
  // requires one — not just the primary patient. Marking Sample Collected
  // cascades to every family member's booking at once server-side, so this
  // is the last point where a missing family-member prescription can still
  // be caught before that happens.
  if (next == 'Sample Collected' && _anyDocRequired) {
    final missing = _visitPatients.where((p) {
      final pid = p['id'] as int?;
      if (pid == null || _patientDocRequired[pid] != true) return false;
      return !_docUploads.any((d) => d.patientId == pid);
    }).toList();
    if (missing.isNotEmpty) {
      final names = missing.map((p) => p['name'] as String).join(', ');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Upload prescription for: $names'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    if (!_docVerified) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Verify the prescription before collecting the sample.'),
        backgroundColor: Colors.orange,
      ));
      return;
    }
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
      ).then((result) {
        if (!mounted) return;
        if (result == kExitToDashboard) {
          Navigator.of(context).pop(kExitToDashboard);
        } else if (result == true) {
          Navigator.of(context).pop(true);
        }
      });
      break;

    case 'Destination Reached':
      setState(() => _currentStatus = 'Destination Reached');
      if (bookingId > 0) SocketService.instance.emitArrived(bookingId: bookingId);
      // The server adds the service charge to the bill on arrival — reload
      // the bill once it has (the charges call also applies it if needed).
      Future.delayed(const Duration(milliseconds: 1500), () async {
        if (!mounted) return;
        await _loadAdditionalCharges();
        await _refreshPaymentInfo();
      });
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

// ── Hand Over to Lab dialog ────────────────────────────────
// Requires both a selected branch/lab and a "received by" name before the
// technician can confirm — final step of the visit, matching the
// handover_branch_id/received_by_name columns added to
// ip_technician_collection for this purpose.
Future<void> _showHandOverToLabDialog() async {
  if (_labBranches.isEmpty) {
    try {
      _labBranches = await ApiService.getBranches();
    } catch (e) {
      debugPrint('[_showHandOverToLabDialog] branch fetch ERROR: $e');
    }
  }
  if (!mounted) return;

  final receivedByCtrl = TextEditingController();
  final branchSearchCtrl = TextEditingController();
  BranchModel? selectedBranch;
  bool showBranchSearch = false;
  // Submission state — the dialog now stays open and shows real progress
  // instead of closing immediately and assuming success (see
  // SocketService.emitHandedToLab: it now awaits a real server
  // acknowledgement instead of firing-and-forgetting).
  bool isSubmitting = false;
  String? submitError;

  showDialog(
    context: context,
    builder: (_) => StatefulBuilder(
      builder: (dialogCtx, setDialogState) {
        final query = branchSearchCtrl.text.trim().toLowerCase();
        final filteredBranches = query.isEmpty
            ? _labBranches
            : _labBranches.where((b) => b.name.toLowerCase().contains(query)).toList();
        final canConfirm = selectedBranch != null &&
            receivedByCtrl.text.trim().isNotEmpty &&
            !isSubmitting;

        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Hand Over to Lab?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'This will complete the visit and cannot be undone.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 14),

                // ── Received Branch/Lab ──────────────────────────
                const Text('Received Branch/Lab *',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => setDialogState(() => showBranchSearch = !showBranchSearch),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selectedBranch != null ? AppColors.brandGreen : AppColors.divider,
                      ),
                    ),
                    child: Row(children: [
                      Icon(Icons.local_hospital_outlined, size: 16,
                          color: selectedBranch != null ? AppColors.brandGreen : AppColors.textHint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          selectedBranch?.name ?? 'Select branch/lab',
                          style: TextStyle(
                            fontSize: 13,
                            color: selectedBranch != null ? AppColors.textPrimary : AppColors.textHint,
                          ),
                        ),
                      ),
                      Icon(showBranchSearch ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          size: 18, color: AppColors.textHint),
                    ]),
                  ),
                ),

                if (showBranchSearch) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: branchSearchCtrl,
                    autofocus: true,
                    onChanged: (_) => setDialogState(() {}),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search branch name…',
                      hintStyle: const TextStyle(fontSize: 12, color: AppColors.textHint),
                      prefixIcon: const Icon(Icons.search_rounded, size: 16, color: AppColors.textHint),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.divider)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.divider)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Plain mapped Column, not ListView — a ListView (sliver-
                  // based) inside AlertDialog content crashes on web/desktop
                  // because AlertDialog sizes itself via IntrinsicWidth, and
                  // slivers don't support intrinsic-width computation. Same
                  // pattern already used safely elsewhere in this file for
                  // the "Add Test / Package" search list.
                  if (filteredBranches.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No branches found', style: TextStyle(fontSize: 12, color: AppColors.textHint)),
                    )
                  else
                    ...filteredBranches.take(6).map((b) => GestureDetector(
                          onTap: () => setDialogState(() {
                            selectedBranch     = b;
                            showBranchSearch   = false;
                            branchSearchCtrl.clear();
                          }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(b.name, style: const TextStyle(fontSize: 13)),
                          ),
                        )),
                ],

                const SizedBox(height: 14),

                // ── Received By ───────────────────────────────────
                const Text('Received By *',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                TextField(
                  controller: receivedByCtrl,
                  onChanged: (_) => setDialogState(() {}),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z ]'))],
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Name of person receiving the samples',
                    hintStyle: const TextStyle(fontSize: 13, color: AppColors.textHint),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                  ),
                ),

                if (submitError != null) ...[
                  const SizedBox(height: 12),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.error_outline_rounded, size: 15, color: Color(0xFFD32F2F)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(submitError!,
                          style: const TextStyle(fontSize: 12, color: Color(0xFFD32F2F))),
                    ),
                  ]),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSubmitting ? null : () => Navigator.pop(dialogCtx),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
            ),
            ElevatedButton(
              onPressed: !canConfirm ? null : () async {
                setDialogState(() {
                  isSubmitting = true;
                  submitError  = null;
                });

                final bookingId = int.tryParse(widget.booking.id) ?? 0;
                final result = await SocketService.instance.emitHandedToLab(
                  bookingId:        bookingId,
                  receivedByName:   receivedByCtrl.text.trim(),
                  handoverBranchId: int.tryParse(selectedBranch!.id),
                );

                if (result['success'] == true) {
                  if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                  if (mounted) {
                    setState(() => _currentStatus = 'Handed to Lab');
                    // Job finished — confirm and go back to the Dashboard
                    // (once the dialog has closed).
                    AppMessages.success(context, 'Sample handed over to the lab. Job complete.');
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _exitScreen();
                    });
                  }
                } else if (dialogCtx.mounted) {
                  setDialogState(() {
                    isSubmitting = false;
                    submitError  = AppMessages.serverMessage(result['message'],
                        fallback: 'We couldn\'t record the handover. Please try again.');
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen, elevation: 0,
                disabledBackgroundColor: AppColors.divider,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: isSubmitting
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Confirm', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    ),
  );
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
  ).then((result) {
    if (!mounted) return;
    if (result == kExitToDashboard) {
      Navigator.of(context).pop(kExitToDashboard);
    } else if (result == true) {
      Navigator.of(context).pop(true);
    }
  });
}
 // ── OTP dialog ────────────────────────────────────────────

  // Nothing paid toward the visit: asks why before the OTP (required, up to
  // 255 characters). Returns the reason, or null if the technician backs out.
  Future<String?> _askNoPaymentReason() async {
    final ctrl = TextEditingController(text: _noPaymentReason ?? '');
    String? error;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('No payment collected'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Enter the reason for not collecting any payment, then verify the OTP.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLength: 255,
              maxLines: 3,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) { if (error != null) setDlg(() => error = null); },
              decoration: InputDecoration(
                labelText: 'Reason for no payment *',
                hintText: 'e.g. Customer will pay at report delivery',
                errorText: error,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final text = ctrl.text.trim();
                if (text.isEmpty) {
                  setDlg(() => error = 'Please enter the reason');
                  return;
                }
                Navigator.pop(ctx, text);
              },
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.brandGreen, foregroundColor: Colors.white),
              child: const Text('Continue to OTP'),
            ),
          ],
        ),
      ),
    );
    // Disposed after the dialog's closing animation, which still reads it.
    Future.delayed(const Duration(milliseconds: 400), ctrl.dispose);
    return reason;
  }

  Future<void> _showOtpDialog() async {
    for (final c in _otpControllers) { c.clear(); }
    setState(() { _otpError = false; _otpErrorText = 'Invalid OTP. Please try again.'; });

    final bookingId = int.tryParse(widget.booking.id) ?? 0;

    // Generate OTP on server and send SMS before opening the dialog
    final genResult = await ApiService.generateBookingOtp(bookingId);
    if (!mounted) return;

    if (genResult == null || genResult['success'] != true) {
      AppMessages.error(context, AppMessages.serverMessage(genResult?['message'],
          fallback: 'We couldn\'t send the OTP to the patient. Please try again.'));
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
          // Fixed-height Column overflows once the on-screen keyboard opens
          // and shrinks the available space (the OTP boxes autofocus the
          // keyboard open immediately). Wrapping in a scroll view lets the
          // content scroll instead of overflowing, matching the fix already
          // applied to the payment sheet for the same underlying issue.
          child: SingleChildScrollView(
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
    final result = await ApiService.verifyBookingOtp(
      bookingId: bookingId,
      otp: otp,
      // Nothing paid yet: the reason the technician gave (_askNoPaymentReason).
      noPaymentReason: _visitPaymentStarted ? null : _noPaymentReason,
    );

    if (!mounted) return;

    if (result?['success'] == true) {
      setState(() { _isVerifyingOtp = false; _currentStatus = 'OTP Verified'; });
      // Pop via the stable outer context (root navigator) rather than the
      // dialog's inner StatefulBuilder ctx, which can go stale across the
      // await above and silently skip the pop while still being "mounted"
      // enough for the earlier check to pass.
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('OTP verified — tap "Hand Over to Lab" to complete'),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
      ));
    } else {
      setState(() {
        _isVerifyingOtp = false;
        _otpError       = true;
        _otpErrorText   = AppMessages.serverMessage(result?['message'],
            fallback: 'Incorrect OTP. Please try again.');
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
      AppMessages.error(context, AppMessages.serverMessage(result?['message'],
          fallback: 'We couldn\'t resend the OTP. Please try again.'));
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
    final test          = _selectedTests.firstWhere((t) => t['id'] == id, orElse: () => {});
    final bookingItemId = int.tryParse(test['bookingItemId'] ?? '');
    final price         = double.tryParse(test['price'] ?? '0') ?? 0;
    final wasOriginal   = _originalItemIds.contains(id);
    // Remove from UI immediately (optimistic).
    // If the removed test was in the original booking, also subtract its price
    // from _totalAmount — otherwise _serviceCharge = _totalAmount - _originalItemsTotal
    // inflates incorrectly (the original test drops out of _originalItemsTotal
    // while _totalAmount stays high, making the service charge appear to grow).
    setState(() {
      _selectedTests.removeWhere((t) => t['id'] == id);
      if (wasOriginal) {
        _originalItemIds.remove(id);
        _totalAmount = (_totalAmount - price).clamp(0.0, double.infinity);
      }
    });
    if (bookingItemId != null && bookingItemId > 0) {
      final bookingId = int.tryParse(widget.booking.id) ?? 0;
      await ApiService.removeBookingItem(bookingId: bookingId, bookingItemId: bookingItemId);
    }
  }

  // ── Family member test edits ──────────────────────────────
  // Mirror of _removeTest / _addTest but scoped to a family member's
  // own booking_id. No _totalAmount/_serviceCharge bookkeeping needed
  // because those fields track only the primary patient's payment state.

  // Updates _linkedPatients[i]['amount_due'] for the given family booking so
  // the "₹X due" badge in the card reflects test additions/removals immediately
  // without waiting for a full server reload.
  void _updateFamilyAmountDue(int familyBookingId, double delta) {
    setState(() {
      _linkedPatients = _linkedPatients.map((p) {
        if ((p['booking_id'] as num?)?.toInt() != familyBookingId) return p;
        final oldDue = double.tryParse(p['amount_due']?.toString() ?? '0') ?? 0.0;
        final newDue = oldDue + delta;
        if (newDue < -0.5) {
          // amount_due went negative — the overshoot is a refund owed to the customer.
          _familyPendingRefund[familyBookingId] =
              (_familyPendingRefund[familyBookingId] ?? 0) + (-newDue);
        }
        return {...p, 'amount_due': newDue.clamp(0.0, double.infinity)};
      }).toList();
    });
  }

  Future<void> _removeFamilyTest(String testId, int familyBookingId) async {
    if (_isFinalized) return;
    final items = _familyItems[familyBookingId];
    if (items == null) return;
    final test          = items.firstWhere((t) => t['id'] == testId, orElse: () => {});
    final bookingItemId = int.tryParse(test['bookingItemId'] ?? '');
    final price         = double.tryParse(test['price'] ?? '0') ?? 0;
    setState(() => items.removeWhere((t) => t['id'] == testId));
    _updateFamilyAmountDue(familyBookingId, -price);
    if (bookingItemId != null && bookingItemId > 0) {
      await ApiService.removeBookingItem(bookingId: familyBookingId, bookingItemId: bookingItemId);
    }
  }

  // ✕ on a Visit Members card (members the technician added this visit):
  // confirm, then the member's booking is deleted. The server refuses when the
  // customer booked them, samples are collected, something is paid, or it is
  // the main patient — its message is shown as-is.
  Future<void> _confirmRemoveMember(Map<String, dynamic> member, int memberBookingId) async {
    if (_isFinalized) return;
    final name = (member['patient_name'] as String?)?.trim().isNotEmpty == true
        ? member['patient_name'] as String
        : 'this member';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name?'),
        content: Text('$name and their tests will be removed from this visit.',
            style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final result = await ApiService.removeVisitMember(bookingId: memberBookingId);
    if (!mounted) return;
    final ok = result['success'] == true;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text((result['message'] as String?) ?? (ok ? '$name removed' : 'Could not remove $name')),
      backgroundColor: ok ? null : Colors.red,
      behavior: SnackBarBehavior.floating,
    ));
    if (!ok) return;
    setState(() {
      _linkedPatients = _linkedPatients
          .where((p) => (p['booking_id'] as num?)?.toInt() != memberBookingId)
          .toList();
      _familyItems.remove(memberBookingId);
    });
    await _loadLinkedPatients();
    _refreshPaymentInfo();
  }

  Future<void> _addFamilyTest(Map<String, String> t, int familyBookingId) async {
    if (_isFinalized) return;
    final items = _familyItems[familyBookingId] ?? [];
    if (items.any((x) => x['id'] == t['id'])) return;
    final price = double.tryParse(t['price'] ?? '0') ?? 0;
    setState(() {
      _familyItems[familyBookingId] = [
        ...items,
        {...Map<String, String>.from(t), 'bookingItemId': '', 'collected': 'pending'},
      ];
    });
    _updateFamilyAmountDue(familyBookingId, price);
    final productId = int.tryParse(t['id'] ?? '') ?? 0;
    if (familyBookingId == 0 || productId == 0) return;
    final result = await ApiService.addBookingItem(bookingId: familyBookingId, productId: productId);
    if (!mounted) return;
    if (result != null) {
      setState(() {
        final list = _familyItems[familyBookingId] ?? [];
        final idx  = list.indexWhere((x) => x['id'] == t['id'] && x['bookingItemId'] == '');
        if (idx != -1) {
          list[idx]['bookingItemId'] = (result['bookingItemId'] as num?)?.toInt().toString() ?? '';
        }
      });
    } else {
      // Revert both the test list and the due amount on failure.
      setState(() {
        _familyItems[familyBookingId]?.removeWhere((x) => x['id'] == t['id'] && x['bookingItemId'] == '');
      });
      _updateFamilyAmountDue(familyBookingId, -price);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to add test — please retry'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  void _showAddFamilyTestSheet(int familyBookingId) {
    String searchQuery = '';
    final Set<String> pendingIds = {};
    bool adding = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final already  = (_familyItems[familyBookingId] ?? []).map((t) => t['id']).toSet();
          final filtered = _catalogueItems.where((t) {
            if (already.contains(t['id'])) return false;
            if (searchQuery.isEmpty) return true;
            return (t['name']?.toLowerCase().contains(searchQuery.toLowerCase()) ?? false) ||
                (t['category']?.toLowerCase().contains(searchQuery.toLowerCase()) ?? false);
          }).toList();
          final selectedTotal = _catalogueItems
              .where((t) => pendingIds.contains(t['id']))
              .fold<double>(0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0));
          return Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding: EdgeInsets.fromLTRB(
              16, 0, 16,
              MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
                ),
                const Text('Add Test / Package',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                TextField(
                  autofocus: true,
                  onChanged: (v) => setSheet(() => searchQuery = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search tests…',
                    hintStyle: const TextStyle(fontSize: 13, color: AppColors.textHint),
                    prefixIcon: const Icon(Icons.search_rounded, size: 18, color: AppColors.textHint),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.divider)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  height: filtered.isEmpty ? null : (filtered.length * 58.0).clamp(58.0, 300.0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: filtered.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(child: Text('No tests found',
                              style: TextStyle(fontSize: 13, color: AppColors.textHint))),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final t = filtered[i];
                            final id = t['id'] ?? '';
                            return CheckboxListTile(
                              value: pendingIds.contains(id),
                              onChanged: adding
                                  ? null
                                  : (v) => setSheet(() {
                                        if (v == true) pendingIds.add(id);
                                        else pendingIds.remove(id);
                                      }),
                              activeColor: AppColors.brandGreen,
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                              title: Text(t['name'] ?? '',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                              subtitle: (t['category'] ?? '').isEmpty ? null
                                  : Text(t['category']!,
                                      style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                              secondary: Text('₹${t['price'] ?? '0'}',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                      color: AppColors.brandGreen)),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: adding ? null : () => Navigator.pop(ctx),
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
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: (pendingIds.isEmpty || adding) ? null : () async {
                        setSheet(() => adding = true);
                        final picked = _catalogueItems
                            .where((t) => pendingIds.contains(t['id'])).toList();
                        for (final t in picked) {
                          await _addFamilyTest(t, familyBookingId);
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: adding
                          ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(
                              pendingIds.isEmpty
                                  ? 'Select tests to add'
                                  : 'Add ${pendingIds.length} selected · ₹${selectedTotal.toStringAsFixed(0)}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                    ),
                  ),
                ]),
              ],
            ),
          );
        },
      ),
    );
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
      // Escalate (never de-escalate here) — a test added mid-visit that itself
      // needs a prescription must also trigger the upload/verify gate, not
      // just tests present on the booking when the screen first loaded.
      // _addTest always adds to this screen's own (primary) booking.
      if (t['docRequired'] == 'yes') {
        _docRequired = true;
        if (widget.booking.patientId != null) {
          _patientDocRequired[widget.booking.patientId!] = true;
        }
      }
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

  // Adds every ticked test/package, one after another through _addTest (same
  // optimistic add, server call, prescription gate and failure message as a
  // single add), then closes the picker.
  Future<void> _addSelectedTests() async {
    if (_isFinalized || _addingTests || _pendingTestIds.isEmpty) return;
    final picked = _catalogueItems.where((t) => _pendingTestIds.contains(t['id'])).toList();
    setState(() => _addingTests = true);
    for (final t in picked) {
      await _addTest(t);
      if (!mounted) return;
    }
    setState(() {
      _addingTests = false;
      _pendingTestIds.clear();
      _showAddTest = false;
      _searchQuery = '';
    });
  }

  void _closeAddTest() => setState(() {
        _showAddTest = false;
        _searchQuery = '';
        _pendingTestIds.clear();
      });

  // Collection checklist toggle — purely a per-item tracking flag, does not
  // touch _currentStatus, collection_status, or the sample_collected flow.
  // targetBookingId defaults to this screen's own (primary) booking; pass a
  // family member's own booking_id to toggle one of their items instead —
  // each family member's tests live on their own booking_id (see
  // _loadFamilyDocRequirements), so the update must target the right one.
  Future<void> _toggleItemCollected(String testId, bool newValue, {int? targetBookingId}) async {
    final bookingId = targetBookingId ?? int.tryParse(widget.booking.id) ?? 0;
    final isFamily   = targetBookingId != null;
    final list       = isFamily ? _familyItems[bookingId] : _selectedTests;
    if (list == null) return;

    final bookingItemId = int.tryParse(
      list.firstWhere((t) => t['id'] == testId, orElse: () => {})['bookingItemId'] ?? '',
    );
    if (bookingItemId == null || bookingItemId <= 0) return;

    // Optimistic local update.
    setState(() {
      final idx = list.indexWhere((t) => t['id'] == testId);
      if (idx != -1) list[idx]['collected'] = newValue ? 'completed' : 'pending';
    });
    final ok = await ApiService.setBookingItemCollected(
      bookingId: bookingId,
      bookingItemId: bookingItemId,
      collected: newValue,
    );
    if (!mounted) return;
    if (!ok) {
      // Revert on failure.
      setState(() {
        final idx = list.indexWhere((t) => t['id'] == testId);
        if (idx != -1) list[idx]['collected'] = newValue ? 'pending' : 'completed';
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Failed to update checklist — please retry'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
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

  // ── Sample-collection proof photo (optional) ─────────────────
  // Camera-only (ImageSource.camera — no gallery option offered, so a
  // technician cannot substitute an old photo). Available any time from
  // "Collection Started" onward via its own section in the UI (see the
  // "Sample Collection Photo" _SectionCard below) — not tied to the moment
  // "Sample Collected" is tapped, so a technician who skips it initially
  // still has a clear way to add (or retake) it later. Optional: cancelling
  // the camera or any upload failure just leaves the previous state as-is,
  // it never blocks anything. Reuses the same two-step upload pipeline as
  // prescription documents: raw bytes → /api/upload → URL, then the URL is
  // linked to this booking_id via saveCollectionProofPhoto. A retake simply
  // calls this again — the server keeps the newest photo as current.
  // patientId/bookingId identify WHICH patient this photo belongs to — the
  // primary patient's own booking, or one family member's own booking_id.
  // Never assume widget.booking.id here, or every family member's photo
  // would overwrite the primary's (or each other's).
  // Why this photo used to get stuck on "Opening camera…": the camera is a
  // separate app, and on low-memory / aggressive-battery phones Android
  // closes MicroLab's screen while it is open. The photo result then never
  // reaches this await, so it only cleared after the timeout, and the photo
  // was lost. The flow below handles that in four ways:
  //   1. The capture is recorded in SharedPreferences before the camera
  //      opens; on return (didChangeAppLifecycleState) or reopening the
  //      screen (initState), _recoverLostProofPhoto fetches the lost photo
  //      with ImagePicker.retrieveLostData() and uploads it.
  //   2. The box shows the real step: Opening camera… / Uploading photo… /
  //      Saving photo….
  //   3. Tapping the box while it waits for the camera or the upload
  //      cancels it (_cancelProofCapture); a late result is ignored via
  //      _proofCaptureToken.
  //   4. Smaller photo (1280px, quality 70 → roughly 200–500KB) so uploads
  //      are quicker on mobile data.
  static const String _pendingProofKey = 'pending_collection_proof_capture';

  Future<void> _captureAndUploadCollectionProof({required int bookingId}) async {
    if (_capturingProofBookingId != null) return;
    if (bookingId <= 0) return;

    final token = ++_proofCaptureToken;
    setState(() {
      _capturingProofBookingId = bookingId;
      _proofStep = _ProofStep.camera;
    });
    await _rememberPendingProof(bookingId: bookingId);

    XFile? image;
    try {
      // The timeout is only a last resort now — a lost result is normally
      // picked up a few seconds after returning (see didChangeAppLifecycleState).
      image = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
        maxWidth: 1280,
        maxHeight: 1280,
      ).timeout(const Duration(seconds: 60), onTimeout: () => null);
    } catch (e) {
      debugPrint('[CollectionProof] camera error: $e');
      if (token == _proofCaptureToken) {
        await _forgetPendingProof();
        _endProofCapture();
        if (mounted) AppMessages.error(context, AppMessages.friendlyError(e));
      }
      return;
    }

    // Cancelled from the box, or already handled by the recovery path.
    if (token != _proofCaptureToken) return;

    if (image == null) {
      // Technician backed out of the camera — fine, the photo is optional.
      await _forgetPendingProof();
      _endProofCapture();
      return;
    }

    await _forgetPendingProof();
    await _uploadProofPhoto(image: image, bookingId: bookingId, token: token);
  }

  // Upload + link to the booking, shared by a normal capture and a recovered
  // one. Shows "Uploading photo…" then "Saving photo…" on the box.
  Future<void> _uploadProofPhoto({
    required XFile image,
    required int bookingId,
    required int token,
  }) async {
    void step(_ProofStep s) {
      if (mounted && token == _proofCaptureToken) setState(() => _proofStep = s);
    }

    try {
      step(_ProofStep.uploading);
      final bytes = await image.readAsBytes();
      final url = await ApiService.uploadFile(bytes.toList(), image.name);
      if (token != _proofCaptureToken) return; // cancelled meanwhile
      if (url == null) {
        if (mounted) AppMessages.error(context, 'We couldn\'t upload the photo. Please check your connection and try again.');
        return;
      }

      step(_ProofStep.saving);
      final saved = await ApiService.saveCollectionProofPhoto(bookingId: bookingId, imageUrl: url);
      if (token != _proofCaptureToken) return;
      if (!saved) {
        if (mounted) AppMessages.error(context, 'We couldn\'t save the photo. Please try again.');
        return;
      }

      if (mounted) {
        setState(() => _proofUrlByBookingId[bookingId] = url);
        AppMessages.success(context, 'Collection photo added');
      }
    } catch (e) {
      debugPrint('[CollectionProof] upload error: $e');
      if (mounted && token == _proofCaptureToken) {
        AppMessages.error(context, 'We couldn\'t upload the photo. ${AppMessages.friendlyError(e)}');
      }
    } finally {
      if (token == _proofCaptureToken) _endProofCapture();
    }
  }

  // ✕ on a collection photo: confirm, then remove it on the server and show
  // the empty "Take Collection Photo" box again.
  Future<void> _confirmRemoveCollectionProof({required int bookingId, required String patientName}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove photo?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text('The collection photo for $patientName will be removed. You can take a new one afterwards.',
            style: const TextStyle(fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove', style: TextStyle(color: Color(0xFFD32F2F), fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _removingProofBookingId = bookingId);
    final result = await ApiService.deleteCollectionProofPhoto(bookingId);
    if (!mounted) return;
    if (result['success'] == true) {
      setState(() {
        _proofUrlByBookingId[bookingId] = null;
        _removingProofBookingId = null;
      });
      AppMessages.success(context, 'Photo removed');
    } else {
      setState(() => _removingProofBookingId = null);
      AppMessages.error(context, result['error'] != null
          ? 'We couldn\'t remove the photo. ${AppMessages.friendlyError(result['error'])}'
          : AppMessages.serverMessage(result['message'],
              fallback: 'We couldn\'t remove the photo. Please try again.'));
    }
  }

  // Tapping the box while it waits (camera or upload). A result that turns
  // up later is ignored because the token has moved on.
  Future<void> _cancelProofCapture() async {
    if (_capturingProofBookingId == null || _proofStep == _ProofStep.saving) return;
    debugPrint('[CollectionProof] cancelled by technician at step=$_proofStep');
    _proofCaptureToken++;
    await _forgetPendingProof();
    _endProofCapture();
    if (mounted) AppMessages.info(context, 'Photo cancelled. Tap the box to take it again.');
  }

  // Always clears the busy flag, even if the widget has unmounted — only the
  // setState() call needs the mounted guard. (Gating the reset itself on
  // mounted previously left the flag stuck and every later tap a no-op.)
  void _endProofCapture() {
    _capturingProofBookingId = null;
    _proofStep = _ProofStep.camera;
    if (mounted) setState(() {});
  }

  // Recovers a photo whose camera result was lost because Android closed
  // this screen while the camera was open (Android only). Runs on opening
  // the screen, and a few seconds after returning from the camera if no
  // result came. Only acts on a capture that this flow recorded, and only
  // for this visit's booking — so it never picks up a prescription photo.
  // When nothing is recoverable, a normal (just slow) camera result can
  // still arrive, so the box keeps waiting — the technician can tap to
  // cancel, and the 60s timeout is the final fallback.
  Future<void> _recoverLostProofPhoto({bool fromResume = false}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final pending = await _readPendingProof();
    if (pending == null || pending.screenBookingId != widget.booking.id) return;

    LostDataResponse lost;
    try {
      lost = await _picker.retrieveLostData();
    } catch (e) {
      debugPrint('[CollectionProof] retrieveLostData failed: $e');
      return;
    }

    final file = (lost.files != null && lost.files!.isNotEmpty) ? lost.files!.first : lost.file;
    if (lost.isEmpty || file == null) {
      debugPrint('[CollectionProof] no lost photo to recover (fromResume=$fromResume exception=${lost.exception?.code})');
      // Opening the screen fresh: a recorded capture with nothing to recover
      // is stale (the app was closed mid-camera and the photo is gone).
      if (!fromResume) await _forgetPendingProof();
      return;
    }
    await _forgetPendingProof();

    debugPrint('[CollectionProof] recovered lost photo for booking=${pending.bookingId}');
    final token = ++_proofCaptureToken;
    if (mounted) {
      setState(() {
        _capturingProofBookingId = pending.bookingId;
        _proofStep = _ProofStep.uploading;
      });
    }
    await _uploadProofPhoto(
      image: file, bookingId: pending.bookingId, token: token,
    );
  }

  Future<void> _rememberPendingProof({required int bookingId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingProofKey, '${widget.booking.id}|$bookingId');
    } catch (_) {}
  }

  Future<void> _forgetPendingProof() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingProofKey);
    } catch (_) {}
  }

  // Stored as "<screen booking id>|<photo booking id>". An entry from the
  // previous build ("<screen>|<patient id>|<booking id>") still reads: the
  // booking id is always the last part.
  Future<({String screenBookingId, int bookingId})?> _readPendingProof() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final parts = prefs.getString(_pendingProofKey)?.split('|');
      if (parts == null || parts.length < 2) return null;
      final bid = int.tryParse(parts.last);
      if (bid == null) return null;
      return (screenBookingId: parts.first, bookingId: bid);
    } catch (_) {
      return null;
    }
  }

  // ── Document ──────────────────────────────────────────────

  void _showDocSourcePicker({required int targetBookingId, required int targetPatientId}) {
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
          _DocSourceTile(Icons.camera_alt_outlined, 'Camera', 'Take a photo now', () {
            Navigator.pop(context);
            _pickDoc(ImageSource.camera, targetBookingId: targetBookingId, targetPatientId: targetPatientId);
          }),
          const SizedBox(height: 8),
          _DocSourceTile(Icons.photo_library_outlined, 'Gallery', 'Choose from your photos', () {
            Navigator.pop(context);
            _pickDoc(ImageSource.gallery, targetBookingId: targetBookingId, targetPatientId: targetPatientId);
          }),
          const SizedBox(height: 4),
        ]),
      ),
    );
  }

  Future<void> _pickDoc(ImageSource source, {required int targetBookingId, required int targetPatientId}) async {
    if (_docIsPicking || _docUploads.length >= _docMaxFiles) return;
    setState(() => _docIsPicking = true);
    try {
      if (source == ImageSource.gallery) {
        // Same 5MB-upload-cap / slow-mobile-upload reasoning as the
        // collection-proof camera capture above — a gallery photo can be
        // just as large as a fresh camera shot.
        final images = await _picker.pickMultiImage(imageQuality: 80, maxWidth: 1600, maxHeight: 1600);
        if (images.isNotEmpty) {
          final toAdd = images.take(_docMaxFiles - _docUploads.length);
          for (final f in toAdd) {
            final bytes = await f.readAsBytes();
            final placeholder = _TechPresDoc(
              bytes: bytes, fileName: f.name,
              uploadedAt: DateTime.now(), isUploading: true,
              patientId: targetPatientId,
            );
            setState(() => _docUploads.add(placeholder));
            _uploadDoc(placeholder, bytes, f.name, targetBookingId: targetBookingId, targetPatientId: targetPatientId);
          }
        }
      } else {
        final image = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 80,
          maxWidth: 1600,
          maxHeight: 1600,
        ).timeout(const Duration(seconds: 90), onTimeout: () => null);
        if (image != null) {
          final bytes = await image.readAsBytes();
          final placeholder = _TechPresDoc(
            bytes: bytes, fileName: image.name,
            uploadedAt: DateTime.now(), isUploading: true,
            patientId: targetPatientId,
          );
          setState(() => _docUploads.add(placeholder));
          _uploadDoc(placeholder, bytes, image.name, targetBookingId: targetBookingId, targetPatientId: targetPatientId);
        }
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
    setState(() => _docIsPicking = false);
  }

  Future<void> _uploadDoc(
    _TechPresDoc placeholder,
    Uint8List bytes,
    String fileName, {
    required int targetBookingId,
    required int targetPatientId,
  }) async {
    final bookingId = targetBookingId;
    final patientId = targetPatientId;
    debugPrint('[_uploadDoc] starting — bookingId=$bookingId patientId=$patientId fileName=$fileName');
    try {
      // Step 1: upload file binary → get URL
      final url = await ApiService.uploadFile(bytes.toList(), fileName);
      debugPrint('[_uploadDoc] upload result — url=$url');
      if (url == null || !mounted) {
        setState(() => _docUploads.remove(placeholder));
        return;
      }
      // Step 2: save URL linked to booking → get docId
      final docId = await ApiService.savePrescriptionDoc(
        bookingId: bookingId, patientId: patientId, imageUrl: url,
      );
      debugPrint('[_uploadDoc] savePrescriptionDoc result — docId=$docId');
      if (!mounted) return;
      setState(() {
        final idx = _docUploads.indexOf(placeholder);
        if (idx == -1) return;
        if (docId != null) {
          _docUploads[idx] = _TechPresDoc(
            docId: docId, url: url, fileName: fileName,
            uploadedAt: DateTime.now(), docStatus: 'pending_review',
            patientId: patientId,
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

  // Takes the doc object itself (not a raw index) — the Prescription section
  // now renders per-patient FILTERED sublists, so an index local to one
  // patient's thumbnails would not line up with _docUploads's own indices.
  void _viewDocImage(_TechPresDoc doc) {
    final index = _docUploads.indexOf(doc);
    if (index == -1) return;
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _DocImageViewerPage(images: _docUploads, initialIndex: index)));
  }

  // Reuses the same full-screen viewer as prescription docs — wraps the
  // single collection-proof URL in a _TechPresDoc since that's what the
  // viewer expects, there's just one image and no delete action here.
  void _viewCollectionProofImage(String? url) {
    if (url == null) return;
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => _DocImageViewerPage(
              images: [_TechPresDoc(url: url, fileName: 'collection_proof.jpg', uploadedAt: DateTime.now())],
              initialIndex: 0,
            )));
  }

  Future<void> _deleteDocImage(_TechPresDoc doc) async {
    if (doc.isUploading) return; // wait for upload to finish first
    debugPrint('[_deleteDocImage] deleting docId=${doc.docId} patientId=${doc.patientId}');
    if (doc.docId != null) {
      final ok = await ApiService.deletePrescription(doc.docId!);
      if (!ok || !mounted) return;
    }
    setState(() {
      _docUploads.remove(doc);
      if (_docUploads.isEmpty) _docVerified = false;
    });
  }

  Future<void> _markDocsVerified() async {
    bool anyFailed = false;
    for (final doc in _docUploads) {
      if (doc.docId != null && !doc.isVerified) {
        final ok = await ApiService.verifyPrescription(doc.docId!);
        if (ok && mounted) {
          setState(() => doc.docStatus = 'verified');
        } else {
          anyFailed = true;
        }
      }
    }
    if (!mounted) return;
    // Derive _docVerified from actual per-doc status rather than forcing it
    // true — a failed verify call must not silently satisfy the "Sample
    // Collected" gate for a document still pending_review server-side.
    setState(() => _docVerified = _docUploads.every((d) => d.isVerified));
    if (anyFailed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Some documents could not be verified — please retry.'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
    }
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
              Text('${widget.booking.customerName}${widget.booking.referenceNo != null ? ' · ${widget.booking.referenceNo}' : ''}',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 20),

              // Step 1: Payment
              _CompleteStep(
                number: '1',
                title: 'Collect Payment',
                // Same figures as the button below: everyone on the visit
                // who still owes (main patient + family members).
                subtitle: _unpaidMembers.isEmpty
                    ? 'All payments collected'
                    : _unpaidMembers.length > 1
                        ? 'Collect ₹${_inr(_unpaidTotal)} for ${_unpaidMembers.length} members. Part payment is fine to continue.'
                        : _livePaymentStatus == 'paid'
                            ? 'Original ₹${_inr(_liveAmountPaid)} paid. Collect additional: ₹${_inr(_unpaidTotal)}'
                            : 'Collect ₹${_inr(_unpaidTotal)} from customer (tests amount)',
                done: _unpaidMembers.isEmpty,
                locked: false,
                buttonLabel: _unpaidMembers.isEmpty
                    ? 'Paid ✓'
                    : 'Make Payment  ₹${_inr(_unpaidTotal)}',
                buttonColor: _unpaidMembers.isEmpty ? AppColors.brandGreen : const Color(0xFF1565C0),
                // Same entry point as the Collect Payment card: a family with
                // 2+ members owing is asked single vs individual payment.
                onTap: _unpaidMembers.isEmpty
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        _startPayment(onDone: () {
                          Future.delayed(
                              const Duration(milliseconds: 300), _showCompleteSheet);
                        });
                      },
              ),

              const SizedBox(height: 12),

              // Step 2: OTP — open even with nothing paid, but then the
              // technician must give the reason first (_askNoPaymentReason).
              _CompleteStep(
                number: '2',
                title: 'Verify OTP',
                subtitle: _visitPaymentStarted
                    ? 'Ask customer for the OTP sent to their phone'
                    : 'No payment yet — you\'ll be asked for the reason, then the OTP',
                done: _currentStatus == 'OTP Verified' || _isCompleted,
                locked: false,
                buttonLabel: (_currentStatus == 'OTP Verified' || _isCompleted)
                    ? 'Verified ✓'
                    : _visitPaymentStarted ? 'Verify OTP' : 'Verify OTP without payment',
                buttonColor: AppColors.brandGreen,
                onTap: (_currentStatus == 'OTP Verified' || _isCompleted)
                    ? null
                    : () async {
                        Navigator.pop(ctx);
                        if (!_visitPaymentStarted) {
                          final reason = await _askNoPaymentReason();
                          if (reason == null || !mounted) return;
                          _noPaymentReason = reason;
                        }
                        _showOtpDialog();
                      },
              ),

              const SizedBox(height: 20),

              // Only while nothing has been paid toward the visit.
              if (!_visitPaymentStarted)
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
                      'Collect a payment (part payment is fine) — or verify the OTP without payment by entering the reason.',
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

  // ── Payment method + amount picker ────────────────────────
  // Lets the technician choose Cash or Razorpay, and optionally collect less
  // than the full amount due — a partial payment, with the remaining balance
  // settled later (e.g. at report delivery) rather than blocking this visit.
  Future<Map<String, dynamic>?> _showPaymentMethodSheet({
    required double maxAmount,
    required String subtitle,
    bool allowPartial = true,
  }) {
    // The due can carry paise (older fares, offer prices) — the box, the
    // limit shown and the check all use the same exact 2-decimal amount.
    maxAmount = (maxAmount * 100).round() / 100;
    final amountCtrl = TextEditingController(text: _inr(maxAmount));
    final reasonCtrl = TextEditingController();
    String method = 'RAZORPAY';
    String? errorText;
    String? reasonError;
    // Less than the full due → a partial payment, which needs a reason.
    double enteredAmount() => ((double.tryParse(amountCtrl.text) ?? 0) * 100).round() / 100;
    bool isPartial() => allowPartial && enteredAmount() > 0 && enteredAmount() < maxAmount - 0.001;
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          // viewInsets.bottom is the on-screen keyboard's height — without it,
          // the sheet's bottom padding only ever accounts for the safe-area
          // inset, so opening the keyboard pushes the TextField/buttons off
          // the bottom of the screen instead of the sheet shifting up to
          // stay above it.
          padding: EdgeInsets.fromLTRB(
            20, 20, 20,
            MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Collect Payment',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 18),

              if (allowPartial) ...[
                const Text('Amount to collect',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                  // Always rebuilds: the reason field follows the amount.
                  onChanged: (_) => setSheet(() { errorText = null; reasonError = null; }),
                  decoration: InputDecoration(
                    prefixText: '₹ ',
                    errorText: errorText,
                    helperText: 'Full amount due: ₹${_inr(maxAmount)} — enter less to pay partially',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                // Only for a partial payment — not needed when paying in full.
                if (isPartial()) ...[
                  const SizedBox(height: 12),
                  const Text('Reason for partial payment *',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: reasonCtrl,
                    maxLength: 255,
                    maxLines: 2,
                    minLines: 1,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) { if (reasonError != null) setSheet(() => reasonError = null); },
                    decoration: InputDecoration(
                      hintText: 'Why is only part of the amount being paid?',
                      errorText: reasonError,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ] else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Amount', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                      Text('₹${_inr(maxAmount)}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    ],
                  ),
                ),
              const SizedBox(height: 18),

              const Text('Payment method',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: _PaymentMethodChip(
                    label: 'Razorpay',
                    icon: Icons.credit_card_rounded,
                    selected: method == 'RAZORPAY',
                    onTap: () => setSheet(() => method = 'RAZORPAY'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _PaymentMethodChip(
                    label: 'UPI QR',
                    icon: Icons.qr_code_rounded,
                    selected: method == 'QR',
                    onTap: () => setSheet(() => method = 'QR'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _PaymentMethodChip(
                    label: 'Cash',
                    icon: Icons.payments_outlined,
                    selected: method == 'CASH',
                    onTap: () => setSheet(() => method = 'CASH'),
                  ),
                ),
              ]),
              const SizedBox(height: 22),

              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    final amt = enteredAmount();
                    if (amt <= 0) { setSheet(() => errorText = 'Enter an amount greater than 0'); return; }
                    if (amt > maxAmount + 0.001) { setSheet(() => errorText = 'Cannot exceed ₹${_inr(maxAmount)}'); return; }
                    final reason = reasonCtrl.text.trim();
                    if (isPartial() && reason.isEmpty) {
                      setSheet(() => reasonError = 'Please enter the reason for partial payment');
                      return;
                    }
                    Navigator.pop(ctx, {
                      'method': method,
                      'amount': amt,
                      'partialReason': isPartial() ? reason : null,
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    method == 'CASH' ? 'Confirm Cash Received'
                        : method == 'QR' ? 'Generate QR Code'
                        : 'Continue to Razorpay',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const _cancelReasons = <String, String>{
    'vehicle_issue':       'Vehicle issue',
    'personal_emergency':  'Personal emergency',
    'unreachable_patient': 'Unable to reach patient',
    'other':               'Other',
  };

  Future<Map<String, dynamic>?> _showCancelJobSheet() {
    String? reason;
    final noteCtrl = TextEditingController();
    String? errorText;
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.fromLTRB(
            20, 20, 20,
            MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Can't make it?",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              const Text(
                'This job will be released and re-dispatched to another technician. The patient keeps their booking.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              ..._cancelReasons.entries.map((e) => RadioListTile<String>(
                    value: e.key,
                    groupValue: reason,
                    onChanged: (v) => setSheet(() { reason = v; errorText = null; }),
                    title: Text(e.value, style: const TextStyle(fontSize: 13)),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: AppColors.brandGreen,
                  )),
              if (errorText != null) ...[
                const SizedBox(height: 4),
                Text(errorText!, style: const TextStyle(fontSize: 12, color: Colors.red)),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: noteCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'Add a note (optional)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    if (reason == null) { setSheet(() => errorText = 'Select a reason'); return; }
                    Navigator.pop(ctx, {'reason': reason, 'note': noteCtrl.text.trim()});
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade600,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Confirm — Release Job', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _cancelJob() async {
    final choice = await _showCancelJobSheet();
    if (choice == null || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final result = await ApiService.cancelAssignedBooking(
      bookingId: int.tryParse(widget.booking.id) ?? 0,
      reason:    choice['reason'] as String,
      note:      (choice['note'] as String?)?.isEmpty == true ? null : choice['note'] as String?,
    );
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close loading dialog

    if (result['success'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Job released — it has been re-dispatched.'),
        backgroundColor: AppColors.brandGreen,
      ));
      Navigator.pop(context, true);
    } else {
      AppMessages.error(context, AppMessages.serverMessage(result['message'],
          fallback: 'We couldn\'t release this job. Please try again.'));
    }
  }

  void _collectPayment({VoidCallback? onDone}) async {
    final choice = await _showPaymentMethodSheet(
      maxAmount: _amountDue,
      subtitle: 'Tests + service charge due for ${widget.booking.customerName}',
    );
    if (choice == null || !mounted) return;
    final method = choice['method'] as String;
    final amount = choice['amount'] as double;
    final partialReason = choice['partialReason'] as String?;

    if (method == 'CASH') {
      await _collectCashPayment(amount: amount, partialReason: partialReason, onDone: onDone);
      return;
    }

    if (method == 'QR') {
      final bookingId = int.tryParse(widget.booking.id) ?? 0;
      final paymentId = await _showQrPaymentSheet(bookingId: bookingId, amount: amount, partialReason: partialReason);
      if (!mounted) return;
      if (paymentId != null) {
        final stillDue = amount < _amountDue;
        setState(() {
          _sessionPaymentCollected += amount;
          _livePaymentStatus       = stillDue ? 'partial' : 'paid';
        });
        AppMessages.success(context, 'UPI payment of ₹${_inr(amount)} received');
        onDone?.call();
        _refreshPaymentInfo();
      }
      return;
    }

    setState(() => _isProcessingPayment = true);

    final options = {
      'key': AppConstants.razorpayKeyId,
      'amount': (amount * 100).round(),
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
        // Capture amount before state changes
        final paidAmount      = amount;
        final bookingId       = int.tryParse(widget.booking.id) ?? 0;
        final stillDue        = paidAmount < _amountDue;
        setState(() {
          _isProcessingPayment     = false;
          _sessionPaymentCollected += paidAmount;
          _livePaymentStatus       = stillDue ? 'partial' : 'paid';
        });
        AppMessages.success(context, 'Payment of ₹${_inr(paidAmount)} received. Ref: $paymentId');
        onDone?.call();
        // Persist to DB and refresh live payment state from server
        () async {
          final ok = await ApiService.collectPayment(
            bookingId: bookingId,
            razorpayPaymentId: paymentId,
            amount: paidAmount,
            paymentMethod: 'RAZORPAY',
            partialReason: partialReason,
          );
          if (mounted) _refreshPaymentInfo();
          if (!ok && mounted) {
            AppMessages.warning(context,
                'Payment received, but it didn\'t save to MicroLab. Note the ref $paymentId and tell support.',
                duration: const Duration(seconds: 8));
          }
        }();
      },
      onError: (msg) {
        setState(() => _isProcessingPayment = false);
        AppMessages.isPaymentCancelled(msg)
            ? AppMessages.info(context, AppMessages.paymentError(msg))
            : AppMessages.error(context, AppMessages.paymentError(msg));
      },
    );
  }

  // Cash counterpart to _collectPayment — no Razorpay checkout, just a direct
  // server record. Supports the same partial-amount capability.
  Future<void> _collectCashPayment({required double amount, String? partialReason, VoidCallback? onDone}) async {
    setState(() => _isProcessingPayment = true);
    final bookingId      = int.tryParse(widget.booking.id) ?? 0;
    final stillDue       = amount < _amountDue;

    final ok = await ApiService.collectPayment(
      bookingId: bookingId,
      amount: amount,
      paymentMethod: 'CASH',
      partialReason: partialReason,
    );
    if (!mounted) return;
    setState(() {
      _isProcessingPayment = false;
      if (ok) {
        _sessionPaymentCollected += amount;
        _livePaymentStatus       = stillDue ? 'partial' : 'paid';
      }
    });
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('₹${_inr(amount)} cash received'),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      onDone?.call();
      _refreshPaymentInfo();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Failed to record cash payment — please retry'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // Collect payment for a visit-member's sibling booking (separate from the parent's payment)
  void _collectVisitMemberPayment({
    required int siblingBookingId,
    required double amountDue,
    required String patientName,
  }) async {
    if (amountDue <= 0) return;
    final choice = await _showPaymentMethodSheet(
      maxAmount: amountDue,
      subtitle: 'Tests due for $patientName',
    );
    if (choice == null || !mounted) return;
    final method = choice['method'] as String;
    final amount = choice['amount'] as double;
    final partialReason = choice['partialReason'] as String?;
    final stillDue = amount < amountDue;

    void applyLocalUpdate(String paymentId) {
      if (!mounted) return;
      setState(() {
        _linkedPatients = _linkedPatients.map((p) {
          if ((p['booking_id'] as num?)?.toInt() == siblingBookingId) {
            return {...p, 'payment_status': stillDue ? 'partial' : 'paid', 'amount_due': stillDue ? amountDue - amount : 0.0};
          }
          return p;
        }).toList();
      });
      AppMessages.success(context, '₹${_inr(amount)} received for $patientName. Ref: $paymentId');
    }

    if (method == 'CASH') {
      final ok = await ApiService.collectPayment(
        bookingId: siblingBookingId,
        amount: amount,
        paymentMethod: 'CASH',
        partialReason: partialReason,
      );
      if (ok) {
        applyLocalUpdate('cash');
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to record cash payment — please retry'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
      }
      if (mounted) _loadLinkedPatients();
      return;
    }

    if (method == 'QR') {
      final paymentId = await _showQrPaymentSheet(bookingId: siblingBookingId, amount: amount, partialReason: partialReason);
      if (paymentId != null && mounted) {
        applyLocalUpdate(paymentId);
        _loadLinkedPatients();
      }
      return;
    }

    final options = {
      'key': AppConstants.razorpayKeyId,
      'amount': (amount * 100).round(),
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
        // Optimistic UI update
        applyLocalUpdate(paymentId);
        final ok = await ApiService.collectPayment(
          bookingId: siblingBookingId,
          razorpayPaymentId: paymentId,
          amount: amount,
          paymentMethod: 'RAZORPAY',
          partialReason: partialReason,
        );
        if (!ok && mounted) {
          AppMessages.warning(context,
              'Payment received, but it didn\'t save to MicroLab. Note the ref $paymentId and tell support.',
              duration: const Duration(seconds: 8));
        }
        // Refresh the list to get accurate server state
        if (mounted) _loadLinkedPatients();
      },
      onError: (msg) {
        if (mounted) {
          AppMessages.isPaymentCancelled(msg)
              ? AppMessages.info(context, AppMessages.paymentError(msg))
              : AppMessages.error(context, AppMessages.paymentError(msg));
        }
      },
    );
  }

  // Shows a QR code sheet and polls until the customer pays or cancels.
  // Returns the Razorpay payment ID on success, null if dismissed without payment.
  // Pass [bookingIds] for combined family QR so the server validates against total due.
  Future<String?> _showQrPaymentSheet({
    required int bookingId,
    required double amount,
    List<int>? bookingIds,
    String? partialReason,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _QrPaymentSheet(bookingId: bookingId, amount: amount, bookingIds: bookingIds, partialReason: partialReason),
    );
  }

  // Collects a single combined payment (Razorpay or Cash) for all unpaid
  // bookings (parent + siblings), at the full combined amount — partial
  // payment is not supported here, since splitting a partial amount fairly
  // across multiple bookings has no well-defined rule. For partial payment,
  // collect each booking individually via _collectPayment/_collectVisitMemberPayment.
  // For Razorpay, each booking's ip_payment_transactions row is updated
  // individually using the same Razorpay payment ID — existing per-booking
  // data structure is not changed. For Cash, each booking gets its own
  // separate collectPayment call (no shared gateway reference to reuse).
  void _collectAllPayment({VoidCallback? onDone}) async {
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
      if (sibId != null && due > 0) {
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

    final choice = await _showPaymentMethodSheet(
      maxAmount: totalAmount,
      subtitle: 'Combined payment · ${unpaidItems.length} members',
    );
    if (choice == null || !mounted) return;
    final method        = choice['method'] as String;
    final enteredAmount = choice['amount'] as double;
    final partialReason = choice['partialReason'] as String?;

    // Sequential/waterfall allocation: fill each booking's due amount in list
    // order (parent first, then siblings) until the entered amount runs out.
    // A booking with zero allocated here is untouched — no collectPayment call,
    // its payment_status stays exactly as it was.
    double remaining = enteredAmount;
    final allocations = unpaidItems.map((item) {
      final due       = item['amount'] as double;
      final allocated = remaining <= 0 ? 0.0 : (remaining >= due ? due : remaining);
      remaining -= allocated;
      return {...item, 'allocated': allocated};
    }).toList();
    final toCharge = allocations.where((a) => (a['allocated'] as double) > 0).toList();

    void applySuccessState(String paymentRef) {
      setState(() {
        _isProcessingPayment = false;
        for (final a in allocations) {
          final allocated = a['allocated'] as double;
          if (allocated <= 0) continue;
          final due        = a['amount'] as double;
          final fullyPaid  = allocated >= due;
          if (a['isParent'] == true) {
            _sessionPaymentCollected += allocated;
            if (fullyPaid) {
              _livePaymentStatus = 'paid';
            } else {
              _livePaymentStatus = 'partial';
            }
          } else {
            final sibId = a['bookingId'] as int;
            _linkedPatients = _linkedPatients.map((p) {
              if ((p['booking_id'] as num?)?.toInt() != sibId) return p;
              return {
                ...p,
                'payment_status': fullyPaid ? 'paid' : 'partial',
                'amount_due':     (due - allocated).clamp(0, due),
              };
            }).toList();
          }
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:         Text('₹${_inr(enteredAmount)} received · $paymentRef'),
        backgroundColor: AppColors.brandGreen,
        behavior:        SnackBarBehavior.floating,
        shape:           RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }

    if (method == 'CASH') {
      setState(() => _isProcessingPayment = true);
      var allOk = true;
      for (final a in toCharge) {
        final ok = await ApiService.collectPayment(
          bookingId:     a['bookingId'] as int,
          amount:        a['allocated'] as double,
          paymentMethod: 'CASH',
          partialReason: partialReason,
        );
        if (!ok) allOk = false;
      }
      if (!mounted) return;
      applySuccessState('cash');
      if (!allOk) {
        AppMessages.warning(context,
            'Some cash payments didn\'t save to MicroLab. Please tell support which patients paid.',
            duration: const Duration(seconds: 8));
      }
      _refreshPaymentInfo();
      _loadLinkedPatients();
      onDone?.call();
      return;
    }

    if (method == 'QR') {
      final allBookingIds = toCharge.map((a) => a['bookingId'] as int).toList();
      final primaryId     = allBookingIds.first;
      final paymentId     = await _showQrPaymentSheet(
        bookingId:  primaryId,
        amount:     enteredAmount,
        bookingIds: allBookingIds.length > 1 ? allBookingIds : null,
        partialReason: partialReason,
      );
      if (!mounted) return;
      if (paymentId != null) {
        setState(() => _isProcessingPayment = true);
        var allOk = true;
        for (final a in toCharge) {
          final ok = await ApiService.collectPayment(
            bookingId:         a['bookingId'] as int,
            razorpayPaymentId: paymentId,
            amount:            a['allocated'] as double,
            paymentMethod:     'QR',
            partialReason:     partialReason,
          );
          if (!ok) allOk = false;
        }
        if (mounted) {
          applySuccessState(paymentId);
          if (!allOk) {
            AppMessages.warning(context,
                'QR payment received, but it didn\'t save for every member. Note ref $paymentId and tell support.',
                duration: const Duration(seconds: 8));
          }
          _refreshPaymentInfo();
          _loadLinkedPatients();
          onDone?.call();
        }
      }
      if (mounted) setState(() => _isProcessingPayment = false);
      return;
    }

    setState(() => _isProcessingPayment = true);

    openRazorpay(
      options: {
        // Same configured key as every other payment (was a hard-coded test key).
        'key':         AppConstants.razorpayKeyId,
        'amount':      (enteredAmount * 100).round(),
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
        applySuccessState(paymentId);
        // Persist each booking's record individually with the same Razorpay ID
        var allOk = true;
        for (final a in toCharge) {
          final ok = await ApiService.collectPayment(
            bookingId:         a['bookingId'] as int,
            razorpayPaymentId: paymentId,
            amount:            a['allocated'] as double,
            paymentMethod:     'RAZORPAY',
            partialReason:     partialReason,
          );
          if (!ok) allOk = false;
        }
        if (mounted) {
          if (!allOk) {
            AppMessages.warning(context,
                'Payment received, but it didn\'t save to MicroLab for every member. Note the ref $paymentId and tell support.',
                duration: const Duration(seconds: 8));
          }
          _refreshPaymentInfo();
          _loadLinkedPatients();
          onDone?.call();
        }
      },
      onError: (msg) {
        if (mounted) {
          setState(() => _isProcessingPayment = false);
          AppMessages.isPaymentCancelled(msg)
              ? AppMessages.info(context, AppMessages.paymentError(msg))
              : AppMessages.error(context, AppMessages.paymentError(msg));
        }
      },
    );
  }

  // ── Family payment choice ─────────────────────────────────
  // Everyone on this visit who still owes something: the main patient (if
  // their booking isn't fully paid) and each family member with an amount due.
  List<({int bookingId, String name, double amount, bool isParent})> get _unpaidMembers => [
        if (!_paymentDone && _amountDue > 0)
          (bookingId: int.tryParse(widget.booking.id) ?? 0,
           name: widget.booking.customerName, amount: _amountDue, isParent: true),
        for (final p in _linkedPatients)
          if ((p['booking_id'] as num?) != null &&
              (double.tryParse(p['amount_due']?.toString() ?? '0') ?? 0.0) > 0)
            (bookingId: (p['booking_id'] as num).toInt(),
             name: p['patient_name'] as String? ?? 'Visit Member',
             amount: double.tryParse(p['amount_due']?.toString() ?? '0') ?? 0.0,
             isParent: false),
      ];

  double get _unpaidTotal => _unpaidMembers.fold(0.0, (s, m) => s + m.amount);

  // Collect one member's payment (Cash or Razorpay, full or partial).
  void _collectForMember(({int bookingId, String name, double amount, bool isParent}) m,
      {VoidCallback? onDone}) {
    if (m.isParent) {
      _collectPayment(onDone: onDone);
    } else {
      _collectVisitMemberPayment(siblingBookingId: m.bookingId, amountDue: m.amount, patientName: m.name);
    }
  }

  // Entry point for every "collect payment" tap. One member owing → that
  // payment directly. A family with 2+ members owing → ask once how they want
  // to pay: one combined payment, or individually in any order. Partial
  // amounts are allowed either way (entered in the payment sheet).
  Future<void> _startPayment({VoidCallback? onDone}) async {
    final members = _unpaidMembers;
    if (members.isEmpty) return;
    if (members.length == 1) {
      _collectForMember(members.first, onDone: onDone);
      return;
    }

    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('How would the family like to pay?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          _PayModeOption(
            icon: Icons.payments_outlined,
            title: 'Single payment',
            subtitle: 'One payment of ₹${_inr(_unpaidTotal)} for all ${members.length} members',
            onTap: () => Navigator.pop(ctx, 'combined'),
          ),
          const SizedBox(height: 10),
          _PayModeOption(
            icon: Icons.people_alt_outlined,
            title: 'Individual payments',
            subtitle: 'Each member pays their own amount, in any order',
            onTap: () => Navigator.pop(ctx, 'individual'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary))),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    setState(() => _familyPayMode = mode);

    if (mode == 'combined') {
      _collectAllPayment(onDone: onDone);
    } else {
      _showIndividualPaySheet(onDone: onDone);
    }
  }

  // Individual mode: every member who still owes, each with their own
  // "Collect" button — the technician picks whoever is paying now.
  void _showIndividualPaySheet({VoidCallback? onDone}) {
    final members = _unpaidMembers;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(ctx).padding.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          const Text('Individual payments',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 4),
          const Text('Choose who is paying now. Partial amounts are allowed.',
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          const SizedBox(height: 14),
          for (final m in members)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _collectForMember(m, onDone: onDone);
                  },
                  icon: const Icon(Icons.payment_outlined, size: 18),
                  label: Text('Collect ₹${_inr(m.amount)} · ${m.name}',
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
            ),
        ]),
      ),
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
        if (!didPop) _exitScreen();
      },
      child: Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
          onPressed: _exitScreen,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Manage Booking',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            if (widget.booking.referenceNo != null)
              Text(widget.booking.referenceNo!,
                  style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 11)),
          ],
        ),
        actions: [
          IconButton(
            icon: _isReloading
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.refresh_rounded, color: Colors.white),
            tooltip: 'Reload booking details',
            onPressed: _isReloading ? null : _reloadBookingData,
          ),
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
          // Only before travel starts — matches the server-side gate exactly
          // (collection_status must still be 'assigned').
          if (_currentStatus == 'Confirmed')
            IconButton(
              icon: const Icon(Icons.cancel_outlined, color: Colors.white),
              tooltip: "Can't make it",
              onPressed: _cancelJob,
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
          // Same action as the bottom bar button (see _currentAction).
          if (isCurrent && _currentAction != null) ...[
  const SizedBox(width: 8),
  GestureDetector(
    onTap: _currentAction!.onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _currentStatus == 'Journey Started' ? const Color(0xFF1565C0) : step.color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '${_currentAction!.label} ▸',
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
              if (widget.booking.collectionNotes != null && widget.booking.collectionNotes!.isNotEmpty)
                _InfoRow(Icons.notes_outlined, 'Notes', widget.booking.collectionNotes!),
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
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
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
                          child: const Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                        ),
                      ],
                    ]),
                    // Collection checklist — visible from "Collection Started"
                    // onward. Purely a per-item tracking toggle: does not gate
                    // or affect the "Sample Collected" step in any way.
                    if (_showCollectionChecklist) ...[
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => _toggleItemCollected(t['id'] ?? '', t['collected'] != 'completed'),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            t['collected'] == 'completed'
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 16,
                            color: t['collected'] == 'completed' ? AppColors.brandGreen : AppColors.textHint,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            t['collected'] == 'completed' ? 'Collected' : 'Pending',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: t['collected'] == 'completed' ? AppColors.brandGreen : AppColors.textHint,
                            ),
                          ),
                        ]),
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
                        onTap: _addingTests ? null : _closeAddTest,
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
                  // Multi-select: tick any number of tests/packages, then
                  // "Add N selected" adds them all. Ticks survive changing
                  // the search text.
                  ...() {
                    final results = _filteredCatalogue;
                    final selectedTotal = _catalogueItems
                        .where((t) => _pendingTestIds.contains(t['id']))
                        .fold<double>(0, (s, t) => s + (double.tryParse(t['price'] ?? '0') ?? 0));
                    return <Widget>[
                      Container(
                        // Fixed height (not shrinkWrap) so a large catalogue
                        // only builds the rows on screen.
                        height: results.isEmpty ? null : (results.length * 58.0).clamp(58.0, 300.0),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.divider),
                        ),
                        child: results.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.symmetric(vertical: 18),
                                child: Center(
                                  child: Text('No tests found',
                                      style: TextStyle(fontSize: 13, color: AppColors.textHint)),
                                ),
                              )
                            : ListView.separated(
                                padding: EdgeInsets.zero,
                                itemCount: results.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final t = results[i];
                                  final id = t['id'] ?? '';
                                  return CheckboxListTile(
                                    value: _pendingTestIds.contains(id),
                                    onChanged: _addingTests
                                        ? null
                                        : (v) => setState(() {
                                              if (v == true) {
                                                _pendingTestIds.add(id);
                                              } else {
                                                _pendingTestIds.remove(id);
                                              }
                                            }),
                                    activeColor: AppColors.brandGreen,
                                    dense: true,
                                    controlAffinity: ListTileControlAffinity.leading,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                                    title: Text(t['name'] ?? '',
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                    subtitle: (t['category'] ?? '').isEmpty
                                        ? null
                                        : Text(t['category']!,
                                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                    secondary: Text('₹${t['price']}',
                                        style: const TextStyle(
                                            fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 10),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _addingTests ? null : _closeAddTest,
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
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: (_pendingTestIds.isEmpty || _addingTests) ? null : _addSelectedTests,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.brandGreen,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: _addingTests
                                ? const SizedBox(
                                    width: 18, height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : Text(
                                    _pendingTestIds.isEmpty
                                        ? 'Select tests to add'
                                        : 'Add ${_pendingTestIds.length} selected · ₹${_inr(selectedTotal)}',
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                          ),
                        ),
                      ]),
                    ];
                  }(),
                ],
              ],
            ),
          ),

          const SizedBox(height: 14),

          // ── Sample Collection Photo ──────────────────────────
          // Optional real-time proof photo. Visible from "Collection Started"
          // onward (same gate as the checklist, _showCollectionChecklist) so
          // it stays available for the whole collection window — a
          // technician who skips it at first still has a clear "Take Photo"
          // entry point later, and can retake it any time before completing
          // the flow. Does not gate or otherwise affect Sample Collected,
          // the checklist, or any booking status transition.
          if (_showCollectionChecklist) _SectionCard(
            title: 'Sample Collection Photo',
            icon: Icons.camera_alt_outlined,
            child: _collectionProofLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                  )
                // One block per patient in this visit (primary + any family
                // members) — each keyed to their own booking_id via
                // _proofUrlByBookingId, so one patient's photo never
                // overwrites or is shown for another patient.
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final patient in _visitPatients) ...[
                      Builder(builder: (context) {
                        // Everything here is keyed by this patient's own
                        // booking id (always known — the primary patient's
                        // patient id is not, e.g. when opened from the live
                        // map). isCapturing must never be true for "no id":
                        // that left a box spinning on "Opening camera…"
                        // forever with its tap disabled.
                        final patientBookingId = patient['bookingId'] as int?;
                        final pname         = patient['name'] as String;
                        final proofUrl      = patientBookingId != null ? _proofUrlByBookingId[patientBookingId] : null;
                        final isCapturing   = patientBookingId != null && _capturingProofBookingId == patientBookingId;
                        final canCapture    = patientBookingId != null;
                        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text(pname,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                              decoration: BoxDecoration(
                                color: proofUrl != null
                                    ? AppColors.brandGreenSurface
                                    : const Color(0xFFFFF3E0),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                proofUrl != null ? 'ADDED' : 'NOT ADDED',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  color: proofUrl != null
                                      ? AppColors.brandGreen
                                      : const Color(0xFFE65100),
                                ),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 10),
                          if (proofUrl == null)
                            GestureDetector(
                              // While busy, a tap cancels (camera or upload
                              // step) — see _cancelProofCapture.
                              onTap: !canCapture
                                  ? null
                                  : isCapturing
                                      ? _cancelProofCapture
                                      : (_capturingProofBookingId != null
                                          ? null // another patient's photo is in progress
                                          : () => _captureAndUploadCollectionProof(
                                              bookingId: patientBookingId)),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(vertical: 22),
                                decoration: BoxDecoration(
                                  color: AppColors.background,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppColors.divider, width: 1.5),
                                ),
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  isCapturing
                                      ? const SizedBox(
                                          width: 22, height: 22,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen),
                                        )
                                      : const Icon(Icons.camera_alt_outlined, size: 22, color: AppColors.textHint),
                                  const SizedBox(height: 6),
                                  Text(
                                    !isCapturing
                                        ? 'Take Collection Photo'
                                        : switch (_proofStep) {
                                            _ProofStep.camera    => 'Opening camera…',
                                            _ProofStep.uploading => 'Uploading photo…',
                                            _ProofStep.saving    => 'Saving photo…',
                                          },
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textSecondary),
                                  ),
                                  if (isCapturing && _proofStep != _ProofStep.saving) ...[
                                    const SizedBox(height: 2),
                                    const Text('Tap to cancel',
                                        style: TextStyle(fontSize: 10.5, color: AppColors.textHint)),
                                  ],
                                ]),
                              ),
                            )
                          else
                            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              // Thumbnail with a ✕ to remove the photo — the
                              // same style as prescription thumbnails. Hidden
                              // once the visit is OTP-verified (the server
                              // also refuses then) and while any photo is
                              // being captured or removed.
                              Stack(clipBehavior: Clip.none, children: [
                                GestureDetector(
                                  onTap: () => _viewCollectionProofImage(proofUrl),
                                  child: Container(
                                    width: 88,
                                    height: 88,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: AppColors.divider),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: _removingProofBookingId == patientBookingId
                                          ? const Center(child: SizedBox(width: 22, height: 22,
                                              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)))
                                          : Image.network(
                                              proofUrl,
                                              fit: BoxFit.cover,
                                              loadingBuilder: (_, child, progress) => progress == null
                                                  ? child
                                                  : const Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                                              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: AppColors.textHint),
                                            ),
                                    ),
                                  ),
                                ),
                                if (!_isFinalized && canCapture &&
                                    _capturingProofBookingId == null && _removingProofBookingId == null)
                                  Positioned(
                                    top: -6, right: -6,
                                    child: Semantics(
                                      button: true,
                                      label: 'Remove photo for $pname',
                                      child: GestureDetector(
                                        onTap: () => _confirmRemoveCollectionProof(
                                            bookingId: patientBookingId, patientName: pname),
                                        child: Container(
                                          width: 24, height: 24,
                                          decoration: const BoxDecoration(color: Color(0xFFD32F2F), shape: BoxShape.circle),
                                          child: const Icon(Icons.close_rounded, size: 15, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ),
                              ]),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  const Text('Proof photo captured',
                                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    onPressed: (!canCapture || isCapturing) ? null : () =>
                                        _captureAndUploadCollectionProof(bookingId: patientBookingId),
                                    icon: isCapturing
                                        ? const SizedBox(
                                            width: 14, height: 14,
                                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen),
                                          )
                                        : const Icon(Icons.refresh_rounded, size: 16),
                                    label: Text(isCapturing ? 'Retaking…' : 'Retake Photo'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: AppColors.brandGreen,
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(0, 0),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                  ),
                                ]),
                              ),
                            ]),
                        ]);
                      }),
                      if (patient != _visitPatients.last) const SizedBox(height: 14),
                    ],
                  ]),
          ),

          const SizedBox(height: 14),

          // ── Prescription / Document ─────────────────────────
          // Shown only when the booking requires a prescription OR when
          // documents have already been uploaded (to avoid hiding existing uploads).
          if (_anyDocRequired || _docUploads.isNotEmpty) _SectionCard(
            title: 'Prescription / Document',
            icon: Icons.description_outlined,
            badge: _anyDocRequired ? 'REQUIRED' : null,
            child: _docsLoading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _anyDocRequired
                      ? const Color(0xFFFFF3E0)
                      : AppColors.brandGreenSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _anyDocRequired
                        ? const Color(0xFFFFCC02).withOpacity(0.4)
                        : AppColors.brandGreenLight,
                  ),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    _anyDocRequired
                        ? Icons.warning_amber_rounded
                        : Icons.info_outline_rounded,
                    size: 13,
                    color: _anyDocRequired
                        ? const Color(0xFFE65100)
                        : AppColors.brandGreen,
                  ),
                  const SizedBox(width: 7),
                  Expanded(child: Text(
                    _anyDocRequired
                        ? 'A doctor\'s prescription is required — mandatory for every patient whose test needs one. Upload and verify each before collecting samples.'
                        : 'Upload prescription if provided by the customer.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: _anyDocRequired
                          ? const Color(0xFF795548)
                          : AppColors.brandGreen,
                    ),
                  )),
                ]),
              ),
              const SizedBox(height: 12),

              // One section per patient in this visit (primary + any family
              // members). Each prescription is fetched already tagged with
              // patient_id (see _loadDocs), so filtering here shows only that
              // patient's own document(s) — never another member's by mistake.
              // Upload is available for EVERY patient (not just primary) —
              // attributed to that patient's own booking_id/patient_id, the
              // same pattern the customer app already uses successfully for
              // family bookings (see savePrescription's bookingId/patientId
              // params — it was never primary-only server-side).
              ..._visitPatients.map((patient) {
                final pid          = patient['id'] as int?;
                final patientBookingId = patient['bookingId'] as int?;
                final pname        = patient['name'] as String;
                final needsDoc     = _patientDocRequired[pid] == true;
                final patientDocs  = _docUploads.where((d) => d.patientId == pid).toList();
                final canUpload    = pid != null && patientBookingId != null;
                debugPrint('[render] patient=$pname (id=$pid) docs=${patientDocs.length} needsDoc=$needsDoc');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(pname,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        if (needsDoc && patientDocs.isEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('REQUIRED',
                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFE65100))),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 8),
                      if (patientDocs.isEmpty)
                        canUpload
                            ? GestureDetector(
                                onTap: _docIsPicking
                                    ? null
                                    : () => _showDocSourcePicker(
                                        targetBookingId: patientBookingId, targetPatientId: pid),
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
                              )
                            : Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                decoration: BoxDecoration(
                                  color: AppColors.background,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.divider),
                                ),
                                child: const Center(
                                  child: Text('No Prescription Uploaded',
                                      style: TextStyle(
                                          fontSize: 12, color: AppColors.textHint, fontStyle: FontStyle.italic)),
                                ),
                              )
                      else
                        SizedBox(
                          height: 104,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: patientDocs.length +
                                (canUpload && patientDocs.length < _docMaxFiles ? 1 : 0),
                            separatorBuilder: (_, __) => const SizedBox(width: 8),
                            itemBuilder: (_, i) {
                              if (i == patientDocs.length) {
                                return _DocAddMoreTile(
                                  onTap: _docIsPicking
                                      ? null
                                      : () => _showDocSourcePicker(
                                          targetBookingId: patientBookingId!, targetPatientId: pid!),
                                );
                              }
                              final doc = patientDocs[i];
                              return _DocThumbnailCard(
                                doc: doc,
                                onView: () => _viewDocImage(doc),
                                onDelete: () => _deleteDocImage(doc),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                );
              }),

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

          // ── Billing Summary ──────────────────────────────
          const SizedBox(height: 14),
          _billingSummaryCard(),
          const SizedBox(height: 14),

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
                          ? (_livePaymentStatus == 'paid'
                              ? 'Service charge ₹${_inr(_serviceCharge)} paid at booking. All tests also paid.'
                              : 'All dues collected — service charge ₹${_inr(_serviceCharge)} + tests.')
                          : _livePaymentStatus == 'paid'
                              ? 'Original booking (₹${_inr(_liveAmountPaid)}) paid. Collect ${_additionalCharge > 0 ? 'balance due' : 'additional tests'}: ₹${_inr(_amountDue)}'
                              : 'Service charge ₹${_inr(_serviceCharge)} not yet paid. Collect total due: ₹${_inr(_amountDue)}',
                      style: const TextStyle(fontSize: 12, color: AppColors.brandGreen, height: 1.4),
                    )),
                  ]),
                ),
                const SizedBox(height: 12),

                // Charges added on site — charge packages, plus any charge typed
                // in with an older app version — already inside each booking's
                // amount due (see the Billing Summary above).
                ...() {
                  final editable = _canEditAdditionalCharge;
                  final typed = _additionalChargeTargets
                      .map((t) => (target: t, amount: _typedChargeFor(t.bookingId, t.amount)))
                      .where((t) => t.amount > 0)
                      .toList();
                  if (_chargePackages.isEmpty && typed.isEmpty && !editable) return <Widget>[];
                  final showMember = _linkedPatients.isNotEmpty;
                  return [
                    ..._chargePackages.map<Widget>((c) => _ChargeCard(
                      title:  c['name'] as String? ?? 'Charge package',
                      member: showMember ? _memberNameFor((c['bookingId'] as num?)?.toInt()) : null,
                      reason: c['reason'] as String?,
                      amount: (c['price'] as num?)?.toDouble() ?? 0.0,
                      onRemove: editable && !_savingAdditionalCharge ? () => _removeChargePackage(c) : null,
                    )),
                    ...typed.map<Widget>((t) => _ChargeCard(
                      title:  'Additional charge',
                      member: showMember ? t.target.name : null,
                      reason: t.target.reason,
                      amount: t.amount,
                      onRemove: editable && !_savingAdditionalCharge
                          ? () => _removeTypedCharge(t.target.bookingId, t.amount)
                          : null,
                    )),
                    if (editable)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _savingAdditionalCharge ? null : _addChargePackages,
                          icon: _savingAdditionalCharge
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add charge package',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          style: TextButton.styleFrom(foregroundColor: AppColors.brandGreen),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ];
                }(),

                // Family visit, 2+ members owing: one "Collect Payment" button
                // that asks how they want to pay (_startPayment). Once they
                // chose individual payments, the per-member buttons below are
                // shown instead, with a link back to a single payment.
                ...() {
                  final members     = _unpaidMembers;
                  final totalUnpaid = members.length;
                  if (totalUnpaid < 2) return <Widget>[];
                  final totalAmount = _unpaidTotal;
                  if (_familyPayMode == 'individual') {
                    return [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _isProcessingPayment ? null : () {
                            setState(() => _familyPayMode = 'combined');
                            _collectAllPayment();
                          },
                          icon: const Icon(Icons.payments_outlined, size: 16),
                          label: Text('Pay together instead · ₹${_inr(totalAmount)}',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          style: TextButton.styleFrom(foregroundColor: AppColors.brandGreen),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ];
                  }
                  return [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isProcessingPayment ? null : () => _startPayment(),
                        icon: _isProcessingPayment
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.payments_outlined, size: 18),
                        label: Text(
                          _isProcessingPayment
                              ? 'Processing…'
                              : 'Collect Payment · ₹${_inr(totalAmount)} · $totalUnpaid members',
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

                // Per-member buttons — shown when exactly one booking is unpaid,
                // or for a family that chose individual payments (any order).
                // A family that hasn't chosen yet gets the single "Collect
                // Payment" button above instead.
                ...() {
                  final parentUnpaid   = !_paymentDone && _amountDue > 0;
                  final unpaidSiblings = _linkedPatients.where((c) {
                    final sibId = (c['booking_id'] as num?)?.toInt();
                    final due   = double.tryParse(c['amount_due']?.toString() ?? '0') ?? 0.0;
                    return sibId != null && due > 0;
                  }).toList();
                  if ((parentUnpaid ? 1 : 0) + unpaidSiblings.length >= 2 &&
                      _familyPayMode != 'individual') return <Widget>[];

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
                              : 'Collect ₹${_inr(_amountDue)} · ${widget.booking.customerName}',
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
                          label: Text('Collect ₹${_inr(due)} · $mName',
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
                    final isPaid      = amountDue <= 0;
                    final hasPayment  = (c['booking_id'] as num?) != null && totalAmount > 0;
                    final memberBookingId = (c['booking_id'] as num?)?.toInt();
                    final memberItems     = memberBookingId != null ? _familyItems[memberBookingId] : null;
                    // ✕ only for members the technician added this visit, while
                    // nothing is collected or paid for them. Members from the
                    // customer's booking stay (the server checks all of it again).
                    final addedByTech  = c['source_channel'] == 'technician_app';
                    final anyCollected = memberItems?.any((t) => t['collected'] == 'completed') ?? false;
                    final paidSome     = totalAmount - amountDue > 0.009;
                    final canRemove    = !_isFinalized && memberBookingId != null && addedByTech
                        && !anyCollected && !paidSome;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.brandGreenLight),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.check_circle_outline_rounded, size: 16, color: AppColors.brandGreen),
                          const SizedBox(width: 8),
                          Expanded(child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${c['patient_name'] ?? ''}  ·  ${c['patient_mobile'] ?? ''}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                              if ((c['reference_no'] as String?) != null)
                                Text(c['reference_no'] as String,
                                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                              if ((c['doctor_name']?.toString().trim() ?? '').isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(children: [
                                    const Icon(Icons.local_hospital_outlined, size: 12, color: AppColors.textSecondary),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text('Doctor: ${c['doctor_name'].toString().trim()}',
                                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                    ),
                                  ]),
                                ),
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
                                  child: Text('₹${_inr(amountDue)} due',
                                      style: const TextStyle(fontSize: 11, color: Color(0xFF1565C0), fontWeight: FontWeight.w600)),
                                ),
                          if (canRemove) ...[
                            const SizedBox(width: 6),
                            InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => _confirmRemoveMember(c, memberBookingId),
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                              ),
                            ),
                          ],
                        ]),
                        // Family member's tests — always shown (edit + checklist).
                        if (memberBookingId != null && memberItems != null && memberItems.isNotEmpty) ...[
                          const Divider(height: 16),
                          ...memberItems.map((t) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(children: [
                              if (_showCollectionChecklist)
                                GestureDetector(
                                  onTap: () => _toggleItemCollected(
                                    t['id'] ?? '', t['collected'] != 'completed',
                                    targetBookingId: memberBookingId,
                                  ),
                                  child: Icon(
                                    t['collected'] == 'completed'
                                        ? Icons.check_circle_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    size: 15,
                                    color: t['collected'] == 'completed' ? AppColors.brandGreen : AppColors.textHint,
                                  ),
                                )
                              else
                                const Icon(Icons.circle_outlined, size: 8, color: AppColors.brandGreen),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(t['name'] ?? '',
                                    style: const TextStyle(fontSize: 12)),
                              ),
                              Text('₹${t['price'] ?? '0'}',
                                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                              if (!_isFinalized) ...[
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () => _removeFamilyTest(t['id'] ?? '', memberBookingId),
                                  child: const Icon(Icons.close_rounded, size: 16, color: AppColors.textHint),
                                ),
                              ],
                            ]),
                          )),
                        ],
                        if (!_isFinalized && memberBookingId != null) ...[
                          const SizedBox(height: 6),
                          GestureDetector(
                            onTap: () => _showAddFamilyTestSheet(memberBookingId),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                color: AppColors.brandGreenSurface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppColors.brandGreenLight),
                              ),
                              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Icon(Icons.add_circle_outline, size: 14, color: AppColors.brandGreen),
                                SizedBox(width: 6),
                                Text('Add Test / Package',
                                    style: TextStyle(fontSize: 12, color: AppColors.brandGreen, fontWeight: FontWeight.w500)),
                              ]),
                            ),
                          ),
                        ],
                        if (memberBookingId != null &&
                            (_familyPendingRefund[memberBookingId] ?? 0) > 0.5) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            const Icon(Icons.info_outline_rounded, size: 13, color: Color(0xFFE65100)),
                            const SizedBox(width: 4),
                            Text(
                              'Refund ₹${_inr((_familyPendingRefund[memberBookingId]!))} pending',
                              style: const TextStyle(fontSize: 12, color: Color(0xFFE65100), fontWeight: FontWeight.w500),
                            ),
                          ]),
                        ],
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
              // Main action of the screen: the same next step as the Journey
              // Status card's button (_currentAction), with the same checks
              // and dialogs. Everything on this screen already saves as it
              // happens, so there is no separate "save". After Handed to Lab
              // it reads "Done" and returns to the Dashboard.
              child: SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isCompleted ? _exitScreen : (_currentAction?.onTap ?? _exitScreen),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.divider,
                    disabledForegroundColor: AppColors.textSecondary,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    _isCompleted ? 'Done' : (_currentAction?.label ?? 'Done'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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

// ─── Payment Method Chip ──────────────────────────────────────────────────────

class _PaymentMethodChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _PaymentMethodChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.brandGreenSurface : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? AppColors.brandGreen : AppColors.divider,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: selected ? AppColors.brandGreen : AppColors.textSecondary),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.brandGreen : AppColors.textSecondary)),
            ],
          ),
        ),
      );
}

// One charge on the visit (a charge package, or an older typed charge):
// name, whose booking it is on (family visits), optional reason, amount and
// a remove button while charges can still change.
class _ChargeCard extends StatelessWidget {
  final String title;
  final String? member;
  final String? reason;
  final double amount;
  final VoidCallback? onRemove;
  const _ChargeCard({required this.title, this.member, this.reason, required this.amount, this.onRemove});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.fromLTRB(12, 8, onRemove != null ? 4 : 12, 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF8E1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFFE082)),
        ),
        child: Row(children: [
          const Icon(Icons.add_circle_outline, size: 16, color: Color(0xFFE65100)),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(member != null ? '$title · $member' : title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            if ((reason ?? '').isNotEmpty)
              Text(reason!, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          ])),
          Text('₹${_inr(amount)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFE65100))),
          if (onRemove != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppColors.textSecondary,
              tooltip: 'Remove charge',
              visualDensity: VisualDensity.compact,
            ),
        ]),
      );
}

// "Add charge package" sheet: search the catalogue, tick one or more
// products, add an optional reason. Returns the chosen product ids and the
// reason; prices shown are the server's, which it charges again on save.
class _ChargePackageSheet extends StatefulWidget {
  final List<Map<String, dynamic>> packages;
  final String patientName;
  const _ChargePackageSheet({required this.packages, required this.patientName});

  @override
  State<_ChargePackageSheet> createState() => _ChargePackageSheetState();
}

class _ChargePackageSheetState extends State<_ChargePackageSheet> {
  final _searchCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  final Set<int> _selected = {};
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  int _idOf(Map<String, dynamic> p) => (p['productId'] as num).toInt();
  double _priceOf(Map<String, dynamic> p) => (p['price'] as num?)?.toDouble() ?? 0.0;

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown = q.isEmpty
        ? widget.packages
        : widget.packages.where((p) =>
            (p['name'] as String? ?? '').toLowerCase().contains(q) ||
            (p['category'] as String? ?? '').toLowerCase().contains(q)).toList();
    final selectedTotal = widget.packages
        .where((p) => _selected.contains(_idOf(p)))
        .fold(0.0, (s, p) => s + _priceOf(p));

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
              )),
              const Text('Add charge package', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(widget.patientName, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 12),
              TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: const InputDecoration(
                  hintText: 'Search packages',
                  prefixIcon: Icon(Icons.search, size: 20),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: shown.isEmpty
                ? const Center(child: Text('No packages match your search',
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary)))
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final p  = shown[i];
                      final id = _idOf(p);
                      return CheckboxListTile(
                        value: _selected.contains(id),
                        onChanged: (v) => setState(() => v == true ? _selected.add(id) : _selected.remove(id)),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppColors.brandGreen,
                        title: Text(p['name'] as String? ?? 'Package', style: const TextStyle(fontSize: 13)),
                        subtitle: (p['category'] as String?) != null
                            ? Text(p['category'] as String, style: const TextStyle(fontSize: 11))
                            : null,
                        secondary: Text('₹${_inr(_priceOf(p))}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(children: [
              TextField(
                controller: _reasonCtrl,
                maxLength: 255,
                maxLines: 2,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.pop(context,
                          (productIds: _selected.toList(), reason: _reasonCtrl.text.trim())),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.brandGreen,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(
                    _selected.isEmpty
                        ? 'Select packages'
                        : 'Add ${_selected.length} · ₹${_inr(selectedTotal)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
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
          Expanded(child: Text(label, style: TextStyle(fontSize: sub ? 12 : 13, color: sub ? AppColors.textSecondary : AppColors.textPrimary))),
          const SizedBox(width: 8),
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
  final _nameCtrl           = TextEditingController();
  final _dobCtrl            = TextEditingController();
  final _healthCtrl         = TextEditingController();
  final List<TextEditingController> _doctorNameCtrls = [];
  // Set when Submit is tapped with a doctor name missing: every empty doctor
  // field then shows its error. (A SnackBar would open behind this sheet.)
  bool _showDoctorNameErrors = false;
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
    for (final c in _doctorNameCtrls) { c.dispose(); }
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
    if (_mode == 'newPatient' && _dob == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please select a date of birth'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    final String name;
    final String mobile;
    int? patientId;
    int? age;
    String? gender;
    String? relation;
    String? dobStr;

    if (_mode == 'select') {
      name      = (_selectedFamilyMember?['patient_name']   as String? ?? '').trim().toUpperCase();
      mobile    = (_selectedFamilyMember?['patient_mobile'] as String? ?? '').trim();
      patientId = (_selectedFamilyMember?['patient_id']     as num?)?.toInt();
      age       = (_selectedFamilyMember?['patient_age']    as num?)?.toInt();
      gender    = _selectedFamilyMember?['patient_gender']  as String?;
      relation  = _selectedFamilyMember?['patient_relation'] as String?;
    } else {
      name      = _nameCtrl.text.trim().toUpperCase();
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
      _doctorNameCtrls.add(TextEditingController());
      _showDoctorNameErrors = false; // a new member starts without an error
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

    // Validate doctor name — required for every member. Shown on the fields
    // themselves: a SnackBar would appear behind this sheet, unseen.
    final missingDoctor = _doctorNameCtrls
        .take(_queuedMembers.length)
        .any((c) => c.text.trim().isEmpty);
    if (missingDoctor) {
      setState(() => _showDoctorNameErrors = true);
      return;
    }

    setState(() => _isSaving = true);

    // Strip UI-only 'total'; attach doctor name from per-member controllers
    final apiMembers = _queuedMembers.asMap().entries.map((e) {
      final copy = Map<String, dynamic>.from(e.value);
      copy.remove('total');
      copy['doctorName'] = _doctorNameCtrls[e.key].text.trim();
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
    return _nameCtrl.text.trim().isNotEmpty
        && _mobileCtrl.text.trim().length == 10
        && _dob != null;
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
                              : 'Add to Queue · ₹${_inr(_selectedTotal)}',
                          _ => 'Submit ${_queuedMembers.length} Member${_queuedMembers.length == 1 ? '' : 's'}'
                              ' · ₹${_inr(_queuedTotal)}',
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
        RichText(text: const TextSpan(
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          children: [
            TextSpan(text: 'Mobile Number'),
            TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ],
        )),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _mobileCtrl,
              keyboardType: TextInputType.phone,
              maxLength: 10,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
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

        RichText(text: const TextSpan(
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          children: [
            TextSpan(text: 'Full Name'),
            TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
          ],
        )),
        const SizedBox(height: 5),
        TextField(
          controller: _nameCtrl,
          keyboardType: TextInputType.name,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z ]'))],
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Enter full name',
            hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
            prefixIcon: const Icon(Icons.person_outline, size: 18, color: AppColors.textHint),
            counterText: '',
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.divider)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
            contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
          ),
        ),
        const SizedBox(height: 10),

        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          RichText(text: const TextSpan(
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            children: [
              TextSpan(text: 'Date of Birth'),
              TextSpan(text: ' *', style: TextStyle(color: Colors.red)),
            ],
          )),
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
            final needsDoc = t['docRequired'] == 'yes';
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
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((t['category'] ?? '').isNotEmpty)
                    Text(t['category']!,
                        style: const TextStyle(fontSize: 11, color: AppColors.brandGreen)),
                  if (needsDoc)
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text('⚠ Requires prescription — mandatory to upload after adding',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFE65100))),
                    ),
                ],
              ),
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

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 6),
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
                      Text('₹${_inr(total)}',
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
                    onTap: () => setState(() {
                      _queuedMembers.removeAt(i);
                      _doctorNameCtrls[i].dispose();
                      _doctorNameCtrls.removeAt(i);
                    }),
                    child: const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.close_rounded, size: 18, color: AppColors.textHint),
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: _doctorNameCtrls[i],
                  maxLength: 150,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z .]'))],
                  style: const TextStyle(fontSize: 13),
                  // Rebuild so the error clears as soon as a name is typed.
                  onChanged: (_) { if (_showDoctorNameErrors) setState(() {}); },
                  decoration: InputDecoration(
                    hintText: 'Self or doctor name for $name *',
                    errorText: _showDoctorNameErrors && _doctorNameCtrls[i].text.trim().isEmpty
                        ? 'Enter "Self" or the doctor name'
                        : null,
                    errorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.red),
                    ),
                    focusedErrorBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.red, width: 1.5),
                    ),
                    hintStyle: const TextStyle(fontSize: 12, color: AppColors.textHint),
                    prefixIcon: const Icon(Icons.local_hospital_outlined, size: 16, color: AppColors.textHint),
                    counterText: '',
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.divider),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              ),
            ],
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
            Text('₹${_inr(_queuedTotal)}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ]),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }
}
// One choice in the family payment popup ("Single payment" / "Individual payments").
class _PayModeOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _PayModeOption({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: AppColors.brandGreenSurface, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: AppColors.brandGreen, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.3)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.textHint),
          ]),
        ),
      ),
    );
  }
}

// ── QR Payment Sheet ──────────────────────────────────────────────────────────
// Shows a Razorpay UPI QR code with a 5-minute countdown. Polls the server
// every 4 s. Pops with the Razorpay payment ID on success, null on cancel.
enum _QrState { loading, ready, paid, expired, error }

class _QrPaymentSheet extends StatefulWidget {
  final int bookingId;
  final double amount;
  final List<int>? bookingIds;
  final String? partialReason;
  const _QrPaymentSheet({required this.bookingId, required this.amount, this.bookingIds, this.partialReason});

  @override
  State<_QrPaymentSheet> createState() => _QrPaymentSheetState();
}

class _QrPaymentSheetState extends State<_QrPaymentSheet> {
  static const int _totalSeconds = 300; // 5 minutes

  _QrState _state = _QrState.loading;
  String? _qrId;
  String? _imageUrl;
  String? _errorMsg;
  int _remaining = _totalSeconds;

  Timer? _pollTimer;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _generateQr();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _generateQr() async {
    _pollTimer?.cancel();
    _countdownTimer?.cancel();
    setState(() { _state = _QrState.loading; _remaining = _totalSeconds; _errorMsg = null; });

    final data = await ApiService.createQrCode(bookingId: widget.bookingId, amount: widget.amount, bookingIds: widget.bookingIds, partialReason: widget.partialReason);
    if (!mounted) return;
    if (data == null) {
      setState(() { _state = _QrState.error; _errorMsg = 'Could not generate QR. Check your connection and try again.'; });
      return;
    }

    setState(() {
      _state    = _QrState.ready;
      _qrId     = data['qrId'] as String?;
      _imageUrl = data['imageUrl'] as String?;
    });

    // Countdown — tick every second
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 1) {
        _countdownTimer?.cancel();
        _pollTimer?.cancel();
        if (mounted) setState(() => _state = _QrState.expired);
      } else {
        setState(() => _remaining--);
      }
    });

    // Poll server every 4 s
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_qrId == null || !mounted) return;
      final status = await ApiService.getQrStatus(_qrId!);
      if (!mounted) return;
      if (status != null && status['paid'] == true) {
        _pollTimer?.cancel();
        _countdownTimer?.cancel();
        setState(() => _state = _QrState.paid);
        await Future.delayed(const Duration(milliseconds: 1600));
        if (mounted) Navigator.of(context).pop(status['paymentId'] as String?);
      }
    });
  }

  String get _timerLabel {
    final m = _remaining ~/ 60;
    final s = (_remaining % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    return Container(
      height: screenH * 0.82,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          const SizedBox(height: 12),
          Container(width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 4),

          Expanded(child: _buildBody()),

          // Cancel / close button at bottom
          if (_state != _QrState.paid)
            Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24,
                  MediaQuery.of(context).padding.bottom + 20),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.divider),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _QrState.loading:
        return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(color: AppColors.brandGreen, strokeWidth: 3),
            SizedBox(height: 20),
            Text('Generating QR code…',
                style: TextStyle(fontSize: 15, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
          ]),
        );

      case _QrState.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.wifi_off_rounded, size: 52, color: AppColors.textHint),
              const SizedBox(height: 16),
              Text(_errorMsg ?? 'Something went wrong',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.5)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _generateQr,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try Again', style: TextStyle(fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                ),
              ),
            ]),
          ),
        );

      case _QrState.expired:
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.timer_off_rounded, size: 52, color: AppColors.textHint),
              const SizedBox(height: 16),
              const Text('QR Code Expired',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 8),
              const Text('The 5-minute window passed.\nGenerate a new code to try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _generateQr,
                icon: const Icon(Icons.qr_code_rounded, size: 18),
                label: const Text('Generate New QR', style: TextStyle(fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                ),
              ),
            ]),
          ),
        );

      case _QrState.paid:
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: AppColors.brandGreen.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded, color: AppColors.brandGreen, size: 44),
            ),
            const SizedBox(height: 20),
            const Text('Payment Received!',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
            const SizedBox(height: 6),
            Text('₹${_inr(widget.amount)} collected via UPI',
                style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
          ]),
        );

      case _QrState.ready:
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
          child: Column(
            children: [
              // Amount
              Text('₹${_inr(widget.amount)}',
                  style: const TextStyle(
                      fontSize: 36, fontWeight: FontWeight.w800,
                      color: AppColors.brandGreen, letterSpacing: -0.5)),

              const SizedBox(height: 16),

              // QR image — no card border, no padding, just the image
              Expanded(
                child: _imageUrl != null
                    ? Image.network(
                        _imageUrl!,
                        fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) => progress == null
                            ? child
                            : const Center(child: CircularProgressIndicator(
                                color: AppColors.brandGreen, strokeWidth: 2)),
                        errorBuilder: (_, __, ___) => const Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.broken_image_outlined, size: 52, color: AppColors.textHint),
                            SizedBox(height: 12),
                            Text('Could not load QR image.\nCheck your internet connection.',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                          ]),
                        ),
                      )
                    : const Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.qr_code_2_rounded, size: 64, color: AppColors.textHint),
                          SizedBox(height: 12),
                          Text('QR code not available',
                              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                        ]),
                      ),
              ),

              const SizedBox(height: 14),

              // Timer pill only
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _remaining <= 60
                      ? Colors.red.withValues(alpha: 0.08)
                      : AppColors.background,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _remaining <= 60
                        ? Colors.red.withValues(alpha: 0.3)
                        : AppColors.divider,
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.timer_outlined,
                      size: 14,
                      color: _remaining <= 60 ? Colors.red : AppColors.textSecondary),
                  const SizedBox(width: 5),
                  Text(_timerLabel,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _remaining <= 60 ? Colors.red : AppColors.textPrimary)),
                ]),
              ),

              const SizedBox(height: 16),
            ],
          ),
        );
    }
  }
}
