import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/notification_service.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/utils/app_messages.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';
import '../shared/location_picker_screen.dart';
import 'customer_home_screen.dart';
import 'checkout_screen.dart';
import 'my_bookings_screen.dart';
import 'package:microlab/models.dart';
import 'reports_screen.dart';
import 'patient_ride_tracking_screen.dart';
import 'tracking_map_screen.dart';
import 'lab_progress_screen.dart';



// ─── Screen ───────────────────────────────────────────────────────────────────

class CustomerDashboardScreen extends StatefulWidget {
  final MemberModel member;
  final List<TestModel> initialCartTests;
  final bool isVip;
  final bool embedded;
  final VoidCallback? onBack;
  final BookingDraft? initialDraft;
  final void Function(BookingDraft)? onDraftSave;
  final VoidCallback? onMemberAdded;
  const CustomerDashboardScreen({
    super.key,
    required this.member,
    this.initialCartTests = const [],
    this.isVip = false,
    this.embedded = false,
    this.onBack,
    this.initialDraft,
    this.onDraftSave,
    this.onMemberAdded,
  });

  @override
  State<CustomerDashboardScreen> createState() => _CustomerDashboardScreenState();
}

class _CustomerDashboardScreenState extends State<CustomerDashboardScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // ── Collection mode ───────────────────────────────────────
  String _mode = 'Home Collection'; // or 'Lab Test'
  bool _modeChosen = false;         // true once user explicitly taps a mode
  final List<String> _modes = ['Home Collection', 'Lab Test'];

  // ── Location fields ───────────────────────────────────────
  String? _address;
  String? _pincode;
  String? _city;
  double? _lat;
  double? _lng;
  // Silently auto-detected from pincode — patient never sees or selects this.
  BranchModel? _selectedBranch;
  bool _branchDetecting = false;
  int  _branchLookupId  = 0;
  // Real patientId from auth session — falls back to 1 if socket not yet connected
  int get _patientId {
    final id = SocketService.instance.userId;
    return id > 0 ? id : 1;
  }

  // ── Cart ──────────────────────────────────────────────────
  final List<TestModel> _cart = [];
  bool get _isLabTest => _mode == 'Lab Test';
  bool _bookingCompleted = false;

  // ── Tests/Packages ────────────────────────────────────────
  bool _loadingTests = false;
  String _searchQuery = '';
  int?   _selectedPackageCategoryId;  // null = All
  String _selectedAudience = 'General'; // General (= all) / Men / Women / Kids
  bool _showOffersOnly = false;

  final List<BranchModel> _branches = [];

  // Tests/packages are loaded from GET /api/tests one page at a time — the
  // catalog has ~1,000 products, too many to download and draw at once.
  // Search, category and offers are applied on the server, so this list
  // already holds only matching products: the first page, plus each further
  // page fetched as the customer scrolls near the end.
  static const int _pageSize = 20;
  List<TestModel> _allTests = [];
  int  _totalTests   = 0;
  bool _hasMoreTests = false;
  bool _loadingMoreTests = false;
  // Bumped on every new search/filter, so a slow reply for an older query
  // can't overwrite the results of the current one.
  int  _testsRequestId = 0;
  Timer? _searchDebounce;
  List<({int id, String name})> _packageCategories = [];

  List<TestModel> get _filteredTests => _allTests;

  @override
  void initState() {
    super.initState();
    _loadTests();
    _loadCategories();
    NotificationService.instance.loadCustomerToken();
    final draft = widget.initialDraft;
    if (draft != null && !draft.isEmpty) {
      _cart.addAll(draft.cart);
      _mode           = draft.mode;
      _modeChosen     = draft.modeChosen;
      _address        = draft.address;
      _pincode        = draft.pincode;
      _city           = draft.city;
      _lat            = draft.lat;
      _lng            = draft.lng;
      _selectedBranch = draft.selectedBranch;
    } else if (widget.initialCartTests.isNotEmpty) {
      _cart.addAll(widget.initialCartTests);
    }
    _searchController.addListener(() {
      if (_searchController.text == _searchQuery) return;
      setState(() => _searchQuery = _searchController.text);
      // Ask the server once typing pauses, not on every keystroke.
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 400), _loadTests);
    });
  }

  // First page for the current search + filters (also pull-to-refresh).
  Future<void> _loadTests() async {
    _searchDebounce?.cancel();
    final requestId = ++_testsRequestId;
    setState(() { _loadingTests = true; _loadingMoreTests = false; });
    try {
      final page = await ApiService.getPackagesPage(
        search:             _searchQuery,
        packageCategoryId:  _selectedPackageCategoryId,
        audience:           _selectedAudience == 'General' ? null : _selectedAudience.toLowerCase(),
        offersOnly:         _showOffersOnly,
        limit:              _pageSize,
        mode:               _isLabTest ? 'lab' : 'home',
      );
      if (!mounted || requestId != _testsRequestId) return;
      setState(() {
        _allTests     = page.items;
        _totalTests   = page.total;
        _hasMoreTests = page.hasMore;
        _loadingTests = false;
      });
    } catch (e) {
      debugPrint('[Tests] first page failed: $e');
      if (mounted && requestId == _testsRequestId) setState(() => _loadingTests = false);
    }
  }

  // Next page, when the customer scrolls near the end of the list.
  Future<void> _loadMoreTests() async {
    if (_loadingTests || _loadingMoreTests || !_hasMoreTests) return;
    final requestId = _testsRequestId;
    setState(() => _loadingMoreTests = true);
    try {
      final page = await ApiService.getPackagesPage(
        search:             _searchQuery,
        packageCategoryId:  _selectedPackageCategoryId,
        audience:           _selectedAudience == 'General' ? null : _selectedAudience.toLowerCase(),
        offersOnly:         _showOffersOnly,
        limit:              _pageSize,
        offset:             _allTests.length,
        mode:               _isLabTest ? 'lab' : 'home',
      );
      if (!mounted || requestId != _testsRequestId) return;
      setState(() {
        final have = _allTests.map((t) => t.id).toSet();
        _allTests = [..._allTests, ...page.items.where((t) => !have.contains(t.id))];
        _totalTests   = page.total;
        _hasMoreTests = page.hasMore;
        _loadingMoreTests = false;
      });
    } catch (e) {
      debugPrint('[Tests] next page failed: $e');
      if (mounted && requestId == _testsRequestId) setState(() => _loadingMoreTests = false);
    }
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await ApiService.getPackageCategories();
      if (mounted) setState(() => _packageCategories = cats);
    } catch (e) {
      debugPrint('[Tests] categories failed: $e');
    }
  }

  // Start fetching the next page while ~2 cards are still below the screen.
  bool _onTestsScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 400) {
      _loadMoreTests();
    }
    return false;
  }

  void _toggleCart(TestModel test) {
    setState(() {
      final exists = _cart.any((t) => t.id == test.id);
      if (exists) {
        _cart.removeWhere((t) => t.id == test.id);
      } else {
        _cart.add(test);
        debugPrint(
          '🎯 [RECOMMENDED] "${test.name}" (id=${test.id}) '
          'isRecommended=${test.isRecommended} '
          'recommendedIds=${test.recommendedIds.isEmpty ? '(none)' : test.recommendedIds.join(', ')}',
        );
      }
    });
  }

  bool _inCart(TestModel test) => _cart.any((t) => t.id == test.id);
  double get _cartTotal => _cart.fold(0.0, (s, t) => s + t.finalPrice);

  void _uploadPrescription() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PrescriptionUploadSheet(member: widget.member),
    );
  }

  // ── Branch auto-detection ─────────────────────────────────
  // Called silently whenever a 6-digit pincode becomes available.
  // Patient never sees this — branch is stored and forwarded to CheckoutScreen.
  Future<void> _autoDetectBranch(String pincode, {String? place, bool isGps = false}) async {
    if (!mounted) return;
    // Lookups can finish out of order; only the latest one may set the branch.
    final lookup = ++_branchLookupId;
    final effectivePlace = place ?? _city;
    debugPrint('\n🏥 [BRANCH AUTO-DETECT] ─────────────────────────────');
    debugPrint('   pincode     : $pincode');
    debugPrint('   place/city  : ${effectivePlace ?? '— (no fallback)'}');
    debugPrint('   mode        : $_mode');
    debugPrint('   source      : ${isGps ? 'gps' : 'manual'}');
    setState(() { _branchDetecting = true; _selectedBranch = null; });

    try {
      final params = <String, String>{'pincode': pincode};
      // Tells the server this came from Current Live Location, not manual
      // pincode entry — even though a pincode is also sent (derived from
      // reverse-geocoding the GPS address), so it runs the GPS eligibility
      // walk (online tech + slots) instead of taking the pincode-exact
      // shortcut straight past that check.
      if (isGps) params['source'] = 'gps';
      if (effectivePlace != null && effectivePlace.isNotEmpty) {
        params['place'] = effectivePlace;
      }
      if (_lat != null) params['lat'] = _lat!.toString();
      if (_lng != null) params['lng'] = _lng!.toString();
      final uri = Uri.parse('${AppConstants.serverUrl}/api/branches/lookup')
          .replace(queryParameters: params);
      debugPrint('   → GET $uri');

      final res = await http
          .get(uri)
          .timeout(const Duration(seconds: 10));

      debugPrint('   ← status    : ${res.statusCode}');
      debugPrint('   ← body      : ${res.body}');

      if (!mounted || lookup != _branchLookupId) return;

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['success'] == true) {
          final branch = BranchModel.fromJson(body['branch'] as Map<String, dynamic>);
          setState(() { _selectedBranch = branch; _branchDetecting = false; });
          debugPrint('   ✅ branch    : ${branch.name} (id=${branch.id})');
          debugPrint('   📍 address   : ${branch.address}');
          // GPS-only: server picked a fallback branch (nearest had no online
          // tech / no available slots) — let the patient know why they're
          // not seeing the true-nearest branch, same idea as Uber surfacing
          // "matched with a nearby driver" instead of silently substituting.
          if (branch.isFallback && body['message'] is String && mounted) {
            AppMessages.info(context, AppMessages.serverMessage(body['message'],
                fallback: 'We matched you with ${branch.name}, the nearest branch with availability.'));
          }
        } else {
          setState(() => _branchDetecting = false);
          debugPrint('   ⚠️  no branch : ${body['message']}');
        }
      } else {
        setState(() => _branchDetecting = false);
        debugPrint('   ❌ HTTP ${res.statusCode} — branch detection skipped');
        // Tell the patient, or checkout can't proceed with no explanation.
        if (res.statusCode == 404 && mounted) {
          try {
            final body = jsonDecode(res.body) as Map<String, dynamic>;
            if (body['message'] is String) {
              AppMessages.error(context, AppMessages.serverMessage(body['message'],
                  fallback: 'No nearby branch has availability right now. Please try a different time or location.'));
            }
          } catch (_) {
            // non-JSON error body — nothing to show, stay silent as before
          }
        }
      }
    } catch (e) {
      debugPrint('   ❌ error     : $e');
      if (mounted && lookup == _branchLookupId) {
        setState(() => _branchDetecting = false);
        AppMessages.error(context, 'We couldn\'t find a branch for this location. Please check your connection and try again.');
      }
    }
    debugPrint('────────────────────────────────────────────────────\n');
  }

  // Extracts a 6-digit Indian pincode from a GPS reverse-geocoded address string.
  // e.g. "12 Gandhi St, T Nagar, Chennai, Tamil Nadu 600017, India" → "600017"
  void _tryExtractPincodeFromAddress(String address) {
    debugPrint('\n📍 [GPS ADDRESS → PINCODE]');
    debugPrint('   raw address : $address');
    final pinMatch = RegExp(r'\b(\d{6})\b').firstMatch(address);
    if (pinMatch != null) {
      final pin = pinMatch.group(1)!;
      // Try to extract city: split by comma, take 2nd segment, strip digits/dashes
      String? extractedCity;
      final parts = address.split(',');
      if (parts.length >= 2) {
        final candidate = parts[1].trim().replaceAll(RegExp(r'[\d\-\s]+$'), '').trim();
        if (candidate.length > 2) extractedCity = candidate;
      }
      debugPrint('   extracted   : pin=$pin  city=${extractedCity ?? '— using _city=$_city'}');
      final cityToUse = extractedCity ?? _city;
      if (extractedCity != null) {
        setState(() { _pincode = pin; _city = extractedCity; });
      } else {
        setState(() => _pincode = pin);
      }
      _autoDetectBranch(pin, place: cityToUse, isGps: true);
    } else {
      debugPrint('   ⚠️  no 6-digit pincode found in address — branch not auto-detected');
    }
  }

  void _showLocationSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationSheet(
        mode: _mode,
        modes: _modes,
        branches: _branches,
        selectedBranch: _selectedBranch,
        pincode: _pincode,
        city: _city,
        address: _address,
        onModeChanged: (m) {
          final prev = _mode;
          debugPrint('\n🔄 [MODE CHANGE] $prev → $m');
          setState(() {
            _mode = m;
            _modeChosen = true;
            // Only clear branch when SWITCHING from Lab Test → Home Collection.
            // If mode hasn't changed (sheet re-confirmed same mode), keep state.
            if (m == 'Home Collection' && prev == 'Lab Test') {
              _selectedBranch = null;
              debugPrint('   🏥 branch cleared (switched to Home Collection)');
            }
            if (m == 'Lab Test' && prev != 'Lab Test') {
              _pincode = null;
              _city    = null;
              debugPrint('   🏥 pincode/city cleared (switched to Lab Test)');
            }
            if (m == prev) debugPrint('   ℹ️  mode unchanged — state preserved');
          });
          if (m != prev) _loadTests();
        },
        // Lab Test only — patient manually picks a branch.
        onBranchChanged: (b) {
          debugPrint('\n🏥 [BRANCH MANUAL SELECT] ${b?.name ?? 'cleared'} (Lab Test)');
          setState(() => _selectedBranch = b);
        },
        // Home Collection — pincode set → trigger silent branch detection.
        onPincodeChanged: (p) {
          debugPrint('\n📮 [PINCODE SET] "$p"  mode=$_mode  (current pincode=$_pincode)');
          // GPS flow sends null after address is confirmed.
          // If we already extracted a pincode from the GPS address, keep it.
          if (p == null && _pincode != null) {
            debugPrint('   ℹ️  null received but keeping extracted pincode "$_pincode" — skipping override');
            return;
          }
          setState(() {
            _pincode = p;
            // Only clear branch for Home Collection — Lab Test branch is set
            // separately via onBranchChanged and must not be wiped here.
            if (_mode != 'Lab Test') _selectedBranch = null;
          });
          if (p != null && p.length == 6 && _mode == 'Home Collection') {
            debugPrint('   → 6 digits confirmed — starting branch auto-detect (city=$_city)');
            _autoDetectBranch(p, place: _city);
          } else {
            debugPrint('   → skipped (length=${p?.length}, mode=$_mode)');
          }
        },
        onCityChanged: (c) => setState(() => _city = c),
        // GPS / manual address — try to extract pincode from the address string.
        onAddressChanged: (a) {
          debugPrint('\n🏠 [ADDRESS SET] "$a"');
          setState(() => _address = a);
          if (a != null && a.isNotEmpty &&
              _pincode == null && _mode == 'Home Collection') {
            debugPrint('   → no pincode yet — scanning address for 6-digit code');
            _tryExtractPincodeFromAddress(a);
          }
        },
        onLatLngChanged: (lat, lng) {
          debugPrint('\n📡 [GPS COORDS] lat=$lat  lng=$lng');
          setState(() { _lat = lat; _lng = lng; });
        },
      ),
    );
  }

  // Recommended packages for whatever's in the cart right now, mapped to the
  // cart item(s) each one is an alternative TO — a recommendation is an
  // either/or swap, not an add-on: choosing it replaces the item(s) that
  // recommended it rather than sitting alongside them. Excludes ids already
  // in the cart.
  Map<String, List<TestModel>> _pendingRecommendations() {
    final inCart = _cart.map((t) => t.id).toSet();
    final map = <String, List<TestModel>>{};
    for (final t in _cart) {
      if (!t.isRecommended) continue;
      for (final id in t.recommendedIds) {
        if (inCart.contains(id)) continue;
        map.putIfAbsent(id, () => []).add(t);
      }
    }
    return map;
  }

  // Swaps every selected recommendation in for whichever cart item(s)
  // suggested it — applied together as one batch when the customer confirms,
  // not the instant they tap a single recommendation, so they can pick
  // several (e.g. both HAEMOGLOBIN and the panel instead of just RFT).
  void _applyRecommendations(List<TestModel> selected, Map<String, List<TestModel>> replaces) {
    if (selected.isEmpty) return;
    setState(() {
      for (final rec in selected) {
        final sources = replaces[rec.id] ?? const <TestModel>[];
        _cart.removeWhere((t) => sources.any((s) => s.id == t.id));
        _cart.add(rec);
      }
    });
  }

  void _navigateToCheckout() {
    // Guard: branch detection still in flight — don't proceed with null branchId
    if (_branchDetecting && _mode == 'Home Collection') {
      debugPrint('🛑 [CHECKOUT BLOCKED] branch detection still running — showing wait message');
      AppMessages.info(context, 'Finding your nearest branch... please wait a moment');
      return;
    }
    final branchId = _selectedBranch != null
        ? int.tryParse(_selectedBranch!.id)
        : null;
    debugPrint('\n🛒 [CHECKOUT] ────────────────────────────────────');
    debugPrint('   mode        : $_mode');
    debugPrint('   pincode     : ${_pincode ?? '—'}');
    debugPrint('   branch      : ${_selectedBranch?.name ?? '⚠️ none'}');
    debugPrint('   branchId    : ${branchId ?? '⚠️ null'}');
    debugPrint('   detecting   : $_branchDetecting');
    debugPrint('   patientId   : $_patientId');
    debugPrint('   cart items  : ${_cart.length}');
    debugPrint('──────────────────────────────────────────────────\n');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CheckoutScreen(
          member:     widget.member,
          cart:       List.from(_cart),
          mode:       _mode,
          address:    _address,
          pincode:    _pincode,
          city:       _city,
          branch:     _selectedBranch,
          isVip:      widget.isVip,
          patientId:  int.tryParse(widget.member.id) ?? _patientId,
          patientLat: _lat,
          patientLng: _lng,
          branchId:   branchId,
          onMemberAdded: widget.onMemberAdded,
          onBookingComplete: () {
            _bookingCompleted = true;
            widget.onDraftSave?.call(BookingDraft());
            setState(() {
              _cart.clear();
              _address        = null;
              _pincode        = null;
              _city           = null;
              _lat            = null;
              _lng            = null;
              _selectedBranch = null;
            });
          },
        ),
      ),
    );
  }

  void _showCart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CartSheet(
        cart: _cart,
        onRemove: (t) => setState(() => _cart.removeWhere((x) => x.id == t.id)),
        onCheckout: () async {
          final recommendations = _pendingRecommendations();
          if (recommendations.isEmpty) {
            Navigator.pop(context); // close cart sheet
            _navigateToCheckout();
            return;
          }
          Navigator.pop(context); // close cart sheet, show recommendations instead
          final recommended = await ApiService.getPackagesByIds(recommendations.keys);
          if (!mounted) return;
          if (recommended.isEmpty) {
            _navigateToCheckout();
            return;
          }
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => _RecommendedTestsSheet(
              tests: recommended,
              replaces: recommendations,
              onContinue: (selected) {
                Navigator.pop(context); // close recommendations sheet
                _applyRecommendations(selected, recommendations);
                _navigateToCheckout();
              },
            ),
          );
        },
      ),
    );
  }

  void _showTestDetail(TestModel test) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TestDetailSheet(
        test: test,
        inCart: _inCart(test),
        onToggleCart: () => _toggleCart(test),
      ),
    );
  }

  Widget _buildCartBar(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    final pill = Container(
      padding: const EdgeInsets.fromLTRB(CxSpace.md, 10, 10, 10),
      decoration: BoxDecoration(
        color: CxColors.brand,
        borderRadius: CxRadius.lgAll,
        boxShadow: [
          BoxShadow(
            color: CxColors.brand.withValues(alpha: 0.30),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: CxRadius.mdAll,
            ),
            child: Stack(alignment: Alignment.center, children: [
              const Icon(Icons.shopping_bag_outlined, color: Colors.white, size: 20),
              Positioned(
                right: 2, top: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: const BoxDecoration(color: Colors.white, borderRadius: CxRadius.pill),
                  child: Text('${_cart.length}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: CxColors.brand, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
          const SizedBox(width: CxSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('₹${_cartTotal.toInt()} total',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                Text('${_cart.length} item${_cart.length > 1 ? 's' : ''} added',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
              ],
            ),
          ),
          FilledButton(
            onPressed: _showCart,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: CxColors.brand,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              minimumSize: const Size(0, 42),
              shape: const RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Text('View Cart'),
              SizedBox(width: 4),
              Icon(Icons.arrow_forward_rounded, size: 18),
            ]),
          ),
        ],
      ),
    );

    // Embedded: floating pill only — no white wrapper, no extra safe area
    if (widget.embedded) return pill;

    // Non-embedded: full-width bottom bar with safe-area padding
    return Container(
      padding: EdgeInsets.fromLTRB(CxSpace.gutter, 10, CxSpace.gutter, bottomPad + 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: CxColors.border)),
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: CxSize.contentMaxWidth),
          child: pill,
        ),
      ),
    );
  }

  void _saveDraft() {
    widget.onDraftSave?.call(BookingDraft(
      cart:           List.from(_cart),
      mode:           _mode,
      modeChosen:     _modeChosen,
      address:        _address,
      pincode:        _pincode,
      city:           _city,
      lat:            _lat,
      lng:            _lng,
      selectedBranch: _selectedBranch,
    ));
  }

  @override
  void dispose() {
    if (!_bookingCompleted) _saveDraft();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = NestedScrollView(
      controller: _scrollController,
      headerSliverBuilder: (context, _) => [
        // ── App Bar ──────────────────────────────────────
        SliverAppBar(
          pinned: true,
          elevation: 0,
          backgroundColor: AppColors.brandGreen,
          leading: widget.embedded
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: Colors.white, size: 20),
                  tooltip: 'Back',
                  onPressed: widget.onBack,
                )
              : IconButton(
                  icon: const Icon(Icons.menu_rounded, color: Colors.white),
                  tooltip: 'Menu',
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                ),
          title: _HeaderTitle(member: widget.member, isVip: widget.isVip),
          actions: [
            // Cart
            Stack(
              children: [
                IconButton(
                  icon: const Icon(Icons.shopping_cart_outlined,
                      color: Colors.white, size: 24),
                  tooltip: _cart.isEmpty ? 'Cart is empty' : 'View cart (${_cart.length})',
                  onPressed: _cart.isEmpty ? null : _showCart,
                ),
                if (_cart.isNotEmpty)
                  Positioned(
                    right: 5,
                    top: 5,
                    child: IgnorePointer(
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 19, minHeight: 19),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: CxColors.offer,
                          borderRadius: CxRadius.pill,
                          border: Border.all(color: CxColors.brand, width: 1.5),
                        ),
                        child: Center(
                          child: Text('${_cart.length}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Container(
              color: AppColors.brandGreen,
              padding: const EdgeInsets.fromLTRB(CxSpace.md, 0, CxSpace.md, CxSpace.md),
              child: _LocationBar(
                mode: _mode,
                selectedBranch: _selectedBranch,
                pincode: _pincode,
                city: _city,
                onTap: _showLocationSheet,
              ),
            ),
          ),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([_loadTests(), _loadCategories()]);
        },
        color: AppColors.brandGreen,
        backgroundColor: Colors.white,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onTestsScroll,
          child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: CxSpace.lg),

              // ── Search + Upload ───────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CxSpace.gutter),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 48,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: CxRadius.mdAll,
                          border: Border.all(color: CxColors.border),
                          boxShadow: const [
                            BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2)),
                          ],
                        ),
                        child: TextField(
                          controller: _searchController,
                          textInputAction: TextInputAction.search,
                          style: const TextStyle(
                              fontSize: 14, color: CxColors.textPrimary),
                          decoration: const InputDecoration(
                            hintText: 'Search tests & packages…',
                            hintStyle: TextStyle(
                                fontSize: 14, color: CxColors.textHint),
                            prefixIcon: Icon(Icons.search_rounded,
                                size: 22, color: CxColors.textHint),
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(vertical: 13),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Upload prescription
                    Tooltip(
                      message: 'Upload prescription',
                      child: Material(
                        color: CxColors.brandSurface,
                        shape: const RoundedRectangleBorder(
                          borderRadius: CxRadius.mdAll,
                          side: BorderSide(color: CxColors.brandLight),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: _uploadPrescription,
                          child: const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(Icons.upload_file_outlined,
                                size: 22, color: CxColors.brand),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: CxSpace.md),

              // ── Filters: Special Offers + Group dropdown + Category dropdown ───
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CxSpace.gutter),
                child: Row(
                  children: [
                    // Special Offers chip
                    Semantics(
                      button: true,
                      selected: _showOffersOnly,
                      child: Material(
                        color: _showOffersOnly ? CxColors.offer : CxColors.offerSurface,
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: _showOffersOnly ? CxColors.offer : CxColors.offer.withValues(alpha: 0.25),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () {
                            setState(() => _showOffersOnly = !_showOffersOnly);
                            _loadTests();
                          },
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 38),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.local_offer_rounded,
                                      size: 15,
                                      color: _showOffersOnly ? Colors.white : CxColors.offer),
                                  const SizedBox(width: 5),
                                  Text('Special Offers',
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: _showOffersOnly ? Colors.white : CxColors.offer)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: CxSpace.sm),
                    // Group dropdown
                    Expanded(
                      child: PopupMenuButton<String>(
                        onSelected: (v) {
                          setState(() => _selectedAudience = v);
                          _loadTests();
                        },
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        itemBuilder: (_) => ['General', 'Men', 'Women', 'Kids']
                            .map((g) => PopupMenuItem(
                                  value: g,
                                  height: 40,
                                  child: Row(children: [
                                    if (_selectedAudience == g)
                                      const Icon(Icons.check_rounded, size: 14, color: AppColors.brandGreen),
                                    if (_selectedAudience == g) const SizedBox(width: 6),
                                    Text(g, style: TextStyle(
                                        fontSize: 13,
                                        color: _selectedAudience == g ? AppColors.brandGreen : AppColors.textPrimary,
                                        fontWeight: _selectedAudience == g ? FontWeight.w600 : FontWeight.w400)),
                                  ]),
                                ))
                            .toList(),
                        tooltip: 'Filter by group',
                        child: _DropdownPill(
                          icon: Icons.people_outline_rounded,
                          label: _selectedAudience == 'General' ? 'Group' : _selectedAudience,
                          active: _selectedAudience != 'General',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Category dropdown — uses 0 as sentinel for "All" because
                    // PopupMenuButton<int?> never fires onSelected for null values.
                    Expanded(
                      child: PopupMenuButton<int>(
                        onSelected: (v) {
                          setState(() => _selectedPackageCategoryId = v == 0 ? null : v);
                          _loadTests();
                        },
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        itemBuilder: (_) => [
                          PopupMenuItem<int>(
                            value: 0,
                            height: 40,
                            child: Row(children: [
                              if (_selectedPackageCategoryId == null)
                                const Icon(Icons.check_rounded, size: 14, color: AppColors.brandGreen),
                              if (_selectedPackageCategoryId == null) const SizedBox(width: 6),
                              Text('All', style: TextStyle(
                                  fontSize: 13,
                                  color: _selectedPackageCategoryId == null ? AppColors.brandGreen : AppColors.textPrimary,
                                  fontWeight: _selectedPackageCategoryId == null ? FontWeight.w600 : FontWeight.w400)),
                            ]),
                          ),
                          ..._packageCategories.map((cat) => PopupMenuItem<int>(
                                value: cat.id,
                                height: 40,
                                child: Row(children: [
                                  if (_selectedPackageCategoryId == cat.id)
                                    const Icon(Icons.check_rounded, size: 14, color: AppColors.brandGreen),
                                  if (_selectedPackageCategoryId == cat.id) const SizedBox(width: 6),
                                  Text(cat.name, style: TextStyle(
                                      fontSize: 13,
                                      color: _selectedPackageCategoryId == cat.id ? AppColors.brandGreen : AppColors.textPrimary,
                                      fontWeight: _selectedPackageCategoryId == cat.id ? FontWeight.w600 : FontWeight.w400)),
                                ]),
                              )),
                        ],
                        tooltip: 'Filter by category',
                        child: _DropdownPill(
                          icon: Icons.category_outlined,
                          label: _selectedPackageCategoryId == null
                              ? 'Category'
                              : (_packageCategories
                                      .where((c) => c.id == _selectedPackageCategoryId)
                                      .firstOrNull
                                      ?.name ?? 'Category'),
                          active: _selectedPackageCategoryId != null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ── Content ───────────────────────────────
              if (!_modeChosen)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: CxSpace.xl),
                  child: CxEmptyState(
                    icon: Icons.touch_app_outlined,
                    title: 'Select a booking type to see available tests',
                  ),
                )
              else if (_loadingTests)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: CxLoading(label: 'Loading tests…'),
                )
              else if (_filteredTests.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: CxSpace.xl),
                  child: CxEmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No tests found',
                    message: 'Try another search or change the filters.',
                  ),
                )
              else ...[
                if (_filteredTests.isNotEmpty) ...[
                  _SectionHeader(
                    title: _searchQuery.isNotEmpty
                        ? '$_totalTests result${_totalTests == 1 ? "" : "s"}'
                        : 'Tests & Packages',
                  ),
                  const SizedBox(height: 10),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: CxSpace.gutter),
                    itemCount: _filteredTests.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _TestCard(
                      test: _filteredTests[i],
                      inCart: _inCart(_filteredTests[i]),
                      onAdd: () => _toggleCart(_filteredTests[i]),
                      onTap: () => _showTestDetail(_filteredTests[i]),
                    ),
                  ),
                  // Next page on its way (fetched by _onTestsScroll).
                  if (_loadingMoreTests)
                    const CxLoading()
                  // Fallback when the list is too short to scroll, or the
                  // last page request failed.
                  else if (_hasMoreTests)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.md, CxSpace.gutter, 0),
                      child: CxButton.secondary(
                        onPressed: _loadMoreTests,
                        icon: Icons.expand_more_rounded,
                        compact: true,
                        label: 'Show more (${_totalTests - _filteredTests.length} more)',
                      ),
                    ),
                ],
              ],

              const SizedBox(height: 120),
            ],
          ),
          ),
        ),
      ),
    );

    // Combined banner: lab collection (top) + active ride (below)
    final banners = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ValueListenableBuilder<ActiveLabBookingInfo?>(
          valueListenable: SocketService.instance.activeLabBooking,
          builder: (context, lab, _) {
            if (lab == null) return const SizedBox.shrink();
            return _ActiveLabBanner(
              lab: lab,
              onTrack: () {
                if (lab.collected) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => LabProgressScreen(
                        bookingId: lab.bookingId,
                        patientName: SocketService.instance.userName.isEmpty
                            ? 'Patient'
                            : SocketService.instance.userName,
                      ),
                    ),
                  );
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TrackingMapScreen(
                        bookingId:      lab.bookingId,
                        patientId:      lab.patientId,
                        trackingId:     lab.trackingId,
                        technicianId:   lab.technicianId,
                        technicianName: lab.technicianName,
                        patientLat:     lab.patientLat,
                        patientLng:     lab.patientLng,
                        patientAddress: lab.patientAddress,
                      ),
                    ),
                  );
                }
              },
            );
          },
        ),
        ValueListenableBuilder<ActiveRideInfo?>(
          valueListenable: SocketService.instance.activeRide,
          builder: (context, ride, _) {
            if (ride == null) return const SizedBox.shrink();
            return _ActiveRideBanner(
              ride: ride,
              onTrack: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PatientRideTrackingScreen(
                    bookingId:     ride.bookingId.toString(),
                    patientId:     ride.patientId,
                    patientName:   ride.patientName,
                    trackingId:    ride.trackingId,
                    driverId:      ride.driverId,
                    driverName:    ride.driverName,
                    patientLat:    ride.patientLat,
                    patientLng:    ride.patientLng,
                    patientAddress: ride.patientAddress,
                    hospital:      ride.hospital,
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );

    if (widget.embedded) {
      final bottomPad = MediaQuery.of(context).padding.bottom;
      // Customer look for this screen and the sheets it opens.
      return CustomerThemeScope(
        child: ColoredBox(
          color: CxColors.page,
          child: Stack(
            children: [
              body,
              if (_cart.isNotEmpty)
                Positioned(
                  left: CxSpace.gutter,
                  right: CxSpace.gutter,
                  bottom: bottomPad + 8,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: CxSize.contentMaxWidth),
                      child: _buildCartBar(context),
                    ),
                  ),
                ),
              Positioned(
                left: 0, right: 0,
                bottom: _cart.isNotEmpty ? bottomPad + 78 : bottomPad + 8,
                child: banners,
              ),
            ],
          ),
        ),
      );
    }

    return CustomerThemeScope(
      child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: CxColors.page,
      drawer: _AppDrawer(member: widget.member, isVip: widget.isVip),
      body: Stack(
        children: [
          body,
          Positioned(
            left: 0, right: 0,
            bottom: _cart.isNotEmpty ? 76 : 0,
            child: banners,
          ),
        ],
      ),
      bottomNavigationBar: _cart.isNotEmpty ? _buildCartBar(context) : null,
      ),
    );
  }
}

