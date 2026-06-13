import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models.dart';
import 'customer_dashboard_screen.dart';

class OffersScreen extends StatefulWidget {
  final MemberModel member;
  const OffersScreen({super.key, required this.member});

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends State<OffersScreen> {
  String _selectedTab = 'All';
  final List<String> _tabs = ['All', 'Tests', 'Packages'];

  // Track items added to cart from this screen
  final List<TestModel> _cart = [];

  // Mock offers — replace with GET /api/offers
  final List<TestModel> _offers = [
    TestModel.fromJson({'id': '1', 'name': 'HbA1c', 'type': 'single', 'category': 'Diabetes', 'description': '3-month average blood sugar control indicator', 'offer': 'yes', 'original_price': '600', 'offer_pct': '10', 'final_price': '540', 'doc_req': 'no', 'start_date': '28-04-2026', 'end_date': '30-05-2026', 'report_sts': '48 hrs'}),
    TestModel.fromJson({'id': '3', 'name': 'Thyroid Profile (T3, T4, TSH)', 'type': 'single', 'category': 'Thyroid', 'description': 'Complete thyroid function evaluation', 'offer': 'yes', 'original_price': '900', 'offer_pct': '15', 'final_price': '765', 'doc_req': 'no', 'start_date': '01-05-2026', 'end_date': '31-05-2026', 'report_sts': '24 hrs'}),
    TestModel.fromJson({'id': '5', 'name': 'Diabetes Care Package', 'type': 'package', 'category': 'Diabetes', 'description': 'HbA1c + Fasting glucose + Insulin + Lipid Profile', 'offer': 'yes', 'original_price': '1800', 'offer_pct': '20', 'final_price': '1440', 'doc_req': 'no', 'start_date': '01-05-2026', 'end_date': '31-05-2026', 'report_sts': '48 hrs'}),
    TestModel.fromJson({'id': '6', 'name': 'Full Body Checkup', 'type': 'package', 'category': 'General', 'description': '60+ parameters — CBC, liver, kidney, thyroid, vitamins & more', 'offer': 'yes', 'original_price': '3500', 'offer_pct': '25', 'final_price': '2625', 'doc_req': 'yes', 'start_date': '01-05-2026', 'end_date': '31-05-2026', 'report_sts': '72 hrs'}),
    TestModel.fromJson({'id': '9', 'name': 'Heart Health Package', 'type': 'package', 'category': 'Heart', 'description': 'Lipid profile + ECG + Cardiac enzymes', 'offer': 'yes', 'original_price': '2200', 'offer_pct': '18', 'final_price': '1804', 'doc_req': 'no', 'start_date': '01-05-2026', 'end_date': '15-05-2026', 'report_sts': '48 hrs'}),
    TestModel.fromJson({'id': '10', 'name': "Women's Wellness Panel", 'type': 'package', 'category': 'Wellness', 'description': 'CBC + Thyroid + Iron + Vitamin D + B12 + Calcium', 'offer': 'yes', 'original_price': '2800', 'offer_pct': '22', 'final_price': '2184', 'doc_req': 'no', 'start_date': '01-05-2026', 'end_date': '31-05-2026', 'report_sts': '48 hrs'}),
  ];

  List<TestModel> get _filtered {
    if (_selectedTab == 'Tests') return _offers.where((o) => o.type == 'single').toList();
    if (_selectedTab == 'Packages') return _offers.where((o) => o.type == 'package').toList();
    return _offers;
  }

  bool _inCart(TestModel t) => _cart.any((c) => c.id == t.id);

  void _toggleCart(TestModel t) {
    setState(() {
      if (_inCart(t)) {
        _cart.removeWhere((c) => c.id == t.id);
      } else {
        _cart.add(t);
      }
    });
  }

  void _proceedToBook() {
    if (_cart.isEmpty) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => CustomerDashboardScreen(
          member: widget.member,
          initialCartTests: List.from(_cart),
        ),
      ),
    );
  }

  int _daysLeft(String? endDate) {
    if (endDate == null) return 0;
    try {
      final parts = endDate.split('-');
      final end = DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
      return end.difference(DateTime.now()).inDays;
    } catch (_) { return 0; }
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
        title: const Text('Offers & Packages',
            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          // Cart count badge
          if (_cart.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: _proceedToBook,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.shopping_cart_outlined,
                          size: 16, color: AppColors.brandGreen),
                      const SizedBox(width: 4),
                      Text('${_cart.length} added',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.brandGreen)),
                    ],
                  ),
                ),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            color: AppColors.brandGreen,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: _tabs.map((tab) {
                final sel = _selectedTab == tab;
                return GestureDetector(
                  onTap: () => setState(() => _selectedTab = tab),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: sel ? Colors.white : Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(tab,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: sel ? AppColors.brandGreen : Colors.white)),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ),

      body: _filtered.isEmpty
          ? const Center(
              child: Text('No offers available',
                  style: TextStyle(fontSize: 14, color: AppColors.textSecondary)))
          : ListView.builder(
              padding: EdgeInsets.fromLTRB(16, 16, 16, _cart.isNotEmpty ? 100 : 32),
              itemCount: _filtered.length,
              itemBuilder: (_, i) => _OfferCard(
                test: _filtered[i],
                daysLeft: _daysLeft(_filtered[i].endDate),
                inCart: _inCart(_filtered[i]),
                onToggleCart: () => _toggleCart(_filtered[i]),
              ),
            ),

      // Proceed FAB - only when items selected
      floatingActionButton: _cart.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _proceedToBook,
              backgroundColor: AppColors.brandGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.shopping_cart_checkout_outlined, size: 20),
              label: Text(
                '${_cart.length} item${_cart.length > 1 ? 's' : ''} · Book Now',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ),
    );
  }
}

