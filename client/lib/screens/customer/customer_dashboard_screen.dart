import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/constants/app_constants.dart';
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
  const CustomerDashboardScreen({
    super.key,
    required this.member,
    this.initialCartTests = const [],
    this.isVip = false,
    this.embedded = false,
    this.onBack,
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
  final List<String> _modes = ['Home Collection', 'Lab Test'];

  // ── Location fields ───────────────────────────────────────
  String? _address;
  String? _pincode;
  String? _city;
  double? _lat;
  double? _lng;
  BranchModel? _selectedBranch;
  bool _loadingBranches = false;
  int get _patientId => int.parse(widget.member.id);

  // ── Cart ──────────────────────────────────────────────────
  final List<TestModel> _cart = [];
  bool get _isLabTest => _mode == 'Lab Test';

  // ── Tests/Packages ────────────────────────────────────────
  bool _loadingTests = false;
  String _searchQuery = '';
  String _selectedCategory = 'All';
  bool _showOffersOnly = false;

  // Mock tests — replace with GET /api/tests
  List<TestModel> _allTests = [];
  List<TestModel> get _filteredTests {
    var list = _allTests;
    if (_showOffersOnly) {
      list = list.where((t) => t.hasOffer).toList();
    }
    if (_selectedCategory != 'All') {
      list = list.where((t) => t.category.toLowerCase() == _selectedCategory.toLowerCase()).toList();
    }
    if (_searchQuery.isNotEmpty) {
      list = list.where((t) =>
        t.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
        t.category.toLowerCase().contains(_searchQuery.toLowerCase()) ||
        t.description.toLowerCase().contains(_searchQuery.toLowerCase())
      ).toList();
    }
    return list;
  }

  List<String> get _categories {
    final cats = {'All', ..._allTests.map((t) => t.category)};
    return cats.toList();
  }

  @override
  void initState() {
    super.initState();
    _loadData();
    // Pre-add tests from offers/other screens
    if (widget.initialCartTests.isNotEmpty) {
      _cart.addAll(widget.initialCartTests);
    }
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text);
    });
  }

  Future<void> _loadData() async {
    setState(() => _loadingTests = true);
    try {
      final tests = await ApiService.getPackages();
      if (mounted) setState(() { _allTests = tests; _loadingTests = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingTests = false);
    }
  }

  void _toggleCart(TestModel test) {
    setState(() {
      final exists = _cart.any((t) => t.id == test.id);
      if (exists) {
        _cart.removeWhere((t) => t.id == test.id);
      } else {
        _cart.add(test);
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

  void _showLocationSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _LocationSheet(
        mode: _mode,
        modes: _modes,
        selectedBranch: _selectedBranch,
        pincode: _pincode,
        city: _city,
        onModeChanged: (m) => setState(() {
          _mode = m;
          if (m == 'Home Collection') _selectedBranch = null;
          if (m == 'Lab Test') { _pincode = null; _city = null; }
        }),
        onBranchChanged: (b) => setState(() => _selectedBranch = b),
        onPincodeChanged: (p) => setState(() => _pincode = p),
        onCityChanged: (c) => setState(() => _city = c),
        onAddressChanged: (a) => setState(() => _address = a),
        onLatLngChanged: (lat, lng) => setState(() { _lat = lat; _lng = lng; }),
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
        onCheckout: () {
          Navigator.pop(context);
          if (_mode == 'Home Collection') {
            _lookupBranchAndCheckout();
          } else {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CheckoutScreen(
                  member:   widget.member,
                  cart:     List.from(_cart),
                  mode:     _mode,
                  address:  _address,
                  pincode:  _pincode,
                  city:     _city,
                  branch:   _selectedBranch,
                  isVip:    widget.isVip,
                  patientId: _patientId,
                  patientLat: _lat,
                  patientLng: _lng,
                ),
              ),
            ).then((_) => setState(() => _cart.clear()));
          }
        },
      ),
    );
  }

  Future<void> _lookupBranchAndCheckout() async {
    if (_pincode == null && _lat == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please update your address before booking a home collection.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [
          CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen),
          SizedBox(width: 16),
          Text('Finding nearest branch…'),
        ]),
      ),
    );

    final branch = await ApiService.lookupBranch(
      pincode: _pincode,
      place:   _city,
      lat:     _lat,
      lng:     _lng,
    );

    if (!mounted) return;
    Navigator.pop(context); // close loading dialog

    if (branch == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No branch found for your area. Please contact support.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CheckoutScreen(
          member:     widget.member,
          cart:       List.from(_cart),
          mode:       'Home Collection',
          address:    _address,
          pincode:    _pincode,
          city:       _city,
          patientId:  _patientId,
          patientLat: _lat,
          patientLng: _lng,
          branch:     branch,
        ),
      ),
    ).then((_) => setState(() => _cart.clear()));
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
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.brandGreen,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: AppColors.brandGreen.withValues(alpha: 0.30),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.20),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text('${_cart.length}',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_cart.length} item${_cart.length > 1 ? 's' : ''} added',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                Text('₹${_cartTotal.toInt()} total',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.80), fontSize: 11)),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: _showCart,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.brandGreen,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('View Cart',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    // Embedded: floating pill only — no white wrapper, no extra safe area
    if (widget.embedded) return pill;

    // Non-embedded: full-width bottom bar with safe-area padding
    return Container(
      padding: EdgeInsets.fromLTRB(16, 10, 16, bottomPad + 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: pill,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = CustomScrollView(
      controller: _scrollController,
        slivers: [
          // ── App Bar ──────────────────────────────────────
          SliverAppBar(
            pinned: true,
            elevation: 0,
            backgroundColor: AppColors.brandGreen,
            leading: widget.embedded
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 18),
                    onPressed: widget.onBack,
                  )
                : IconButton(
                    icon: const Icon(Icons.menu_rounded, color: Colors.white),
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
                    onPressed: _cart.isEmpty ? null : _showCart,
                  ),
                  if (_cart.isNotEmpty)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(
                          color: Colors.orange,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text('${_cart.length}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700)),
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
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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

          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),

                // ── Trust banner ──────────────────────────
                const _TrustBanner(),

                const SizedBox(height: 16),

                // ── Search + Upload ───────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 46,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.divider),
                          ),
                          child: TextField(
                            controller: _searchController,
                            style: const TextStyle(
                                fontSize: 14, color: AppColors.textPrimary),
                            decoration: const InputDecoration(
                              hintText: 'Search tests & packages…',
                              hintStyle: TextStyle(
                                  fontSize: 14, color: AppColors.textHint),
                              prefixIcon: Icon(Icons.search_rounded,
                                  size: 20, color: AppColors.textHint),
                              border: InputBorder.none,
                              contentPadding:
                                  EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Upload prescription
                      GestureDetector(
                        onTap: _uploadPrescription,
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.divider),
                          ),
                          child: const Icon(Icons.upload_file_outlined,
                              size: 22, color: AppColors.brandGreen),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // ── Filters: Offers toggle + Category chips ───
                SizedBox(
                  height: 34,
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    scrollDirection: Axis.horizontal,
                    children: [
                      // Special Offers chip (always first)
                      GestureDetector(
                        onTap: () => setState(() => _showOffersOnly = !_showOffersOnly),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _showOffersOnly ? const Color(0xFFE65100) : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _showOffersOnly ? const Color(0xFFE65100) : AppColors.divider,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.local_offer_rounded,
                                  size: 12,
                                  color: _showOffersOnly ? Colors.white : const Color(0xFFE65100)),
                              const SizedBox(width: 5),
                              Text('Special Offers',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _showOffersOnly ? Colors.white : const Color(0xFFE65100))),
                            ],
                          ),
                        ),
                      ),
                      // Category chips
                      ..._categories.map((cat) {
                        final selected = _selectedCategory == cat;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedCategory = cat),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: selected ? AppColors.brandGreen : Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: selected ? AppColors.brandGreen : AppColors.divider,
                              ),
                            ),
                            child: Text(cat,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: selected ? Colors.white : AppColors.textSecondary)),
                          ),
                        );
                      }),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // ── Content ───────────────────────────────
                if (_loadingTests)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(
                      child: CircularProgressIndicator(color: AppColors.brandGreen),
                    ),
                  )
                else if (_filteredTests.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40, horizontal: 16),
                    child: Center(
                      child: Text('No tests found',
                          style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                    ),
                  )
                else ...[
                  // Tests — full-width list
                  if (_filteredTests.isNotEmpty) ...[
                    _SectionHeader(
                      title: _searchQuery.isNotEmpty
                          ? '${_filteredTests.length} result${_filteredTests.length == 1 ? "" : "s"}'
                          : 'Tests & Packages',
                    ),
                    const SizedBox(height: 10),
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _filteredTests.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _TestCard(
                        test: _filteredTests[i],
                        inCart: _inCart(_filteredTests[i]),
                        onAdd: () => _toggleCart(_filteredTests[i]),
                        onTap: () => _showTestDetail(_filteredTests[i]),
                      ),
                    ),
                  ],
                ],

                const SizedBox(height: 120),
              ],
            ),
          ),
        ],
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
      return Stack(
        children: [
          body,
          if (_cart.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: bottomPad + 8,
              child: _buildCartBar(context),
            ),
          Positioned(
            left: 0, right: 0,
            bottom: _cart.isNotEmpty ? bottomPad + 78 : bottomPad + 8,
            child: banners,
          ),
        ],
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
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
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isVip) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFB300),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, size: 10, color: Colors.white),
                    SizedBox(width: 3),
                    Text('VIP', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.5)),
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
                color: Colors.white.withOpacity(0.75), fontSize: 11),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withOpacity(0.25)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Icon(
              mode == 'Lab Test'
                  ? Icons.local_hospital_outlined
                  : Icons.home_outlined,
              size: 16,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(mode,
                  style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _locationLabel,
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withOpacity(0.9),
                    fontWeight: FontWeight.w400),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white, size: 18),
          ],
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
  final BranchModel? selectedBranch;
  final String? pincode;
  final String? city;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<BranchModel?> onBranchChanged;
  final ValueChanged<String?> onPincodeChanged;
  final ValueChanged<String?> onCityChanged;
  final ValueChanged<String?> onAddressChanged;
  final void Function(double? lat, double? lng)? onLatLngChanged;

  const _LocationSheet({
    required this.mode,
    required this.modes,
    required this.selectedBranch,
    required this.pincode,
    required this.city,
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

class _LocationSheetState extends State<_LocationSheet> {
  late String _mode;
  BranchModel? _branch;
  final _pincodeCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  bool _locationError = false;
  bool _branchError = false;

  List<BranchModel> _filteredBranches = [];
  bool _loadingBranches = false;
  Timer? _debounceTimer;

  // Pincode auto-detection
  String? _detectedArea;
  bool _detecting = false;
  
  // Manual address mode flag
  bool _isManualMode = false;
  
  // Address from GPS
  String? _gpsAddress;
  double? _gpsLat;
  double? _gpsLng;
  bool _gpsSelected = false;
  
  // Address from manual entry (pincode based)
  String? _manualAddress;
  double? _manualLat;
  double? _manualLng;
  bool _manualSelected = false;
  
  // Pincode geocoding in progress
  bool _isGeocoding = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.mode;
    _branch = widget.selectedBranch;
    _pincodeCtrl.text = widget.pincode ?? '';
    _cityCtrl.text = widget.city ?? '';
    _addressCtrl.text = '';

    _pincodeCtrl.addListener(_scheduleFetch);
    _cityCtrl.addListener(_scheduleFetch);
    _pincodeCtrl.addListener(_onPincodeChanged);

    if (_mode == 'Lab Test') _fetchBranches();
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isGeocoding = true;
      _gpsSelected = false;
      _manualSelected = false;
    });
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission denied. Please enable location access.')),
          );
        }
        setState(() => _isGeocoding = false);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));
      _gpsLat = pos.latitude;
      _gpsLng = pos.longitude;
      final address = await _reverseGeocode(pos.latitude, pos.longitude);
      setState(() { _gpsAddress = address; _gpsSelected = true; _isGeocoding = false; });
    } catch (e) {
      setState(() => _isGeocoding = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to get current location. Please try again.')),
        );
      }
    }
  }

  Future<String> _reverseGeocode(double lat, double lng) async {
    try {
      final apiKey = AppConstants.googleMapsApiKey;
      if (apiKey.isEmpty) return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lng&key=$apiKey',
      );
      final response = await http.get(url).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['status'] == 'OK') {
          final results = data['results'] as List;
          if (results.isNotEmpty) return results[0]['formatted_address'] as String;
        }
      }
    } catch (_) {}
    return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }

  Future<void> _detectLocationFromPincode() async {
    final pincode = _pincodeCtrl.text.trim();
    if (pincode.length != 6) { setState(() => _locationError = true); return; }
    setState(() { _isGeocoding = true; _gpsSelected = false; _manualSelected = false; _locationError = false; });
    try {
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
            final geoRes = await http.get(Uri.parse(
              'https://maps.googleapis.com/maps/api/geocode/json?address=$pincode,India&key=${AppConstants.googleMapsApiKey}',
            )).timeout(const Duration(seconds: 8));
            if (geoRes.statusCode == 200) {
              final geoData = jsonDecode(geoRes.body) as Map<String, dynamic>;
              if (geoData['status'] == 'OK') {
                final results = geoData['results'] as List;
                if (results.isNotEmpty) {
                  final loc = (results[0]['geometry'] as Map)['location'] as Map;
                  _manualLat = (loc['lat'] as num).toDouble();
                  _manualLng = (loc['lng'] as num).toDouble();
                  _manualAddress = '$area, $city, $state - $pincode';
                  setState(() { _manualSelected = true; _isGeocoding = false; });
                  return;
                }
              }
            }
          }
        }
      }
      setState(() { _detectedArea = 'Not found'; _isGeocoding = false; _locationError = true; });
    } catch (_) {
      setState(() { _isGeocoding = false; _locationError = true; });
    }
  }

  void _onPincodeChanged() {
    final pin = _pincodeCtrl.text.trim();
    if (_mode != 'Home Collection') return;
    if (pin.length == 6) {
      _detectLocationFromPincode();
    } else {
      if (_detectedArea != null || _detecting) {
        setState(() { _detectedArea = null; _detecting = false; _manualSelected = false; });
      }
    }
  }

  void _scheduleFetch() {
    if (_mode != 'Lab Test') return;
    _debounceTimer?.cancel();
    setState(() => _branch = null);
    _debounceTimer = Timer(const Duration(milliseconds: 600), _fetchBranches);
  }

  Future<void> _fetchBranches() async {
    final pincode = _pincodeCtrl.text.trim();
    final city = _cityCtrl.text.trim();
    if (mounted) setState(() => _loadingBranches = true);
    try {
      final branches = await ApiService.getBranches(
        pincode: pincode.isEmpty ? null : pincode,
        city: city.isEmpty ? null : city,
      );
      if (mounted) setState(() { _filteredBranches = branches; _loadingBranches = false; });
    } catch (_) {
      if (mounted) setState(() { _filteredBranches = []; _loadingBranches = false; });
    }
  }

  void _apply() {
    if (_mode == 'Home Collection') {
      if (_gpsSelected && _gpsLat != null && _gpsLng != null) {
        // Use GPS location
        widget.onAddressChanged(_gpsAddress);
        widget.onLatLngChanged?.call(_gpsLat, _gpsLng);
        widget.onPincodeChanged(null);
        widget.onCityChanged(null);
      } 
      else if (_manualSelected && _manualLat != null && _manualLng != null) {
        // Use manual pincode-based location
        final address = _addressCtrl.text.trim().isNotEmpty 
            ? _addressCtrl.text.trim() 
            : _manualAddress;
        widget.onAddressChanged(address);
        widget.onLatLngChanged?.call(_manualLat, _manualLng);
        widget.onPincodeChanged(_pincodeCtrl.text.trim());
        widget.onCityChanged(_cityCtrl.text.trim().isEmpty ? null : _cityCtrl.text.trim());
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
    _pincodeCtrl.removeListener(_scheduleFetch);
    _cityCtrl.removeListener(_scheduleFetch);
    _pincodeCtrl.removeListener(_onPincodeChanged);
    _debounceTimer?.cancel();
    _pincodeCtrl.dispose();
    _cityCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottomInset + safeBottom + 20),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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

            const Text('Collection Mode',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 14),

            // Mode selector
            Row(
              children: widget.modes.map((m) {
                final sel = _mode == m;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                        right: m == widget.modes.first ? 8 : 0),
                    child: GestureDetector(
                      onTap: () => setState(() => _mode = m),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        decoration: BoxDecoration(
                          color: sel ? AppColors.brandGreen : AppColors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: sel ? AppColors.brandGreen : AppColors.divider),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              m == 'Home Collection'
                                  ? Icons.home_outlined
                                  : Icons.local_hospital_outlined,
                              size: 22,
                              color: sel ? Colors.white : AppColors.textSecondary,
                            ),
                            const SizedBox(height: 4),
                            Text(m,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: sel ? Colors.white : AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 20),

            if (_mode == 'Home Collection') ...[
              const Text('Select Location Method',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
              const SizedBox(height: 12),
              
              // Option 1: GPS Current Location Button
              GestureDetector(
                onTap: _isGeocoding ? null : _getCurrentLocation,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _gpsSelected ? AppColors.brandGreenSurface : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _gpsSelected ? AppColors.brandGreen : AppColors.divider,
                      width: _gpsSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: AppColors.brandGreenSurface,
                          borderRadius: BorderRadius.circular(12),
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
                                size: 28, color: AppColors.brandGreen),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Use Current Location',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary)),
                            const SizedBox(height: 4),
                            Text(
                              _gpsSelected && _gpsAddress != null
                                  ? _gpsAddress!
                                  : 'Get your real-time location using GPS',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: _gpsSelected ? AppColors.brandGreen : AppColors.textSecondary),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (_gpsSelected)
                        const Icon(Icons.check_circle_rounded,
                            color: AppColors.brandGreen, size: 24),
                    ],
                  ),
                ),
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
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _manualSelected ? AppColors.brandGreenSurface : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _manualSelected ? AppColors.brandGreen : AppColors.divider,
                      width: _manualSelected ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEEF4FB),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.edit_location_rounded,
                                size: 28, color: Color(0xFF1565C0)),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Enter Address Manually',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.textPrimary)),
                                const SizedBox(height: 4),
                                Text(
                                  _manualSelected && _manualAddress != null
                                      ? _manualAddress!
                                      : 'Enter pincode to auto-detect location',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: _manualSelected ? AppColors.brandGreen : AppColors.textSecondary),
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
                        
                        // Full address
                        TextField(
                          controller: _addressCtrl,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: 'House no, Street, Area (optional)',
                            hintStyle: const TextStyle(color: AppColors.textHint),
                            prefixIcon: const Icon(Icons.home_outlined, size: 18, color: AppColors.textHint),
                            filled: true,
                            fillColor: AppColors.background,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        
                        // Pincode (required for manual detection)
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
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
                              flex: 1,
                              child: TextField(
                                controller: _cityCtrl,
                                style: const TextStyle(fontSize: 14),
                                decoration: InputDecoration(
                                  hintText: 'City',
                                  hintStyle: const TextStyle(color: AppColors.textHint),
                                  prefixIcon: const Icon(Icons.location_city_outlined, size: 18, color: AppColors.textHint),
                                  filled: true,
                                  fillColor: AppColors.background,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        
                        // Geocoding indicator
                        if (_isGeocoding && _manualSelected == false) ...[
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
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppColors.brandGreenSurface,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle_outline_rounded, size: 16, color: AppColors.brandGreen),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('Detected: $_detectedArea',
                                      style: const TextStyle(fontSize: 12, color: AppColors.brandGreen)),
                                ),
                              ],
                            ),
                          ),
                        ] else if (_detectedArea == 'Not found') ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3E0),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFFE65100)),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text('Pincode not found — enter city manually',
                                      style: TextStyle(fontSize: 12, color: Color(0xFFE65100))),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
              
              if (_locationError) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF5F5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFFCDD2)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: Color(0xFFD32F2F)),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('Please select a location method or enter valid pincode',
                            style: TextStyle(fontSize: 12, color: Color(0xFFD32F2F))),
                      ),
                    ],
                  ),
                ),
              ],
            ],

            if (_mode == 'Lab Test') ...[
              RichText(
                text: const TextSpan(
                  text: 'Pincode or City',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                  children: [TextSpan(text: '  (to find nearby branches)', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w400))],
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _pincodeCtrl,
                    keyboardType: TextInputType.number,
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
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'City',
                      hintStyle: const TextStyle(color: AppColors.textHint),
                      prefixIcon: const Icon(Icons.location_city_outlined, size: 18, color: AppColors.textHint),
                      filled: true, fillColor: AppColors.background,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.divider)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              RichText(
                text: const TextSpan(
                  text: 'Select Branch',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
                  children: [TextSpan(text: ' *', style: TextStyle(color: Color(0xFFD32F2F)))],
                ),
              ),
              const SizedBox(height: 8),
              if (_loadingBranches)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: const Row(children: [
                    SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                    SizedBox(width: 10),
                    Text('Loading branches…', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                  ]),
                )
              else if (_filteredBranches.isEmpty)
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
                    Text('No branches found for this location', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
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
                    final sub = [
                      if ((b.location ?? '').isNotEmpty) b.location!,
                      if ((b.pincode ?? '').isNotEmpty) b.pincode!,
                    ].join(', ');
                    return DropdownMenuItem(
                      value: b,
                      child: Text(
                        sub.isNotEmpty ? '${b.name} · $sub' : b.name,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (b) => setState(() { _branch = b; _branchError = false; }),
                ),
              if (_branchError) ...[
                const SizedBox(height: 6),
                const Row(children: [
                  Icon(Icons.error_outline, size: 13, color: Color(0xFFD32F2F)),
                  SizedBox(width: 4),
                  Text('Please select a branch', style: TextStyle(fontSize: 12, color: Color(0xFFD32F2F))),
                ]),
              ],
            ],

            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _apply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Apply Location',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: inCart ? AppColors.brandGreen : AppColors.divider,
              width: inCart ? 1.5 : 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  // Type badge
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: test.type == 'package'
                                          ? const Color(0xFFE8F5F1)
                                          : const Color(0xFFEEF4FB),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      test.type == 'package'
                                          ? 'Package'
                                          : 'Test',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                          color: test.type == 'package'
                                              ? AppColors.brandGreen
                                              : const Color(0xFF1565C0)),
                                    ),
                                  ),
                                  if (test.hasOffer) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 7, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFF3E0),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${(test.offerPercent ?? 0).toInt()}% OFF',
                                        style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFFE65100)),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(test.name,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.textPrimary)),
                              const SizedBox(height: 3),
                              Text(test.description,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textSecondary,
                                      height: 1.4),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Price
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text('₹${test.finalPrice.toInt()}',
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary)),
                            if (test.hasOffer)
                              Text('₹${test.originalPrice.toInt()}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textHint,
                                      decoration:
                                          TextDecoration.lineThrough)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Meta row
                    Row(
                      children: [
                        _MetaChip(
                            icon: Icons.schedule_outlined,
                            label: test.reportStatus),
                        const SizedBox(width: 8),
                        _MetaChip(
                            icon: Icons.category_outlined,
                            label: test.category),
                        if (test.docRequired) ...[
                          const SizedBox(width: 8),
                          _MetaChip(
                              icon: Icons.description_outlined,
                              label: 'Rx needed',
                              color: const Color(0xFFE65100)),
                        ],
                      ],
                    ),
                    // Offer validity
                    if (test.hasOffer && test.endDate != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.local_offer_outlined,
                              size: 11, color: Color(0xFFE65100)),
                          const SizedBox(width: 4),
                          Text('Offer valid till ${test.endDate}',
                              style: const TextStyle(
                                  fontSize: 11, color: Color(0xFFE65100))),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Add to cart strip
              Material(
                color: inCart
                    ? AppColors.brandGreenSurface
                    : const Color(0xFFF4F6F8),
                child: InkWell(
                  onTap: onAdd,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          inCart
                              ? Icons.check_circle_outline
                              : Icons.add_circle_outline,
                          size: 15,
                          color: inCart
                              ? AppColors.brandGreen
                              : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          inCart ? 'Added to cart' : 'Add to cart',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: inCart
                                  ? AppColors.brandGreen
                                  : AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  const _MetaChip({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: c),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, color: c)),
      ],
    );
  }
}