// Visual for the Group / Category filter menus (the PopupMenuButton around
// it handles the tap and the choices).
class _DropdownPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  const _DropdownPill({required this.icon, required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : CxColors.textPrimary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      constraints: const BoxConstraints(minHeight: 38),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active ? CxColors.brand : Colors.white,
        borderRadius: CxRadius.pill,
        border: Border.all(color: active ? CxColors.brand : CxColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: active ? Colors.white : CxColors.textSecondary),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg),
            ),
          ),
          Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: fg),
        ],
      ),
    );
  }
}

// ─── Header title ─────────────────────────────────────────────────────────────

class _HeaderTitle extends StatelessWidget {
  final MemberModel member;
  final bool isVip;
  const _HeaderTitle({required this.member, required this.isVip});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                member.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isVip) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: const BoxDecoration(
                  color: Color(0xFFFFB300),
                  borderRadius: CxRadius.pill,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, size: 12, color: Colors.white),
                    SizedBox(width: 3),
                    Text('VIP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.5)),
                  ],
                ),
              ),
            ],
          ],
        ),
        if (member.relation != null)
          Text(
            member.relation!,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8), fontSize: 12),
          ),
      ],
    );
  }
}

// ─── Location bar ─────────────────────────────────────────────────────────────

class _LocationBar extends StatelessWidget {
  final String mode;
  final BranchModel? selectedBranch;
  final String? pincode;
  final String? city;
  final VoidCallback onTap;
  const _LocationBar({
    required this.mode,
    required this.selectedBranch,
    required this.pincode,
    required this.city,
    required this.onTap,
  });