// ─── Offer Card ───────────────────────────────────────────────────────────────

class _OfferCard extends StatelessWidget {
  final TestModel test;
  final int daysLeft;
  final bool inCart;
  final VoidCallback onToggleCart;
  const _OfferCard({
    required this.test,
    required this.daysLeft,
    required this.inCart,
    required this.onToggleCart,
  });

  Color get _urgencyColor {
    if (daysLeft <= 3) return const Color(0xFFD32F2F);
    if (daysLeft <= 7) return const Color(0xFFE65100);
    return AppColors.brandGreen;
  }

  @override
  Widget build(BuildContext context) {
    final saving = test.originalPrice - test.finalPrice;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: inCart ? AppColors.brandGreen : AppColors.divider,
          width: inCart ? 1.5 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Column(
          children: [
            // Offer banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFFE65100).withOpacity(0.10),
                    const Color(0xFFFFCC02).withOpacity(0.07),
                  ],
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_offer_rounded, size: 14, color: Color(0xFFE65100)),
                  const SizedBox(width: 6),
                  Text(
                    '${(test.offerPercent ?? 0).toInt()}% OFF  •  Save ₹${saving.toInt()}',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFE65100)),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _urgencyColor.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _urgencyColor.withOpacity(0.3)),
                    ),
                    child: Text(
                      daysLeft <= 0 ? 'Expired' : '$daysLeft days left',
                      style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700, color: _urgencyColor),
                    ),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(14),
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
                            Row(children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: test.type == 'package'
                                      ? AppColors.brandGreenSurface
                                      : const Color(0xFFEEF4FB),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  test.type == 'package' ? 'Package' : 'Test',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: test.type == 'package'
                                          ? AppColors.brandGreen
                                          : const Color(0xFF1565C0)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(test.category,
                                    style: const TextStyle(
                                        fontSize: 11, color: AppColors.textSecondary),
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ]),
                            const SizedBox(height: 6),
                            Text(test.name,
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary)),
                            const SizedBox(height: 4),
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
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('₹${test.finalPrice.toInt()}',
                              style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textPrimary)),
                          Text('₹${test.originalPrice.toInt()}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textHint,
                                  decoration: TextDecoration.lineThrough)),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      _Meta(Icons.schedule_outlined, test.reportStatus),
                      if (test.docRequired)
                        _Meta(Icons.description_outlined, 'Rx needed',
                            color: const Color(0xFFE65100)),
                    ],
                  ),

                  if (test.endDate != null) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.event_outlined, size: 11, color: AppColors.textHint),
                      const SizedBox(width: 4),
                      Text(
                        'Offer ends ${test.endDate}',
                        style: TextStyle(
                            fontSize: 11,
                            color: _urgencyColor,
                            fontWeight: daysLeft <= 7 ? FontWeight.w600 : FontWeight.w400),
                      ),
                    ]),
                  ],

                  const SizedBox(height: 12),

                  // Add to cart / Remove button
                  SizedBox(
                    width: double.infinity,
                    child: inCart
                        ? OutlinedButton.icon(
                            onPressed: onToggleCart,
                            icon: const Icon(Icons.check_circle_outline, size: 18),
                            label: const Text('Added · Tap to remove'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.brandGreen,
                              side: const BorderSide(
                                  color: AppColors.brandGreen, width: 1.5),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          )
                        : ElevatedButton.icon(
                            onPressed: onToggleCart,
                            icon: const Icon(Icons.add_shopping_cart_outlined, size: 18),
                            label: const Text('Add to Cart'),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  const _Meta(this.icon, this.label, {this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: c),
      const SizedBox(width: 3),
      Text(label, style: TextStyle(fontSize: 11, color: c)),
    ]);
  }
}