// ─── Trust Banner ────────────────────────────────────────────────────────────

class _TrustBanner extends StatelessWidget {
  const _TrustBanner();

  static const _items = [
    (Icons.home_outlined, 'Home Collection'),
    (Icons.verified_outlined, 'NABL Certified'),
    (Icons.schedule_rounded, 'Reports in 24 hrs'),
    (Icons.lock_outline_rounded, '100% Secure'),
    (Icons.medical_services_outlined, 'Doctor Support'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final (icon, label) = _items[i];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.brandGreenSurface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.brandGreenLight),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppColors.brandGreen),
                const SizedBox(width: 6),
                Text(label,
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.brandGreen)),
              ],
            ),
          );
        },
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
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(title,
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary)),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.80),
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
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: test.type == 'package'
                              ? AppColors.brandGreenSurface
                              : const Color(0xFFEEF4FB),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          test.type == 'package' ? 'Package' : 'Test',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: test.type == 'package'
                                  ? AppColors.brandGreen
                                  : const Color(0xFF1565C0)),
                        ),
                      ),
                      if (test.hasOffer) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3E0),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${(test.offerPercent ?? 0).toInt()}% OFF',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFE65100)),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(test.name,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 6),
                  Text(test.description,
                      style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.textSecondary,
                          height: 1.5)),
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 16),
                  _InfoRow('Category', test.category),
                  _InfoRow('Report Status', test.reportStatus),
                  _InfoRow('Prescription',
                      test.docRequired ? 'Required' : 'Not required',
                      highlight: test.docRequired),
                  if (test.docRequired) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFFCC02).withOpacity(0.4)),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded, size: 13, color: Color(0xFFE65100)),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Full payment is available only after a technician verifies your uploaded prescription.',
                              style: TextStyle(fontSize: 11, color: Color(0xFF795548), height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
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
          Padding(
            padding: EdgeInsets.fromLTRB(
                20, 0, 20, MediaQuery.of(context).padding.bottom + 16),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  onToggleCart();
                  Navigator.pop(context);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      inCart ? Colors.red[700] : AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(inCart ? 'Remove from cart' : 'Add to cart',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
              ),
            ),
          ),
        ],
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
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: highlight
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: highlight
                        ? AppColors.brandGreen
                        : AppColors.textPrimary)),
          ),
        ],
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
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75),
      child: cart.isEmpty
          ? Column(
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
                const SizedBox(height: 24),
                const Icon(Icons.shopping_cart_outlined,
                    size: 40, color: AppColors.textHint),
                const SizedBox(height: 12),
                const Text('Cart is empty',
                    style: TextStyle(fontSize: 15, color: AppColors.textSecondary)),
                SizedBox(height: MediaQuery.of(context).padding.bottom + 32),
              ],
            )
          : Column(
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Cart  (${cart.length} item${cart.length > 1 ? 's' : ''})',
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      Text('₹${_total.toInt()}',
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.brandGreen)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: cart.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final t = cart[i];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.divider),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.name,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: AppColors.textPrimary)),
                                  const SizedBox(height: 2),
                                  Text(t.category,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                            Text('₹${t.finalPrice.toInt()}',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary)),
                            const SizedBox(width: 10),
                            GestureDetector(
                              onTap: () => _remove(t),
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF5F5),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFFFFCDD2)),
                                ),
                                child: const Icon(Icons.close_rounded,
                                    size: 16, color: Color(0xFFD32F2F)),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      20, 8, 20, MediaQuery.of(context).padding.bottom + 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: widget.onCheckout,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text('Proceed to Book  ·  ₹${_total.toInt()}',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w500)),
                    ),
                  ),
                ),
              ],
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
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withOpacity(0.4), width: 1.5),
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
                  Text('+91 \${member.mobile}',
                      style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withOpacity(0.8))),
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
    final color = isDestructive ? const Color(0xFFD32F2F) : isActive ? AppColors.brandGreen : AppColors.textSecondary;
    return ListTile(
      leading: Icon(icon, size: 20, color: color),
      title: Text(label, style: TextStyle(fontSize: 14, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400, color: color)),
      tileColor: isActive ? AppColors.brandGreenSurface : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      visualDensity: VisualDensity.compact,
      onTap: onTap,
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

  // Mock previous prescriptions
  final List<Map<String, dynamic>> _previous = [
    {
      'date': '08 May 2026',
      'file': 'prescription_ravi_08may.jpg',
      'status': 'Tests assigned by technician',
      'action': 'Technician assigned CBC + Lipid Profile based on prescription',
    },
    {
      'date': '15 Apr 2026',
      'file': 'prescription_ravi_15apr.jpg',
      'status': 'Reviewed',
      'action': 'Technician called and confirmed HbA1c test',
    },
  ];

  // ── Image picking ─────────────────────────────────────────
  void _showSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2)),
              ),
              _SourceTile(
                icon: Icons.camera_alt_outlined,
                label: 'Take a photo',
                sub: 'Use camera to capture prescription',
                onTap: () {
                  Navigator.pop(context);
                  _pickFrom(ImageSource.camera);
                },
              ),
              const SizedBox(height: 10),
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

  void _callSupport() {
    // TODO: launch('tel:+911800XXXXXX')
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Row(children: [
        Icon(Icons.phone_outlined, color: Colors.white, size: 16),
        SizedBox(width: 8),
        Expanded(child: Text('Calling support…')),
      ]),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _submit() {
    if (_uploads.isEmpty) return;
    Navigator.pop(context);
    // TODO: POST /api/prescriptions with _uploads.map((d) => d.bytes)
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Row(children: [
        const Icon(Icons.check_circle_outline, color: Colors.white, size: 16),
        const SizedBox(width: 8),
        Expanded(
            child: Text(
                '${_uploads.length} prescription image${_uploads.length > 1 ? 's' : ''} submitted. Our technician will review and contact you.')),
      ]),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  Color _statusColor(String s) {
    if (s.contains('assigned') || s.contains('Reviewed')) {
      return AppColors.brandGreen;
    }
    if (s.contains('Pending')) return const Color(0xFFE65100);
    return const Color(0xFF1565C0);
  }

  @override
  Widget build(BuildContext context) {
    final canAddMore = _uploads.length < _maxFiles;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(
        children: [
          // ── Handle ──────────────────────────────────────
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),

          // ── Header ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Upload Prescription',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      Text('For ${widget.member.name}',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _callSupport,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.brandGreenLight),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.support_agent_outlined,
                            size: 16, color: AppColors.brandGreen),
                        SizedBox(width: 6),
                        Text('Support Call',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: AppColors.brandGreen)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Info note ────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.brandGreenLight),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 14, color: AppColors.brandGreen),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            "Upload your doctor's prescription. You can add up to 5 images. Our technician will review and assign the right tests.",
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.brandGreen,
                                height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Patient chip ─────────────────────────
                  Row(children: [
                    const Icon(Icons.person_outline,
                        size: 14, color: AppColors.textHint),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Text(widget.member.name,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary)),
                    ),
                    if (widget.member.relation != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.brandGreenSurface,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(widget.member.relation!,
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppColors.brandGreen,
                                fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ]),

                  const SizedBox(height: 20),

                  // ── Upload section header ─────────────────
                  Row(
                    children: [
                      const Text('Prescription Images',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                      const Spacer(),
                      if (_uploads.isNotEmpty)
                        Text('${_uploads.length} / $_maxFiles',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                  const SizedBox(height: 12),

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
                    GestureDetector(
                      onTap: _isPicking ? null : _showSourcePicker,
                      child: Container(
                        width: double.infinity,
                        padding:
                            const EdgeInsets.symmetric(vertical: 32),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                              color: AppColors.divider, width: 1.5),
                        ),
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
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: AppColors.brandGreen)),
                                SizedBox(height: 4),
                                Text('Camera or Gallery · JPG, PNG · max 5MB',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textHint)),
                              ]),
                      ),
                    ),
                  ],

                  // ── Previous prescriptions ───────────────
                  if (_previous.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text('Previous Uploads',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 10),
                    ..._previous.map((p) => Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.background,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.divider),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                const Icon(
                                    Icons.insert_drive_file_outlined,
                                    size: 16,
                                    color: AppColors.textHint),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(p['file'],
                                      style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: AppColors.textPrimary),
                                      overflow: TextOverflow.ellipsis),
                                ),
                              ]),
                              const SizedBox(height: 6),
                              Row(children: [
                                const Icon(Icons.calendar_today_outlined,
                                    size: 11, color: AppColors.textHint),
                                const SizedBox(width: 4),
                                Text(p['date'],
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.textSecondary)),
                              ]),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: _statusColor(p['status'])
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(p['status'],
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: _statusColor(p['status']))),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.check_circle_outline,
                                      size: 13,
                                      color: AppColors.brandGreen),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(p['action'],
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: AppColors.textSecondary,
                                            height: 1.4)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        )),
                  ],

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),

          // ── Submit button ────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
                16, 8, 16, MediaQuery.of(context).padding.bottom + 16),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _uploads.isNotEmpty ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  disabledBackgroundColor:
                      AppColors.brandGreen.withValues(alpha: 0.35),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                  _uploads.isEmpty
                      ? 'Upload at least 1 image'
                      : 'Submit ${_uploads.length} Image${_uploads.length > 1 ? 's' : ''}',
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
  Widget build(BuildContext context) => GestureDetector(
        onTap: isPicking ? null : onTap,
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: AppColors.brandGreenSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: AppColors.brandGreen, width: 1.5),
          ),
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
                            fontSize: 11,
                            color: AppColors.brandGreen,
                            fontWeight: FontWeight.w500)),
                  ],
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
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreenSurface,
                  shape: BoxShape.circle),
              child: Icon(icon, size: 22, color: AppColors.brandGreen),
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
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: AppColors.textHint, size: 20),
          ]),
        ),
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