  String get _locationLabel {
    if (mode == 'Lab Test') {
      return selectedBranch?.name ?? 'Select branch';
    }
    if (city != null && city!.isNotEmpty) return city!;
    if (pincode != null && pincode!.isNotEmpty) return pincode!;
    return 'Set location';
  }

  @override
  Widget build(BuildContext context) {
    // White card on the green header: mode chip, location, chevron.
    return Semantics(
      button: true,
      label: 'Change location. $mode, $_locationLabel',
      excludeSemantics: true,
      child: Material(
        color: Colors.white,
        borderRadius: CxRadius.mdAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: CxSpace.md),
            child: Row(
              children: [
                Icon(
                  mode == 'Lab Test'
                      ? Icons.local_hospital_outlined
                      : Icons.home_outlined,
                  size: 18,
                  color: CxColors.brand,
                ),
                const SizedBox(width: CxSpace.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: const BoxDecoration(
                    color: CxColors.brandSurface,
                    borderRadius: CxRadius.pill,
                  ),
                  child: Text(mode,
                      style: const TextStyle(
                          fontSize: 11,
                          color: CxColors.brand,
                          fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: CxSpace.sm),
                Expanded(
                  child: Text(
                    _locationLabel,
                    style: const TextStyle(
                        fontSize: 14,
                        color: CxColors.textPrimary,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.keyboard_arrow_down_rounded,
                    color: CxColors.textSecondary, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Location Sheet ───────────────────────────────────────────────────────────

// ─── Location Sheet ───────────────────────────────────────────────────────────

class _LocationSheet extends StatefulWidget {
  final String mode;
  final List<String> modes;
  final List<BranchModel> branches;
  final BranchModel? selectedBranch;
  final String? pincode;
  final String? city;
  final String? address;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<BranchModel?> onBranchChanged;
  final ValueChanged<String?> onPincodeChanged;
  final ValueChanged<String?> onCityChanged;
  final ValueChanged<String?> onAddressChanged;
  final void Function(double? lat, double? lng)? onLatLngChanged;

  const _LocationSheet({
    required this.mode,
    required this.modes,
    required this.branches,
    required this.selectedBranch,
    required this.pincode,
    required this.city,
    this.address,
    required this.onModeChanged,
    required this.onBranchChanged,
    required this.onPincodeChanged,
    required this.onCityChanged,
    required this.onAddressChanged,
    this.onLatLngChanged,
  });

  @override
  State<_LocationSheet> createState() => _LocationSheetState();
}

// Why the live location couldn't be used — drives the message and the
// action button shown under the "Use Current Location" card.
enum _LocationIssue { none, serviceOff, permissionDenied, permissionDeniedForever, approximate, failed }

class _LocationSheetState extends State<_LocationSheet> with WidgetsBindingObserver {
  late String _mode;
  BranchModel? _branch;
  final _pincodeCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  bool _locationError = false;
  bool _branchError = false;

  // Branches for Lab Test mode
  List<BranchModel> _allBranches      = [];
  List<BranchModel> _filteredBranches = [];
  bool _searchingBranches = false;
  // Lab Test PIN lookup: a 6-digit PIN is looked up once (district + map
  // point); branches are then listed nearest first, and one matching the
  // PIN or city is selected automatically. City and Branch are disabled
  // while the lookup runs.
  bool _labPinLookup = false;
  String? _labLookedUpPin;
  double? _labPinLat;
  double? _labPinLng;
  final Map<String, double> _branchDistKm = {};
  String? _branchMatchNote;

  // Pincode auto-detection
  String? _detectedArea;
  bool _detecting = false;

  // Manual address mode flag
  bool _isManualMode = false;

  // Address from GPS
  // A GPS fix worse than this (in metres) is treated as approximate and
  // refused — see _getCurrentLocation.
  static const double _maxGpsAccuracyMeters = 1000;
  String? _gpsAddress;
  double? _gpsLat;
  double? _gpsLng;
  bool _gpsSelected = false;
  // Why the live location couldn't be used (location off, permission
  // refused, ...) — shown with its own action under "Use Current Location".
  _LocationIssue _locationIssue = _LocationIssue.none;
  double? _approxAccuracyMeters;
  // True while waiting for a precise GPS fix (card reads "Getting your
  // precise location…").
  bool _waitingForFix = false;
  // Only the newest lookup may change the sheet — an older one that
  // finishes late is ignored (see _getCurrentLocation).
  int _locRequestId = 0;
  // Phone's "location switched on/off" events, and a short pause after the
  // app returns to the front — together they replace retrying the instant
  // the app resumes, which ran before GPS was ready and made the sheet
  // flicker between "turned off" and the spinner.
  StreamSubscription<ServiceStatus>? _serviceStatusSub;
  Timer? _settleTimer;
  StreamSubscription<Position>? _fixSub;
  // How long to wait for an accurate fix after location is turned on.
  static const Duration _fixTimeout = Duration(seconds: 12);

  // Address from manual entry (pincode based)
  String? _manualAddress;
  double? _manualLat;
  double? _manualLng;
  bool _manualSelected = false;

  // Pincode geocoding in progress
  bool _isGeocoding = false;
  // True only while a typed pincode is being looked up (not during GPS) —
  // Location and Address stay disabled until the lookup finishes.
  bool _isPincodeLookup = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mode   = widget.mode;
    _branch = widget.selectedBranch;
    _pincodeCtrl.text = widget.pincode ?? '';
    _cityCtrl.text    = widget.city    ?? '';

    // Restore previously entered address so user sees it when going back
    if (widget.address != null && widget.address!.isNotEmpty) {
      _addressCtrl.text = widget.address!;
      _manualAddress    = widget.address;
      _manualSelected   = true;
      _isManualMode     = true;
    }

    _pincodeCtrl.addListener(_filterBranches);
    _cityCtrl.addListener(_filterBranches);
    _pincodeCtrl.addListener(_onPincodeChanged);

    if (_mode == 'Lab Test') {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadBranches());
    } else if (!_manualSelected) {
      // Home Collection with no location chosen yet: check that location is
      // on and permission is given straight away, instead of waiting for
      // the "Use Current Location" tap.
      WidgetsBinding.instance.addPostFrameCallback((_) => _getCurrentLocation());
    }

    // React when the customer switches location on (from settings, the
    // quick panel or the notification shade). Not available on web.
    if (!kIsWeb) {
      try {
        _serviceStatusSub = Geolocator.getServiceStatusStream().listen((status) {
          if (status == ServiceStatus.enabled) _scheduleQuietRetry();
        });
      } catch (e) {
        debugPrint('[LocationSheet] service status stream unavailable: $e');
      }
    }
  }

  // Coming back from the phone's location or app settings. Nothing changes
  // on screen here — _scheduleQuietRetry only starts a lookup once the
  // problem is actually fixed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleQuietRetry();
  }

  // Waits a moment for the phone to settle, then checks — without touching
  // the sheet — whether the reported problem is gone; only then runs the
  // lookup. Several triggers in a row (resume + "location on" event) collapse
  // into one check.
  void _scheduleQuietRetry() {
    if (_mode != 'Home Collection' || _gpsSelected || _manualSelected || _isGeocoding) return;
    if (_locationIssue != _LocationIssue.serviceOff &&
        _locationIssue != _LocationIssue.permissionDeniedForever) return;
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 900), () async {
      if (!mounted || _isGeocoding || _gpsSelected || _manualSelected) return;
      try {
        if (_locationIssue == _LocationIssue.serviceOff) {
          if (!await Geolocator.isLocationServiceEnabled()) return; // still off — leave the message as is
        } else if (_locationIssue == _LocationIssue.permissionDeniedForever) {
          final p = await Geolocator.checkPermission();
          if (p != LocationPermission.always && p != LocationPermission.whileInUse) return;
        }
      } catch (_) {
        return;
      }
      if (mounted) _getCurrentLocation();
    });
  }

  Future<void> _loadBranches() async {
    if (!mounted) return;
    setState(() => _searchingBranches = true);
    try {
      final branches = await ApiService.getBranches();
      if (!mounted) return;
      setState(() {
        _allBranches      = branches;
        _filteredBranches = branches;
        _searchingBranches = false;
        // Re-sync _branch to the freshly loaded instance so DropdownButtonFormField value matches by reference
        if (_branch != null) {
          _branch = branches.cast<BranchModel?>().firstWhere(
            (b) => b?.id == _branch!.id,
            orElse: () => _branch,
          );
        }
      });
      // Re-opened with a PIN/city already filled in: rank straight away,
      // keeping a branch the customer chose earlier.
      _rankBranches(autoSelect: _branch == null);
      final pin = _pincodeCtrl.text.trim();
      if (pin.length == 6) _labLookupPin(pin);
    } catch (_) {
      if (mounted) setState(() => _searchingBranches = false);
    }
  }

  // Lab Test: orders ALL branches — ones matching the PIN or city first,
  // then nearest first (when the PIN's map point is known), then by name —
  // and selects the first match automatically. Never hides a branch, so the
  // dropdown is never empty while branches exist.
  void _rankBranches({bool autoSelect = true}) {
    if (_mode != 'Lab Test' || !mounted) return;
    final pin  = _pincodeCtrl.text.trim();
    final city = _cityCtrl.text.trim().toLowerCase();

    _branchDistKm.clear();
    if (_labPinLat != null && _labPinLng != null) {
      for (final b in _allBranches) {
        if (b.lat != null && b.lng != null) {
          _branchDistKm[b.id] = Geolocator.distanceBetween(_labPinLat!, _labPinLng!, b.lat!, b.lng!) / 1000;
        }
      }
    }

    bool pinMatch(BranchModel b)  => pin.length == 6 && b.pincode?.trim() == pin;
    bool cityMatch(BranchModel b) => city.length >= 3 && [b.location, b.address, b.name]
        .any((s) => s != null && s.toLowerCase().contains(city));
    int rank(BranchModel b) => pinMatch(b) ? 0 : cityMatch(b) ? 1 : 2;

    final ranked = [..._allBranches]..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final da = _branchDistKm[a.id], db = _branchDistKm[b.id];
      if (da != null && db != null) return da.compareTo(db);
      if (da != null) return -1;
      if (db != null) return 1;
      return a.name.compareTo(b.name);
    });

    setState(() {
      _filteredBranches = ranked;
      final best = ranked.isNotEmpty && rank(ranked.first) < 2 ? ranked.first : null;
      if (autoSelect && best != null) {
        _branch = best;
        _branchError = false;
        _branchMatchNote = pinMatch(best)
            ? 'Branch selected for your pincode — you can change it'
            : 'Branch selected for your city — you can change it';
      } else if (best == null) {
        _branchMatchNote = null;
      }
    });
  }

  // Lab Test: district + map point for a 6-digit PIN (same India Post +
  // Google geocode lookups Home Collection uses). Results for a PIN the
  // customer has since changed are ignored.
  Future<void> _labLookupPin(String pin) async {
    if (_labLookedUpPin == pin) return;
    _labLookedUpPin = pin;
    setState(() => _labPinLookup = true);
    String? district;
    double? lat, lng;
    try {
      final res = await http
          .get(Uri.parse('https://api.postalpincode.in/pincode/$pin'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        if (data.isNotEmpty && data[0]['Status'] == 'Success') {
          final offices = data[0]['PostOffice'] as List;
          if (offices.isNotEmpty) district = offices[0]['District'] as String?;
        }
      }
      final geoRes = await http.get(Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?address=$pin,India&key=${AppConstants.googleMapsApiKey}',
      )).timeout(const Duration(seconds: 8));
      if (geoRes.statusCode == 200) {
        final geo = jsonDecode(geoRes.body) as Map<String, dynamic>;
        final results = geo['results'] as List?;
        if (geo['status'] == 'OK' && results != null && results.isNotEmpty) {
          final loc = (results[0]['geometry'] as Map)['location'] as Map;
          lat = (loc['lat'] as num).toDouble();
          lng = (loc['lng'] as num).toDouble();
        }
      }
    } catch (e) {
      debugPrint('[LocationSheet] Lab PIN lookup error: $e');
    }
    if (!mounted || _pincodeCtrl.text.trim() != pin) return;
    setState(() {
      _labPinLookup = false;
      _labPinLat = lat;
      _labPinLng = lng;
    });
    // Filling the city re-ranks through its listener; rank once more so
    // the new distances apply either way.
    if (district != null && _cityCtrl.text.trim().isEmpty) _cityCtrl.text = district;
    _rankBranches();
  }

  // Home Collection live location, in order: location switched on →
  // permission granted → an accurate GPS fix → reverse-geocoded address.
  // Each failure sets _locationIssue, which shows its own message and
  // action under the "Use Current Location" card.
  //
  // No flicker: the current message (if any) stays where it is while the
  // lookup runs — its button just reads "Checking…" — and is replaced only
  // by the final outcome, so the sheet changes once instead of jumping
  // between spinner and message.
  Future<void> _getCurrentLocation() async {
    if (!mounted) return;
    _settleTimer?.cancel();
    final id = ++_locRequestId;
    bool stale() => !mounted || id != _locRequestId;

    setState(() {
      _isGeocoding    = true;
      _waitingForFix  = false;
      _gpsSelected    = false;
      _manualSelected = false;
      _locationError  = false;
    });

    void finish(_LocationIssue issue) {
      if (stale()) return;
      setState(() { _isGeocoding = false; _waitingForFix = false; _locationIssue = issue; });
    }

    try {
      // 1. Location (GPS) must be switched on.
      if (!await Geolocator.isLocationServiceEnabled()) {
        debugPrint('[LocationSheet] location service is OFF');
        return finish(_LocationIssue.serviceOff);
      }

      // 2. Permission — asked here; the customer cannot continue without it.
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (stale()) return;
      if (perm == LocationPermission.deniedForever) {
        debugPrint('[LocationSheet] permission denied forever');
        return finish(_LocationIssue.permissionDeniedForever);
      }
      if (perm == LocationPermission.denied) {
        debugPrint('[LocationSheet] permission denied');
        return finish(_LocationIssue.permissionDenied);
      }

      // 3. Wait for a precise fix. Right after location is switched on the
      // phone's first readings come from Wi-Fi / mobile towers (often several
      // km off) and sharpen within seconds, so the first reading is not
      // judged on its own. The Home Collection fare is priced from this
      // point, so a location that never gets precise enough is refused.
      setState(() => _waitingForFix = true);
      final pos = await _waitForAccurateFix();
      if (stale()) return;
      if (pos == null) return finish(_LocationIssue.failed);
      debugPrint('[LocationSheet] GPS accuracy: ${pos.accuracy.toStringAsFixed(0)} m');
      if (pos.accuracy > _maxGpsAccuracyMeters) {
        _approxAccuracyMeters = pos.accuracy;
        return finish(_LocationIssue.approximate);
      }

      _gpsLat = pos.latitude;
      _gpsLng = pos.longitude;

      // 4. Reverse geocode to get the address (and its pincode, used to
      // detect the branch).
      final address = await _reverseGeocode(pos.latitude, pos.longitude);
      if (stale()) return;

      setState(() {
        _gpsAddress    = address;
        _gpsSelected   = true;
        _isGeocoding   = false;
        _waitingForFix = false;
        _locationIssue = _LocationIssue.none;
      });

      debugPrint('[LocationSheet] GPS Location: ${pos.latitude}, ${pos.longitude}');
      debugPrint('[LocationSheet] GPS Address: $address');
    } catch (e) {
      debugPrint('[LocationSheet] GPS error: $e');
      finish(_LocationIssue.failed);
    }
  }

  // Listens to location updates until one is within _maxGpsAccuracyMeters,
  // or _fixTimeout passes — then returns the best (most accurate) reading
  // seen, or null if none arrived at all.
  Future<Position?> _waitForAccurateFix() async {
    await _fixSub?.cancel();
    final done = Completer<Position?>();
    Position? best;
    void complete() {
      if (done.isCompleted) return;
      _fixSub?.cancel();
      _fixSub = null;
      done.complete(best);
    }

    final timer = Timer(_fixTimeout, complete);
    try {
      _fixSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 0),
      ).listen((p) {
        if (best == null || p.accuracy < best!.accuracy) best = p;
        if (p.accuracy <= _maxGpsAccuracyMeters) complete();
      }, onError: (Object e) {
        debugPrint('[LocationSheet] position stream error: $e');
        complete();
      });
    } catch (e) {
      debugPrint('[LocationSheet] position stream unavailable: $e');
      complete();
    }
    final result = await done.future;
    timer.cancel();
    return result;
  }

  // Message + action for the current _locationIssue. Web can't open the
  // device's settings, so it only gets "Try again" with browser wording.
  ({String message, String action, VoidCallback onAction})? _locationIssueInfo() {
    switch (_locationIssue) {
      case _LocationIssue.none:
        return null;
      case _LocationIssue.serviceOff:
        return kIsWeb
            ? (message: 'Location is turned off on this device. Turn it on, then try again.',
               action: 'Try again', onAction: _getCurrentLocation)
            : (message: 'Location is turned off. Turn it on so we can use your current location.',
               action: 'Turn on location', onAction: () => Geolocator.openLocationSettings());
      case _LocationIssue.permissionDenied:
        return (message: 'Allow location access so we can find your branch and calculate the service charge.',
                action: 'Allow location', onAction: _getCurrentLocation);
      case _LocationIssue.permissionDeniedForever:
        return kIsWeb
            ? (message: 'Location access is blocked in your browser. Allow it in the browser\'s site settings, then try again.',
               action: 'Try again', onAction: _getCurrentLocation)
            : (message: 'Location access is turned off for MicroLab. Allow it in the app settings.',
               action: 'Open settings', onAction: () => Geolocator.openAppSettings());
      case _LocationIssue.approximate:
        final km = ((_approxAccuracyMeters ?? 0) / 1000).toStringAsFixed(1);
        return (message: 'Your location is only approximate (about ±$km km). '
                    'Turn on precise / high-accuracy location and try again, or enter your pincode below.',
                action: 'Try again', onAction: _getCurrentLocation);
      case _LocationIssue.failed:
        return (message: 'Couldn\'t get your current location.',
                action: 'Try again', onAction: _getCurrentLocation);
    }
  }
  
  Future<String> _reverseGeocode(double lat, double lng) async {
    try {
      final apiKey = AppConstants.googleMapsApiKey;
      if (apiKey.isEmpty) return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
      
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?latlng=$lat,$lng'
        '&key=$apiKey',
      );
      
      final response = await http.get(url).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['status'] == 'OK') {
          final results = data['results'] as List;
          if (results.isNotEmpty) {
            return results[0]['formatted_address'] as String;
          }
        }
      }
    } catch (e) {
      debugPrint('[LocationSheet] Reverse geocoding error: $e');
    }
    return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }
  
  Future<void> _detectLocationFromPincode() async {
    final pincode = _pincodeCtrl.text.trim();
    if (pincode.length != 6) {
      setState(() => _locationError = true);
      return;
    }
    
    setState(() {
      _isGeocoding = true;
      _isPincodeLookup = true;
      _gpsSelected = false;
      _manualSelected = false;
      _locationError = false;
    });

    try {
      await _lookupPincode(pincode);
    } finally {
      if (mounted) setState(() => _isPincodeLookup = false);
    }
  }

  Future<void> _lookupPincode(String pincode) async {
    try {
      // First detect area from pincode API
      final res = await http
          .get(Uri.parse('https://api.postalpincode.in/pincode/$pincode'))
          .timeout(const Duration(seconds: 8));
          
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List;
        if (data.isNotEmpty && data[0]['Status'] == 'Success') {
          final offices = data[0]['PostOffice'] as List;
          if (offices.isNotEmpty) {
            final po = offices[0];
            final area = po['Name'] as String;
            final district = po['District'] as String;
            final state = po['State'] as String;
            final city = _cityCtrl.text.trim().isEmpty ? district : _cityCtrl.text.trim();
            
            setState(() {
              _detectedArea = '$area, $district, $state';
              if (_cityCtrl.text.trim().isEmpty) _cityCtrl.text = district;
            });
            
            // Geocode to get coordinates
            final geoUri = Uri.parse(
              'https://maps.googleapis.com/maps/api/geocode/json'
              '?address=$pincode,India'
              '&key=${AppConstants.googleMapsApiKey}',
            );
            
            final geoRes = await http.get(geoUri).timeout(const Duration(seconds: 8));
            if (geoRes.statusCode == 200) {
              final geoData = jsonDecode(geoRes.body) as Map<String, dynamic>;
              if (geoData['status'] == 'OK') {
                final results = geoData['results'] as List;
                if (results.isNotEmpty) {
                  final loc = (results[0]['geometry'] as Map)['location'] as Map;
                  _manualLat = (loc['lat'] as num).toDouble();
                  _manualLng = (loc['lng'] as num).toDouble();
                  
                  // Build manual address
                  _manualAddress = '$area, $city, $state - $pincode';
                  
                  setState(() {
                    _manualSelected = true;
                    _isGeocoding = false;
                  });
                  
                  debugPrint('[LocationSheet] Pincode detected: $_manualAddress');
                  debugPrint('[LocationSheet] Coordinates: $_manualLat, $_manualLng');
                  return;
                }
              }
            }
          }
        }
      }
      
      // If pincode API fails, try direct geocoding
      final geoUri = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json'
        '?address=$pincode,India'
        '&key=${AppConstants.googleMapsApiKey}',
      );
      
      final geoRes = await http.get(geoUri).timeout(const Duration(seconds: 8));
      if (geoRes.statusCode == 200) {
        final geoData = jsonDecode(geoRes.body) as Map<String, dynamic>;
        if (geoData['status'] == 'OK') {
          final results = geoData['results'] as List;
          if (results.isNotEmpty) {
            final loc = (results[0]['geometry'] as Map)['location'] as Map;
            _manualLat = (loc['lat'] as num).toDouble();
            _manualLng = (loc['lng'] as num).toDouble();
            _manualAddress = results[0]['formatted_address'] as String;
            
            setState(() {
              _manualSelected = true;
              _isGeocoding = false;
            });
            
            debugPrint('[LocationSheet] Geocoded pincode: $_manualAddress');
            return;
          }
        }
      }
      
      setState(() {
        _detectedArea = 'Not found';
        _isGeocoding = false;
        _locationError = true;
      });
      
    } catch (e) {
      debugPrint('[LocationSheet] Pincode detection error: $e');
      setState(() {
        _isGeocoding = false;
        _locationError = true;
      });
    }
  }
  
  void _onPincodeChanged() {
    final pin = _pincodeCtrl.text.trim();
    if (_mode != 'Home Collection') return;
    if (pin.length == 6) {
      // Auto-detect when pincode length is 6
      _detectLocationFromPincode();
    } else {
      if (_detectedArea != null || _detecting) {
        setState(() { 
          _detectedArea = null; 
          _detecting = false;
          _manualSelected = false;
        });
      }
    }
  }

  // Lab Test: runs on every PIN / city keystroke. Re-ranks the branches
  // (keeps the chosen branch unless a match is found) and looks up a PIN
  // once it has 6 digits. A shorter PIN drops the previous map point.
  void _filterBranches() {
    if (_mode != 'Lab Test') return;
    final pin = _pincodeCtrl.text.trim();
    if (pin.length != 6 && (_labPinLat != null || _labLookedUpPin != null || _labPinLookup)) {
      _labLookedUpPin = null;
      _labPinLat = null;
      _labPinLng = null;
      _labPinLookup = false;
    }
    _rankBranches();
    if (pin.length == 6) _labLookupPin(pin);
  }

  void _apply() {
    debugPrint('\n📌 [APPLY CHANGES] ─────────────────────────────────');
    debugPrint('   mode        : $_mode');
    if (_mode == 'Home Collection') {
      debugPrint('   input method: ${_gpsSelected ? 'Current Live Location' : _manualSelected ? 'Manual Address/Pincode' : '⚠️ none selected'}');
      if (_gpsSelected) {
        debugPrint('   gps lat/lng : $_gpsLat, $_gpsLng');
        debugPrint('   gps address : ${_gpsAddress ?? '—'}');
      } else if (_manualSelected) {
        debugPrint('   pincode     : ${_pincodeCtrl.text.trim()}');
        debugPrint('   address     : ${_addressCtrl.text.trim().isNotEmpty ? _addressCtrl.text.trim() : (_manualAddress ?? '—')}');
        debugPrint('   city        : ${_cityCtrl.text.trim().isNotEmpty ? _cityCtrl.text.trim() : '—'}');
        debugPrint('   manual lat/lng: $_manualLat, $_manualLng');
      }
    }
    debugPrint('──────────────────────────────────────────────────\n');
    if (_mode == 'Home Collection') {
      if (_gpsSelected && _gpsLat != null && _gpsLng != null) {
        // Use GPS location.
        // lat/lng MUST fire before address — onAddressChanged synchronously
        // triggers _tryExtractPincodeFromAddress -> _autoDetectBranch, which
        // reads _lat/_lng to build the branch-lookup request. Firing address
        // first sent that request with lat/lng still null, so the GPS
        // eligibility walk (online tech + slots) never ran for real
        // Current-Live-Location taps — it silently fell through to the
        // city/name text-match steps instead. Same ordering hazard as the
        // manual branch below, just previously unhandled here.
        widget.onLatLngChanged?.call(_gpsLat, _gpsLng);
        widget.onAddressChanged(_gpsAddress);
        widget.onPincodeChanged(null);
        widget.onCityChanged(null);
      }
      else if (_manualSelected && _manualLat != null && _manualLng != null) {
        // Use manual pincode-based location.
        // city and lat/lng MUST fire before pincode so they are ready when
        // auto-detect triggers. Address goes last: with the pincode already
        // set it doesn't scan the address for one — that scan starts a second
        // lookup, marked as GPS and without coordinates, which matched a
        // different branch by city name.
        final address = _addressCtrl.text.trim().isNotEmpty
            ? _addressCtrl.text.trim()
            : _manualAddress;
        final city = _cityCtrl.text.trim().isEmpty ? null : _cityCtrl.text.trim();
        widget.onCityChanged(city);                        // 1st — set city
        widget.onLatLngChanged?.call(_manualLat, _manualLng);
        widget.onPincodeChanged(_pincodeCtrl.text.trim()); // triggers auto-detect (city + lat/lng already set)
        widget.onAddressChanged(address);                  // last — pincode already set, no second lookup
      }
      else {
        setState(() => _locationError = true);
        return;
      }
    }
    
    if (_mode == 'Lab Test' && _branch == null) {
      setState(() => _branchError = true);
      return;
    }

    widget.onModeChanged(_mode);
    if (_mode == 'Lab Test') {
      widget.onBranchChanged(_branch);
      widget.onPincodeChanged(_pincodeCtrl.text.trim().isEmpty ? null : _pincodeCtrl.text.trim());
      widget.onCityChanged(_cityCtrl.text.trim().isEmpty ? null : _cityCtrl.text.trim());
      widget.onAddressChanged(null);
    }
    Navigator.pop(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settleTimer?.cancel();
    _serviceStatusSub?.cancel();
    _fixSub?.cancel();
    _pincodeCtrl.removeListener(_filterBranches);
    _cityCtrl.removeListener(_filterBranches);
    _pincodeCtrl.removeListener(_onPincodeChanged);
    _pincodeCtrl.dispose();
    _cityCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return CustomerThemeScope(
      child: Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: CxSize.sheetMaxWidth),
      child: Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: CxRadius.sheetTop,
      ),
      padding: EdgeInsets.fromLTRB(CxSpace.xl, 0, CxSpace.xl, bottomInset + safeBottom + CxSpace.xl),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CxDragHandle(),

            const Text('Collection Mode', style: CxText.sheetTitle),
            const SizedBox(height: CxSpace.md),

            // Mode selector
            Row(
              children: widget.modes.map((m) {
                final sel = _mode == m;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                        right: m == widget.modes.first ? 8 : 0),
                    child: Material(
                      color: sel ? CxColors.brand : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: CxRadius.mdAll,
                        side: BorderSide(color: sel ? CxColors.brand : CxColors.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                      onTap: () {
                        final prev = _mode;
                        setState(() => _mode = m);
                        if (m == 'Lab Test' && _allBranches.isEmpty) {
                          _loadBranches();
                        } else if (m == 'Lab Test') {
                          _filterBranches(); // rank + PIN lookup for what is already typed
                        }
                        // Switching to Home Collection: check location
                        // on/permission right away, as on opening the sheet.
                        if (m == 'Home Collection' && prev != m &&
                            !_gpsSelected && !_manualSelected && !_isGeocoding) {
                          _getCurrentLocation();
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Column(
                          children: [
                            Icon(
                              m == 'Home Collection'
                                  ? Icons.home_outlined
                                  : Icons.local_hospital_outlined,
                              size: 24,
                              color: sel ? Colors.white : CxColors.textSecondary,
                            ),
                            const SizedBox(height: 6),
                            Text(m,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: sel ? Colors.white : CxColors.textPrimary)),
                          ],
                        ),
                      ),
                    ),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 20),

            if (_mode == 'Home Collection') ...[
              const Text('Select Location Method', style: CxText.label),
              const SizedBox(height: CxSpace.md),

              // Option 1: GPS Current Location Button
              Material(
                color: _gpsSelected ? CxColors.brandSurface : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: CxRadius.lgAll,
                  side: BorderSide(
                    color: _gpsSelected ? CxColors.brand : CxColors.border,
                    width: _gpsSelected ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                onTap: _isGeocoding ? null : _getCurrentLocation,
                child: Container(
                  padding: const EdgeInsets.all(CxSpace.lg),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: const BoxDecoration(
                          color: CxColors.brandSurface,
                          borderRadius: CxRadius.mdAll,
                        ),
                        child: _isGeocoding && !_manualSelected
                            ? const Center(
                                child: SizedBox(
                                  width: 24, height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.brandGreen,
                                  ),
                                ),
                              )
                            : const Icon(Icons.my_location_rounded,
                                size: 26, color: CxColors.brand),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Use Current Location', style: CxText.cardTitle),
                            const SizedBox(height: 4),
                            Text(
                              _gpsSelected && _gpsAddress != null
                                  ? _gpsAddress!
                                  : _isGeocoding && _waitingForFix
                                      ? 'Getting your precise location…'
                                      : _isGeocoding
                                          ? 'Checking your location…'
                                          : 'Get your real-time location using GPS',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: _gpsSelected ? CxColors.brand : CxColors.textSecondary),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (_gpsSelected)
                        const Icon(Icons.check_circle_rounded,
                            color: CxColors.brand, size: 24),
                    ],
                  ),
                ),
                ),
              ),

              // Location off / permission refused / approximate — what
              // went wrong and the one action that fixes it. While a new
              // lookup runs the message stays put (its button reads
              // "Checking…") and is only replaced by the final outcome;
              // AnimatedSize makes that single change smooth, so the sheet
              // never jumps between spinner and message.
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                alignment: Alignment.topCenter,
                child: switch (_locationIssueInfo()) {
                  final issue? when !_gpsSelected && !_manualSelected => Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(CxSpace.md, 6, 4, 6),
                      decoration: const BoxDecoration(
                        color: CxColors.warningSurface,
                        borderRadius: CxRadius.mdAll,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.location_off_outlined, size: 18, color: CxColors.warning),
                          const SizedBox(width: CxSpace.sm),
                          Expanded(
                            child: Text(issue.message,
                                style: const TextStyle(fontSize: 13, color: CxColors.textPrimary, height: 1.35)),
                          ),
                          const SizedBox(width: 4),
                          TextButton(
                            onPressed: _isGeocoding ? null : issue.onAction,
                            style: TextButton.styleFrom(
                              foregroundColor: CxColors.brand,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              minimumSize: const Size(0, 40),
                            ),
                            child: Text(_isGeocoding ? 'Checking…' : issue.action,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _ => const SizedBox(width: double.infinity),
                },
              ),

              const SizedBox(height: 16),
              
              // Option 2: Manual Address with Pincode
              GestureDetector(
                onTap: () {
                  setState(() {
                    _isManualMode = true;
                    _gpsSelected = false;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(CxSpace.lg),
                  decoration: BoxDecoration(
                    color: _manualSelected ? CxColors.brandSurface : Colors.white,
                    borderRadius: CxRadius.lgAll,
                    border: Border.all(
                      color: _manualSelected ? CxColors.brand : CxColors.border,
                      width: _manualSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const CxIconBadge(icon: Icons.edit_location_rounded, tone: CxTone.info, size: 48),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Enter Address Manually', style: CxText.cardTitle),
                                const SizedBox(height: 4),
                                Text(
                                  _manualSelected && _manualAddress != null
                                      ? _manualAddress!
                                      : 'Enter pincode to auto-detect location',
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: _manualSelected ? CxColors.brand : CxColors.textSecondary),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          if (_manualSelected)
                            const Icon(Icons.check_circle_rounded,
                                color: AppColors.brandGreen, size: 24),
                        ],
                      ),
                      
                      // Manual entry form (shown when manual mode is active)
                      if (_manualSelected || _isManualMode) ...[
                        const SizedBox(height: 16),
                        const Divider(),
                        const SizedBox(height: 12),
                        
                        // PIN Code (left) + Location (right). Location and
                        // Address below stay disabled while the PIN is
                        // being looked up.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _pincodeCtrl,
                                keyboardType: TextInputType.number,
                                maxLength: 6,
                                style: const TextStyle(fontSize: 14),
                                decoration: InputDecoration(
                                  hintText: 'Pincode *',
                                  hintStyle: const TextStyle(color: AppColors.textHint),
                                  counterText: '',
                                  prefixIcon: const Icon(Icons.pin_outlined, size: 18, color: AppColors.textHint),
                                  filled: true,
                                  fillColor: AppColors.background,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _cityCtrl,
                                enabled: !_isPincodeLookup,
                                style: const TextStyle(fontSize: 14),
                                decoration: InputDecoration(
                                  hintText: 'Location',
                                  hintStyle: const TextStyle(color: AppColors.textHint),
                                  prefixIcon: const Icon(Icons.location_city_outlined, size: 18, color: AppColors.textHint),
                                  filled: true,
                                  fillColor: _isPincodeLookup ? AppColors.divider.withValues(alpha: 0.5) : AppColors.background,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                                  disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                                ),
                              ),
                            ),
                          ],
                        ),

                        // Full address (bottom)
                        const SizedBox(height: 10),
                        TextField(
                          controller: _addressCtrl,
                          enabled: !_isPincodeLookup,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'House no, Street, Area (optional)',
                            hintStyle: const TextStyle(color: AppColors.textHint),
                            prefixIcon: const Icon(Icons.home_outlined, size: 18, color: AppColors.textHint),
                            filled: true,
                            fillColor: _isPincodeLookup ? AppColors.divider.withValues(alpha: 0.5) : AppColors.background,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                            disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                          ),
                        ),

                        // Pincode lookup indicator — only for a typed PIN, not GPS
                        if (_isPincodeLookup) ...[
                          const SizedBox(height: 8),
                          const Row(children: [
                            SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.brandGreen),
                            ),
                            SizedBox(width: 8),
                            Text('Detecting location from pincode...',
                                style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                          ]),
                        ],
                        
                        // Detected area result
                        if (_detectedArea != null && _detectedArea != 'Not found' && _manualSelected) ...[
                          const SizedBox(height: CxSpace.sm),
                          CxBanner(tone: CxTone.success, message: 'Detected: $_detectedArea'),
                        ] else if (_detectedArea == 'Not found') ...[
                          const SizedBox(height: CxSpace.sm),
                          const CxBanner(
                            tone: CxTone.warning,
                            message: 'Pincode not found — enter city manually',
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              
              if (_locationError) ...[
                const SizedBox(height: CxSpace.md),
                const CxBanner(
                  tone: CxTone.error,
                  message: 'Please select a location method or enter valid pincode',
                ),
              ],
            ],

            if (_mode == 'Lab Test') ...[
              RichText(
                text: const TextSpan(
                  text: 'Pincode or City',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textPrimary),
                  children: [TextSpan(text: '  (to find nearby branches)', style: TextStyle(fontSize: 12, color: CxColors.textSecondary, fontWeight: FontWeight.w400))],
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _pincodeCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    maxLength: 6,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Pincode',
                      hintStyle: const TextStyle(color: AppColors.textHint),
                      counterText: '',
                      prefixIcon: const Icon(Icons.pin_outlined, size: 18, color: AppColors.textHint),
                      filled: true, fillColor: AppColors.background,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _cityCtrl,
                    enabled: !_labPinLookup,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'City',
                      hintStyle: const TextStyle(color: AppColors.textHint),
                      prefixIcon: const Icon(Icons.location_city_outlined, size: 18, color: AppColors.textHint),
                      filled: true,
                      fillColor: _labPinLookup ? AppColors.divider.withValues(alpha: 0.5) : AppColors.background,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                      disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                    ),
                  ),
                ),
              ]),
              if (_labPinLookup) ...[
                const SizedBox(height: 8),
                const Row(children: [
                  SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.brandGreen),
                  ),
                  SizedBox(width: 8),
                  Text('Detecting location from pincode...',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ]),
              ],
              const SizedBox(height: 16),
              RichText(
                text: const TextSpan(
                  text: 'Select Branch',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textPrimary),
                  children: [TextSpan(text: ' *', style: TextStyle(color: CxColors.error))],
                ),
              ),
              const SizedBox(height: 8),
              if (_searchingBranches)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: const Row(children: [
                    SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: CxColors.brand)),
                    SizedBox(width: 10),
                    Text('Loading branches…', style: TextStyle(fontSize: 13, color: CxColors.textSecondary)),
                  ]),
                )
              else if (_filteredBranches.isEmpty)
                // Only when no branch exists at all — the list is never
                // filtered down to nothing.
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: const Row(children: [
                    Icon(Icons.search_off_rounded, size: 16, color: AppColors.textHint),
                    SizedBox(width: 8),
                    Text('No branches available right now', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ]),
                )
              else
                DropdownButtonFormField<BranchModel>(
                  value: _filteredBranches.contains(_branch) ? _branch : null,
                  hint: const Text('Choose a branch', style: TextStyle(fontSize: 14, color: AppColors.textHint)),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.local_hospital_outlined, size: 18, color: AppColors.textHint),
                    filled: true, fillColor: AppColors.background,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _branchError ? const Color(0xFFD32F2F) : AppColors.divider)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: _branchError ? const Color(0xFFD32F2F) : AppColors.divider)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
                  dropdownColor: AppColors.white,
                  borderRadius: BorderRadius.circular(12),
                  isExpanded: true,
                  items: _filteredBranches.map((b) {
                    final km = _branchDistKm[b.id];
                    return DropdownMenuItem(
                      value: b,
                      child: Text(
                        km != null ? '${b.name}  ·  ${km < 1 ? '<1' : km.toStringAsFixed(1)} km' : b.name,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  // Disabled while the PIN is being looked up.
                  onChanged: _labPinLookup
                      ? null
                      : (b) => setState(() { _branch = b; _branchError = false; _branchMatchNote = null; }),
                ),
              if (_branchMatchNote != null && _branch != null && !_labPinLookup) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.check_circle_outline_rounded, size: 16, color: CxColors.brand),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_branchMatchNote!,
                        style: const TextStyle(fontSize: 13, color: CxColors.brand)),
                  ),
                ]),
              ],
              if (_branchError) ...[
                const SizedBox(height: 6),
                const Row(children: [
                  Icon(Icons.error_outline, size: 16, color: CxColors.error),
                  SizedBox(width: 6),
                  Text('Please select a branch', style: TextStyle(fontSize: 13, color: CxColors.error)),
                ]),
              ],
            ],

            const SizedBox(height: CxSpace.xxl),

            CxButton(
              onPressed: _apply,
              icon: Icons.check_rounded,
              label: 'Apply Location',
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
// ─── Test Card ────────────────────────────────────────────────────────────────

class _TestCard extends StatelessWidget {
  final TestModel test;
  final bool inCart;
  final VoidCallback onAdd;
  final VoidCallback onTap;
  const _TestCard({
    required this.test,
    required this.inCart,
    required this.onAdd,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Tapping the card adds / removes the test (same as before).
    return Semantics(
      button: true,
      selected: inCart,
      child: Material(
      color: inCart ? CxColors.brandSurface : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: CxRadius.lgAll,
        side: BorderSide(
            color: inCart ? CxColors.brand : CxColors.border,
            width: inCart ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
      onTap: onAdd,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CxSpace.md, CxSpace.md, CxSpace.lg, CxSpace.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Checkbox
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: inCart,
                onChanged: (_) => onAdd(),
                activeColor: CxColors.brand,
                side: const BorderSide(color: CxColors.textHint, width: 1.5),
                shape: const CircleBorder(),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: CxSpace.md),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      CxChip(
                        label: test.type == 'package' ? 'Package' : 'Test',
                        icon: test.type == 'package' ? Icons.inventory_2_outlined : Icons.science_outlined,
                        tone: test.type == 'package' ? CxTone.brand : CxTone.info,
                      ),
                      if (test.hasOffer)
                        CxChip(
                          label: '${(test.offerPercent ?? 0).toInt()}% OFF',
                          tone: CxTone.offer,
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(test.name,
                      style: CxText.cardTitle),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 10,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.schedule_outlined,
                            size: 14, color: CxColors.textHint),
                        const SizedBox(width: 3),
                        Text(test.reportStatus, style: CxText.caption),
                      ]),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.category_outlined,
                            size: 14, color: CxColors.textHint),
                        const SizedBox(width: 3),
                        Text(test.category, style: CxText.caption),
                      ]),
                      if (test.docRequired)
                        const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.description_outlined,
                              size: 14, color: CxColors.warning),
                          SizedBox(width: 3),
                          Text('Rx',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600, color: CxColors.warning)),
                        ]),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: CxSpace.md),
            // Price
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('₹${test.finalPrice.toInt()}',
                    style: CxText.price),
                if (test.hasOffer)
                  Text('₹${test.originalPrice.toInt()}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: CxColors.textHint,
                          decoration: TextDecoration.lineThrough)),
              ],
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

// ─── Section Header ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CxSpace.gutter),
      child: Text(title, style: CxText.sectionTitle),
    );
  }
}



// ─── Test Detail Sheet ────────────────────────────────────────────────────────

class _TestDetailSheet extends StatelessWidget {
  final TestModel test;
  final bool inCart;
  final VoidCallback onToggleCart;
  const _TestDetailSheet({
    required this.test,
    required this.inCart,
    required this.onToggleCart,
  });

  String _formatTat(String raw) {
    final hours = int.tryParse(raw);
    if (hours == null) return raw;
    if (hours < 24) return '$hours hour${hours == 1 ? '' : 's'}';
    final days = hours ~/ 24;
    return '$days day${days == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    return CustomerThemeScope(
      child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: CxRadius.sheetTop,
      ),
      constraints: BoxConstraints(
          maxWidth: CxSize.sheetMaxWidth,
          maxHeight: MediaQuery.of(context).size.height * 0.80),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CxDragHandle(),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(CxSpace.xl, 0, CxSpace.xl, CxSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: CxSpace.sm,
                    runSpacing: 4,
                    children: [
                      CxChip(
                        label: test.type == 'package' ? 'Package' : 'Test',
                        icon: test.type == 'package' ? Icons.inventory_2_outlined : Icons.science_outlined,
                        tone: test.type == 'package' ? CxTone.brand : CxTone.info,
                      ),
                      if (test.hasOffer)
                        CxChip(
                          label: '${(test.offerPercent ?? 0).toInt()}% OFF',
                          icon: Icons.local_offer_outlined,
                          tone: CxTone.offer,
                        ),
                    ],
                  ),
                  const SizedBox(height: CxSpace.md),
                  Text(test.name, style: CxText.pageTitle),
                  const SizedBox(height: CxSpace.sm),
                  Text(test.description, style: CxText.body.copyWith(color: CxColors.textSecondary)),
                  const SizedBox(height: CxSpace.lg),
                  const Divider(height: 1),
                  const SizedBox(height: CxSpace.md),
                  _InfoRow('Category', test.category),
                  _InfoRow('Report Status', _formatTat(test.reportStatus)),
                  _InfoRow('Prescription',
                      test.docRequired ? 'Required' : 'Not required',
                      highlight: test.docRequired),
                  if (test.preInstructions != null) ...[
                    const SizedBox(height: CxSpace.sm),
                    CxBanner(
                      tone: CxTone.success,
                      icon: Icons.checklist_rounded,
                      message: 'Preparation: ${test.preInstructions!}',
                    ),
                    const SizedBox(height: CxSpace.sm),
                  ],
                  if (test.docRequired) ...[
                    const SizedBox(height: CxSpace.sm),
                    const CxBanner(
                      tone: CxTone.warning,
                      message: 'Full payment is available only after a technician verifies your uploaded prescription.',
                    ),
                    const SizedBox(height: CxSpace.xs),
                  ],
                  _InfoRow('Original Price', '₹${test.originalPrice.toInt()}'),
                  if (test.hasOffer) ...[
                    _InfoRow('Discount',
                        '${(test.offerPercent ?? 0).toInt()}%'),
                    _InfoRow('Offer Valid',
                        '${test.startDate ?? ''} – ${test.endDate ?? ''}'),
                  ],
                  _InfoRow('Final Price', '₹${test.finalPrice.toInt()}',
                      highlight: true),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
                CxSpace.xl, CxSpace.md, CxSpace.xl, MediaQuery.of(context).padding.bottom + CxSpace.lg),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: CxColors.border)),
            ),
            child: Row(children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Price', style: CxText.caption),
                  CxPrice(
                    price: '₹${test.finalPrice.toInt()}',
                    originalPrice: test.hasOffer ? '₹${test.originalPrice.toInt()}' : null,
                    fontSize: 18,
                  ),
                ],
              ),
              const SizedBox(width: CxSpace.lg),
              Expanded(
                child: inCart
                    ? CxButton.destructive(
                        icon: Icons.remove_shopping_cart_outlined,
                        label: 'Remove from cart',
                        onPressed: () {
                          onToggleCart();
                          Navigator.pop(context);
                        },
                      )
                    : CxButton(
                        icon: Icons.add_shopping_cart_rounded,
                        label: 'Add to cart',
                        onPressed: () {
                          onToggleCart();
                          Navigator.pop(context);
                        },
                      ),
              ),
            ]),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  const _InfoRow(this.label, this.value, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: CxText.bodySecondary),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: highlight
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: highlight
                        ? CxColors.brand
                        : CxColors.textPrimary)),
          ),
        ],
      ),
    );
  }
}

// ─── Recommended Tests Sheet ────────────────────────────────────────────────
// Shown once, before checkout, when any cart item is flagged is_recommended
// with a non-empty recommended_ids list (ip_products). Each one is an
// either/or alternative to whatever cart item suggested it, not an add-on —
// choosing a recommendation swaps it in for that item. The customer can
// equally just continue with what they already picked; nothing here is
// required.

class _RecommendedTestsSheet extends StatefulWidget {
  final List<TestModel> tests;
  final Map<String, List<TestModel>> replaces; // recommended id -> cart item(s) it replaces
  final ValueChanged<List<TestModel>> onContinue; // all currently-selected tests
  const _RecommendedTestsSheet({
    required this.tests,
    required this.replaces,
    required this.onContinue,
  });

  @override
  State<_RecommendedTestsSheet> createState() => _RecommendedTestsSheetState();
}

class _RecommendedTestsSheetState extends State<_RecommendedTestsSheet> {
  // Multi-select: a customer can pick more than one alternative (e.g. swap
  // RFT for both HAEMOGLOBIN and the panel) — nothing is applied to the cart
  // until one of the two bottom buttons is tapped.
  final Set<String> _selectedIds = {};

  void _toggle(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  // Every cart item named as a "replaces" target by at least one
  // recommendation — i.e. what "Continue with My Selection" below keeps.
  List<TestModel> get _originalItems {
    final seen = <String>{};
    final result = <TestModel>[];
    for (final group in widget.replaces.values) {
      for (final t in group) {
        if (seen.add(t.id)) result.add(t);
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return CustomerThemeScope(
      child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: CxRadius.sheetTop,
      ),
      constraints: BoxConstraints(
          maxWidth: CxSize.sheetMaxWidth,
          maxHeight: MediaQuery.of(context).size.height * 0.75),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CxDragHandle(),
          const Padding(
            padding: EdgeInsets.fromLTRB(CxSpace.xl, 0, CxSpace.xl, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CxIconBadge(icon: Icons.auto_awesome_rounded, size: 36),
                    SizedBox(width: CxSpace.md),
                    Expanded(child: Text('Recommended for you', style: CxText.sheetTitle)),
                  ],
                ),
                SizedBox(height: CxSpace.sm),
                Text(
                  'An alternative to what you\'ve already selected — choosing one '
                  'replaces it. Optional, you can continue with your original pick.',
                  style: CxText.bodySecondary,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(CxSpace.xl, CxSpace.md, CxSpace.xl, 0),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(CxSpace.md),
              decoration: BoxDecoration(
                color: CxColors.surfaceMuted,
                borderRadius: CxRadius.mdAll,
                border: Border.all(color: CxColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your current selection', style: CxText.caption),
                  const SizedBox(height: 4),
                  for (final o in _originalItems)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('${o.name}  ·  ₹${o.finalPrice.toInt()}',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600, color: CxColors.textPrimary)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: CxSpace.md),
          const Divider(height: 1),
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.md, CxSpace.gutter, CxSpace.md),
              shrinkWrap: true,
              itemCount: widget.tests.length,
              separatorBuilder: (_, __) => const SizedBox(height: CxSpace.sm),
              itemBuilder: (_, i) {
                final t = widget.tests[i];
                final selected = _selectedIds.contains(t.id);
                final replacesNames =
                    (widget.replaces[t.id] ?? const <TestModel>[]).map((r) => r.name).join(', ');
                // Same circular-checkbox selection style as the main test list
                // (_TestCard) — tapping anywhere on the card toggles it.
                return Semantics(
                  button: true,
                  selected: selected,
                  child: Material(
                  color: selected ? CxColors.brandSurface : Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: CxRadius.lgAll,
                    side: BorderSide(
                        color: selected ? CxColors.brand : CxColors.border,
                        width: selected ? 1.5 : 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                  onTap: () => _toggle(t.id),
                  child: Padding(
                    padding: const EdgeInsets.all(CxSpace.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: selected,
                            onChanged: (_) => _toggle(t.id),
                            activeColor: CxColors.brand,
                            side: const BorderSide(color: CxColors.textHint, width: 1.5),
                            shape: const CircleBorder(),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        const SizedBox(width: CxSpace.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(t.name, style: CxText.cardTitle),
                              if (replacesNames.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Row(children: [
                                  const Icon(Icons.swap_horiz_rounded, size: 15, color: CxColors.textHint),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text('Instead of: $replacesNames',
                                        style: CxText.caption.copyWith(fontStyle: FontStyle.italic)),
                                  ),
                                ]),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: CxSpace.sm),
                        Text('₹${t.finalPrice.toInt()}', style: CxText.price),
                      ],
                    ),
                  ),
                  ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
                CxSpace.xl, CxSpace.md, CxSpace.xl, MediaQuery.of(context).padding.bottom + CxSpace.lg),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: CxColors.border)),
            ),
            child: Column(
              children: [
                // Only enabled once at least one recommendation is checked —
                // applies the swap(s) then proceeds.
                CxButton(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => widget.onContinue(
                            widget.tests.where((t) => _selectedIds.contains(t.id)).toList(),
                          ),
                  icon: Icons.auto_awesome_rounded,
                  label: _selectedIds.isEmpty
                      ? 'Continue with Recommended'
                      : 'Continue with Recommended  ·  ${_selectedIds.length} selected',
                ),
                const SizedBox(height: CxSpace.sm),
                // Always available — explicitly keeps the original cart
                // untouched, regardless of what's checked above.
                CxButton.secondary(
                  onPressed: () => widget.onContinue(const []),
                  label: 'Continue with My Selection',
                ),
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

// ─── Cart Sheet ───────────────────────────────────────────────────────────────

class _CartSheet extends StatefulWidget {
  final List<TestModel> cart;
  final ValueChanged<TestModel> onRemove;
  final VoidCallback onCheckout;
  const _CartSheet({
    required this.cart,
    required this.onRemove,
    required this.onCheckout,
  });

  @override
  State<_CartSheet> createState() => _CartSheetState();
}

class _CartSheetState extends State<_CartSheet> {
  double get _total => widget.cart.fold(0, (s, t) => s + t.finalPrice);

  void _remove(TestModel t) {
    widget.onRemove(t); // mutates parent's list via parent setState
    setState(() {});    // rebuild sheet with updated list
  }

  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    return CustomerThemeScope(
      child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: CxRadius.sheetTop,
      ),
      constraints: BoxConstraints(
          maxWidth: CxSize.sheetMaxWidth,
          maxHeight: MediaQuery.of(context).size.height * 0.75),
      child: cart.isEmpty
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CxDragHandle(),
                const CxEmptyState(
                  icon: Icons.shopping_cart_outlined,
                  title: 'Cart is empty',
                ),
                SizedBox(height: MediaQuery.of(context).padding.bottom + CxSpace.lg),
              ],
            )
          : Column(
              children: [
                const CxDragHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(CxSpace.xl, 0, CxSpace.xl, CxSpace.md),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Your cart', style: CxText.sheetTitle)),
                      CxChip(
                        label: '${cart.length} item${cart.length > 1 ? 's' : ''}',
                        tone: CxTone.brand,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.md, CxSpace.gutter, CxSpace.md),
                    itemCount: cart.length,
                    separatorBuilder: (_, __) => const SizedBox(height: CxSpace.sm),
                    itemBuilder: (_, i) {
                      final t = cart[i];
                      return Container(
                        padding: const EdgeInsets.fromLTRB(CxSpace.md, CxSpace.md, 4, CxSpace.md),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: CxRadius.lgAll,
                          border: Border.all(color: CxColors.border),
                        ),
                        child: Row(
                          children: [
                            CxIconBadge(
                              icon: t.type == 'package' ? Icons.inventory_2_outlined : Icons.science_outlined,
                              tone: t.type == 'package' ? CxTone.brand : CxTone.info,
                              size: 40,
                            ),
                            const SizedBox(width: CxSpace.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.name, style: CxText.cardTitle),
                                  const SizedBox(height: 2),
                                  Text(t.category, style: CxText.caption),
                                ],
                              ),
                            ),
                            const SizedBox(width: CxSpace.sm),
                            Text('₹${t.finalPrice.toInt()}', style: CxText.price),
                            CxIconButton(
                              icon: Icons.delete_outline_rounded,
                              tooltip: 'Remove ${t.name}',
                              color: CxColors.error,
                              onPressed: () => _remove(t),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  padding: EdgeInsets.fromLTRB(
                      CxSpace.xl, CxSpace.md, CxSpace.xl, MediaQuery.of(context).padding.bottom + CxSpace.lg),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: CxColors.border)),
                  ),
                  child: Column(
                    children: [
                      CxPriceRow(
                        label: 'Total',
                        value: '₹${_total.toInt()}',
                        emphasis: true,
                        valueColor: CxColors.brand,
                      ),
                      const SizedBox(height: CxSpace.sm),
                      CxButton(
                        onPressed: widget.onCheckout,
                        icon: Icons.arrow_forward_rounded,
                        label: 'Proceed to Book  ·  ₹${_total.toInt()}',
                      ),
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

// ─── Sidebar Drawer ───────────────────────────────────────────────────────────

class _AppDrawer extends StatelessWidget {
  final MemberModel member;
  final bool isVip;
  const _AppDrawer({required this.member, required this.isVip});

  @override
  Widget build(BuildContext context) {
    final hasPhoto =
        member.photoBytes != null && member.photoBytes!.isNotEmpty;
    return Drawer(
      backgroundColor: AppColors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              color: AppColors.brandGreen,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 56, height: 56,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.4), width: 1.5),
                    ),
                    child: ClipOval(
                      child: hasPhoto
                          ? Image.memory(member.photoBytes!,
                              fit: BoxFit.cover, width: 56, height: 56)
                          : Center(
                              child: Text(
                                member.name.isNotEmpty
                                    ? member.name[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        member.name,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                      if (isVip) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFB300),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.star_rounded, size: 10, color: Colors.white),
                            SizedBox(width: 3),
                            Text('VIP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
                          ]),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Was '+91 \${member.mobile}' (escaped), which showed the
                  // literal text instead of the number.
                  Text('+91 ${member.mobile}',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withValues(alpha: 0.85))),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _DrawerItem(icon: Icons.group_outlined, label: 'My Customers', onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => CustomerHomeScreen(mobile: member.mobile)));
            }),
            _DrawerItem(icon: Icons.calendar_month_outlined, label: 'My Bookings', onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBookingsScreen()));
            }),
            _DrawerItem(icon: Icons.receipt_long_outlined, label: 'Reports & Results', onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const ReportsScreen()));
            }),
            _DrawerItem(icon: Icons.help_outline_rounded, label: 'Help & Support', onTap: () => Navigator.pop(context)),
            _DrawerItem(icon: Icons.info_outline_rounded, label: 'About Us', onTap: () => Navigator.pop(context)),
            const Spacer(),
            const Divider(height: 1),
            _DrawerItem(icon: Icons.logout_rounded, label: 'Logout', isDestructive: true, onTap: () => Navigator.pop(context)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final bool isDestructive;
  const _DrawerItem({required this.icon, required this.label, required this.onTap, this.isActive = false, this.isDestructive = false});

  @override
  Widget build(BuildContext context) {
    final color = isDestructive ? CxColors.error : isActive ? CxColors.brand : CxColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: CxSpace.sm, vertical: 2),
      child: ListTile(
        leading: Icon(icon, size: 22, color: isDestructive ? CxColors.error : isActive ? CxColors.brand : CxColors.textSecondary),
        title: Text(label, style: TextStyle(fontSize: 15, fontWeight: isActive ? FontWeight.w600 : FontWeight.w500, color: color)),
        tileColor: isActive ? CxColors.brandSurface : null,
        shape: const RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
        contentPadding: const EdgeInsets.symmetric(horizontal: CxSpace.md),
        onTap: onTap,
      ),
    );
  }
}

// ─── Prescription Upload Sheet ────────────────────────────────────────────────

class _PrescriptionUploadSheet extends StatefulWidget {
  final MemberModel member;
  const _PrescriptionUploadSheet({required this.member});

  @override
  State<_PrescriptionUploadSheet> createState() => _PrescriptionUploadSheetState();
}

class _PrescriptionUploadSheetState extends State<_PrescriptionUploadSheet> {
  static const int _maxFiles = 5;
  final List<_PresDoc> _uploads = [];
  bool _isPicking = false;
  bool _isSubmitting = false;
  List<Map<String, dynamic>> _previous = [];
  bool _loadingHistory = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final requests = await ApiService.getMyPrescriptionRequests(patientId: widget.member.id);
    if (!mounted) return;
    setState(() {
      _previous = requests;
      _loadingHistory = false;
    });
  }

  // ── Image picking ─────────────────────────────────────────
  void _showSourcePicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CustomerThemeScope(
        child: CxSheetFrame(
          title: 'Add prescription images',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SourceTile(
                icon: Icons.camera_alt_outlined,
                label: 'Take a photo',
                sub: 'Use camera to capture prescription',
                onTap: () {
                  Navigator.pop(context);
                  _pickFrom(ImageSource.camera);
                },
              ),
              const SizedBox(height: CxSpace.md),
              _SourceTile(
                icon: Icons.photo_library_outlined,
                label: 'Choose from gallery',
                sub: 'Select one or more images',
                onTap: () {
                  Navigator.pop(context);
                  _pickFrom(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickFrom(ImageSource source) async {
    if (_isPicking) return;
    setState(() => _isPicking = true);
    try {
      final picker = ImagePicker();
      if (source == ImageSource.gallery) {
        final files = await picker.pickMultiImage(imageQuality: 85);
        for (final f in files) {
          if (_uploads.length >= _maxFiles) break;
          final bytes = await f.readAsBytes();
          if (!mounted) return;
          setState(() => _uploads.add(_PresDoc(
            bytes: bytes,
            fileName: f.name,
            uploadedAt: DateTime.now(),
          )));
        }
      } else {
        final f = await picker.pickImage(
            source: ImageSource.camera, imageQuality: 85);
        if (f != null && _uploads.length < _maxFiles) {
          final bytes = await f.readAsBytes();
          if (!mounted) return;
          setState(() => _uploads.add(_PresDoc(
            bytes: bytes,
            fileName: f.name,
            uploadedAt: DateTime.now(),
          )));
        }
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  void _viewImage(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            _ImageViewerPage(docs: _uploads, initialIndex: index),
      ),
    );
  }

  void _deleteImage(int index) {
    setState(() => _uploads.removeAt(index));
  }


  Future<void> _submit() async {
    if (_uploads.isEmpty || _isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      // Upload each image and collect URLs
      final filePaths = <String>[];
      for (final doc in _uploads) {
        final url = await ApiService.uploadPhoto(doc.bytes, doc.fileName);
        if (url != null) filePaths.add(url);
      }
      if (filePaths.isEmpty) throw Exception('Upload failed');

      await ApiService.submitPrescriptionRequest(filePaths, patientId: widget.member.id);
      if (!mounted) return;

      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_outline, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(
              '${filePaths.length} prescription image${filePaths.length > 1 ? 's' : ''} submitted. Our team will review and contact you.')),
        ]),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Could not submit. Please try again.'),
        backgroundColor: const Color(0xFFD32F2F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'called':           return const Color(0xFF6A1B9A);
      case 'booking_pending':  return const Color(0xFFF57F17);
      case 'reviewed':         return AppColors.brandGreen;
      case 'converted':        return const Color(0xFF1565C0);
      case 'not_interested':   return const Color(0xFF757575);
      default:                 return const Color(0xFFE65100);
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'called':           return 'Called';
      case 'booking_pending':  return 'Booking Pending';
      case 'reviewed':         return 'Reviewed';
      case 'converted':        return 'Booking Created';
      case 'not_interested':   return 'Not Interested';
      default:                 return 'Pending Review';
    }
  }

  String _formatDate(String iso) {
    try {
      final d = DateTime.parse(iso);
      const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${d.day} ${months[d.month]} ${d.year}';
    } catch (_) { return iso; }
  }

  @override
  Widget build(BuildContext context) {
    final canAddMore = _uploads.length < _maxFiles;

    return CustomerThemeScope(
      child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: CxRadius.sheetTop,
      ),
      constraints: BoxConstraints(
          maxWidth: CxSize.sheetMaxWidth,
          maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(
        children: [
          // ── Handle ──────────────────────────────────────
          const CxDragHandle(),

          // ── Header ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(CxSpace.xl, 0, CxSpace.xl, CxSpace.md),
            child: Row(
              children: [
                const CxIconBadge(icon: Icons.description_outlined, size: 40),
                const SizedBox(width: CxSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Upload Prescription', style: CxText.sheetTitle),
                      Text('For ${widget.member.name}', style: CxText.bodySecondary),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(CxSpace.xl, CxSpace.lg, CxSpace.xl, CxSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Info note ────────────────────────────
                  const CxBanner(
                    tone: CxTone.brand,
                    icon: Icons.info_outline_rounded,
                    message: "Upload your doctor's prescription. You can add up to 5 images. Our technician will review and assign the right tests.",
                  ),

                  const SizedBox(height: CxSpace.lg),

                  // ── Patient chip ─────────────────────────
                  Wrap(spacing: CxSpace.sm, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    CxChip(label: widget.member.name, icon: Icons.person_outline, tone: CxTone.neutral),
                    if (widget.member.relation != null)
                      CxChip(label: widget.member.relation!, tone: CxTone.brand),
                  ]),

                  const SizedBox(height: CxSpace.xl),

                  // ── Upload section header ─────────────────
                  Row(
                    children: [
                      const Text('Prescription Images', style: CxText.label),
                      const Spacer(),
                      if (_uploads.isNotEmpty)
                        Text('${_uploads.length} / $_maxFiles', style: CxText.caption),
                    ],
                  ),
                  const SizedBox(height: CxSpace.md),

                  // ── Image grid ───────────────────────────
                  if (_uploads.isNotEmpty) ...[
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        ..._uploads.asMap().entries.map((e) =>
                            _ThumbnailCard(
                              doc: e.value,
                              onView: () => _viewImage(e.key),
                              onDelete: () => _deleteImage(e.key),
                            )),
                        if (canAddMore)
                          _AddMoreTile(
                            isPicking: _isPicking,
                            onTap: _showSourcePicker,
                          ),
                      ],
                    ),
                  ] else ...[
                    // ── Empty upload drop zone ────────────
                    Material(
                      color: CxColors.brandSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: CxRadius.lgAll,
                        side: BorderSide(color: CxColors.brand.withValues(alpha: 0.35), width: 1.5),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                      onTap: _isPicking ? null : _showSourcePicker,
                      child: Container(
                        width: double.infinity,
                        padding:
                            const EdgeInsets.symmetric(vertical: 32),
                        child: _isPicking
                            ? const Center(
                                child: SizedBox(
                                  width: 28, height: 28,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: AppColors.brandGreen,
                                  ),
                                ),
                              )
                            : const Column(children: [
                                Icon(Icons.add_photo_alternate_outlined,
                                    size: 40, color: AppColors.brandGreen),
                                SizedBox(height: 10),
                                Text('Tap to add prescription images',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.brandGreen)),
                                SizedBox(height: 4),
                                Text('Camera or Gallery · JPG, PNG · max 5MB',
                                    style: CxText.caption),
                              ]),
                      ),
                      ),
                    ),
                  ],

                  // ── Previous prescriptions ───────────────
                  if (_loadingHistory)
                    const CxLoading(label: 'Loading previous uploads…')
                  else if (_previous.isNotEmpty) ...[
                    const SizedBox(height: CxSpace.xxl),
                    const Text('Previous Uploads', style: CxText.label),
                    const SizedBox(height: CxSpace.md),
                    ..._previous.map((p) {
                      final paths  = (p['file_paths'] as List?)?.cast<String>() ?? [];
                      final status = (p['status'] as String?) ?? 'pending';
                      final date   = _formatDate((p['created_at'] as String?) ?? '');
                      final note   = (p['admin_notes'] as String?);
                      final sc     = _statusColor(status);
                      return Container(
                        margin: const EdgeInsets.only(bottom: CxSpace.md),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: CxRadius.lgAll,
                          border: Border.all(color: CxColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Patient name + date
                            Row(children: [
                              const Icon(Icons.person_outline,
                                  size: 16, color: CxColors.textHint),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  (p['patient_name'] as String?) ?? 'Patient',
                                  style: CxText.cardTitle,
                                ),
                              ),
                              const Icon(Icons.calendar_today_outlined,
                                  size: 14, color: CxColors.textHint),
                              const SizedBox(width: 4),
                              Text(date, style: CxText.caption),
                            ]),
                            // Image thumbnails
                            if (paths.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              SizedBox(
                                height: 72,
                                child: ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: paths.length,
                                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                                  itemBuilder: (_, i) => ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      paths[i],
                                      width: 72, height: 72,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                        width: 72, height: 72,
                                        decoration: BoxDecoration(
                                          color: AppColors.background,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: AppColors.divider),
                                        ),
                                        child: const Icon(Icons.broken_image_outlined,
                                            size: 28, color: AppColors.textHint),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: sc.withValues(alpha: 0.1),
                                borderRadius: CxRadius.pill,
                              ),
                              child: Text(_statusLabel(status),
                                  style: TextStyle(fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: sc)),
                            ),
                            if (note != null && note.isNotEmpty) ...[
                              const SizedBox(height: CxSpace.sm),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.check_circle_outline,
                                      size: 16, color: CxColors.brand),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(note, style: CxText.bodySecondary)),
                                ],
                              ),
                            ],
                          ],
                        ),
                      );
                    }),
                  ],

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ── Submit button ────────────────────────────────
          Container(
            padding: EdgeInsets.fromLTRB(
                CxSpace.xl, CxSpace.md, CxSpace.xl, MediaQuery.of(context).padding.bottom + CxSpace.lg),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: CxColors.border)),
            ),
            child: CxButton(
              onPressed: _uploads.isNotEmpty ? _submit : null,
              icon: _uploads.isEmpty ? null : Icons.cloud_upload_outlined,
              label: _uploads.isEmpty
                  ? 'Upload at least 1 image'
                  : 'Submit ${_uploads.length} Image${_uploads.length > 1 ? 's' : ''}',
            ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

// ─── Prescription document model ─────────────────────────────────────────────

class _PresDoc {
  final Uint8List bytes;
  final String fileName;
  final DateTime uploadedAt;
  const _PresDoc(
      {required this.bytes,
      required this.fileName,
      required this.uploadedAt});
}

// ─── Thumbnail card ───────────────────────────────────────────────────────────

class _ThumbnailCard extends StatelessWidget {
  final _PresDoc doc;
  final VoidCallback onView;
  final VoidCallback onDelete;
  const _ThumbnailCard(
      {required this.doc, required this.onView, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onView,
      child: SizedBox(
        width: 96,
        height: 96,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(doc.bytes,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                        width: 96,
                        height: 96,
                        color: AppColors.brandGreenSurface,
                        child: const Icon(Icons.insert_drive_file_outlined,
                            color: AppColors.brandGreen, size: 32),
                      )),
            ),
            // Dark overlay hint
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                    ],
                  ),
                ),
              ),
            ),
            // Delete button (top-right)
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: onDelete,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded,
                      size: 13, color: Colors.white),
                ),
              ),
            ),
            // View icon (bottom-right)
            Positioned(
              bottom: 6,
              right: 6,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.fullscreen_rounded,
                    size: 14, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Add-more tile ────────────────────────────────────────────────────────────

class _AddMoreTile extends StatelessWidget {
  final bool isPicking;
  final VoidCallback onTap;
  const _AddMoreTile({required this.isPicking, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: CxColors.brandSurface,
        shape: RoundedRectangleBorder(
          borderRadius: CxRadius.mdAll,
          side: BorderSide(color: CxColors.brand.withValues(alpha: 0.6), width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
        onTap: isPicking ? null : onTap,
        child: SizedBox(
          width: 96,
          height: 96,
          child: isPicking
              ? const Center(
                  child: SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.brandGreen),
                  ),
                )
              : const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_rounded,
                        size: 28, color: AppColors.brandGreen),
                    SizedBox(height: 4),
                    Text('Add more',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.brandGreen,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
        ),
      );
}

// ─── Source picker tile ───────────────────────────────────────────────────────

class _SourceTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;
  const _SourceTile(
      {required this.icon,
      required this.label,
      required this.sub,
      required this.onTap});

  @override
  // Same look as the shared option card; tap behaviour unchanged.
  Widget build(BuildContext context) => CxOptionCard(
        icon: icon,
        title: label,
        subtitle: sub,
        onTap: onTap,
      );
}

// ─── Full-screen image viewer ─────────────────────────────────────────────────

class _ImageViewerPage extends StatefulWidget {
  final List<_PresDoc> docs;
  final int initialIndex;
  const _ImageViewerPage(
      {required this.docs, required this.initialIndex});

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
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
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.docs.length > 1
              ? 'Photo ${_current + 1} of ${widget.docs.length}'
              : 'Photo',
          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
        ),
      ),
      body: PageView.builder(
        controller: _pageCtrl,
        itemCount: widget.docs.length,
        onPageChanged: (i) => setState(() => _current = i),
        itemBuilder: (_, i) => InteractiveViewer(
          minScale: 0.8,
          maxScale: 5.0,
          child: Center(
            child: Image.memory(
              widget.docs[i].bytes, 
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_outlined,
                        color: Colors.white38, size: 48),
                    SizedBox(height: 8),
                    Text('Unable to preview',
                        style: TextStyle(color: Colors.white38)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      // Page indicator dots
      bottomNavigationBar: widget.docs.length > 1
          ? Container(
              color: Colors.black,
              padding: EdgeInsets.fromLTRB(
                  16, 10, 16, MediaQuery.of(context).padding.bottom + 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.docs.length,
                  (i) => AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: _current == i ? 20 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: _current == i
                          ? AppColors.brandGreen
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

// ─── Active Ride Banner ───────────────────────────────────────────────────────

class _ActiveRideBanner extends StatelessWidget {
  final ActiveRideInfo ride;
  final VoidCallback onTrack;
  const _ActiveRideBanner({required this.ride, required this.onTrack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTrack,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0A3D2D),
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.local_taxi_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Active Ride',
                        style: TextStyle(
                          color: AppColors.brandGreen,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ride.driverName.isNotEmpty
                            ? 'Driver: ${ride.driverName}'
                            : 'Driver en route',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        ride.hospital,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Track',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Active Lab Booking Banner ────────────────────────────────────────────────

class _ActiveLabBanner extends StatelessWidget {
  final ActiveLabBookingInfo lab;
  final VoidCallback onTrack;
  const _ActiveLabBanner({required this.lab, required this.onTrack});

  @override
  Widget build(BuildContext context) {
    final statusText = lab.collected
        ? 'Sample collected — processing at lab'
        : lab.arrived
            ? 'Technician has arrived!'
            : lab.enRoute
                ? 'Technician en route to you'
                : 'Finding technician…';
    final statusColor = lab.collected
        ? const Color(0xFF6A1B9A)
        : lab.arrived
            ? AppColors.brandGreen
            : lab.enRoute
                ? const Color(0xFF1565C0)
                : AppColors.brandGreen;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTrack,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0A3D2D),
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 12, offset: Offset(0, 4)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.science_rounded, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor == AppColors.brandGreen
                              ? AppColors.brandGreen
                              : Colors.lightBlueAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        lab.technicianName.isNotEmpty
                            ? 'Technician: ${lab.technicianName}'
                            : 'Lab Collection',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        lab.patientAddress,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Track',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
