// branch_selection_screen.dart
//
// Step 1 of the branch-based booking flow.
//
// Flow:
//  1. Patient types their pincode OR area/place name.
//  2. Taps "Find Branch" → GET /api/branches/lookup.
//  3. Matched branch is shown in a detail card.
//  4. "Continue to Book" → navigates to CheckoutScreen with branch pre-filled.
//     CheckoutScreen loads real slots from the API when branchId is set.
//
// Existing features are untouched. This screen is only reached via
// the new "Schedule Collection" entry point on the home screen.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/models.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'checkout_screen.dart';

class BranchSelectionScreen extends StatefulWidget {
  final MemberModel      member;
  final List<TestModel>  cart;
  final int              patientId;
  final double?          patientLat;
  final double?          patientLng;

  const BranchSelectionScreen({
    super.key,
    required this.member,
    required this.cart,
    required this.patientId,
    this.patientLat,
    this.patientLng,
  });

  @override
  State<BranchSelectionScreen> createState() => _BranchSelectionScreenState();
}

enum _LookupState { idle, loading, found, notFound, error }

class _BranchSelectionScreenState extends State<BranchSelectionScreen> {
  final _pincodeCtrl = TextEditingController();
  final _placeCtrl   = TextEditingController();
  final _pincodeFocus = FocusNode();
  final _placeFocus   = FocusNode();

  _LookupState _state   = _LookupState.idle;
  BranchModel? _branch;
  String       _errorMsg = '';

  @override
  void dispose() {
    _pincodeCtrl.dispose();
    _placeCtrl.dispose();
    _pincodeFocus.dispose();
    _placeFocus.dispose();
    super.dispose();
  }

  // ── API call ───────────────────────────────────────────────────────────────

  Future<void> _lookup() async {
    final pincode = _pincodeCtrl.text.trim();
    final place   = _placeCtrl.text.trim();

    if (pincode.isEmpty && place.isEmpty) {
      _showSnack('Enter your pincode or area name first');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _state   = _LookupState.loading;
      _branch  = null;
      _errorMsg = '';
    });

    try {
      final params = <String, String>{};
      if (pincode.isNotEmpty) params['pincode'] = pincode;
      if (place.isNotEmpty)   params['place']   = place;

      final uri = Uri.parse('${AppConstants.serverUrl}/api/branches/lookup')
          .replace(queryParameters: params);

      final res = await http.get(uri).timeout(const Duration(seconds: 15));

      if (!mounted) return;

      Map<String, dynamic>? body;
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        // Server returned non-JSON (unexpected HTML error page etc.)
        setState(() {
          _state    = _LookupState.error;
          _errorMsg = 'Server returned an unexpected response (${res.statusCode}).';
        });
        return;
      }

      if (res.statusCode == 200 && body['success'] == true) {
        setState(() {
          _branch = BranchModel.fromJson(
              body!['branch'] as Map<String, dynamic>);
          _state = _LookupState.found;
        });
      } else if (res.statusCode == 404) {
        setState(() {
          _state    = _LookupState.notFound;
          _errorMsg = body!['message'] as String? ??
              'No branch found for this location.';
        });
      } else {
        setState(() {
          _state    = _LookupState.error;
          _errorMsg = body!['message'] as String? ?? 'Something went wrong.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state    = _LookupState.error;
        _errorMsg = 'Could not reach the server. Check your connection.';
      });
    }
  }

  // ── Continue to checkout (slot selection happens there) ───────────────────

  void _continue() {
    if (_branch == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CheckoutScreen(
          member:     widget.member,
          cart:       widget.cart,
          mode:       'Home Collection',
          patientId:  widget.patientId,
          patientLat: widget.patientLat,
          patientLng: widget.patientLng,
          branch:     _branch!,
          branchId:   int.tryParse(_branch!.id),
        ),
      ),
    );
  }

  void _reset() {
    setState(() {
      _state    = _LookupState.idle;
      _branch   = null;
      _errorMsg = '';
    });
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'Find Your Branch',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: AppColors.divider),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── Header info ──────────────────────────────────────────────
              _InfoBanner(
                icon: Icons.location_on_rounded,
                color: AppColors.brandGreen,
                text: 'Enter your pincode or area name to find the nearest '
                    'branch that serves your location.',
              ),

              const SizedBox(height: 24),

              // ── Input card ───────────────────────────────────────────────
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // Pincode field
                    _FieldLabel(
                      'Pincode',
                      Icons.pin_drop_outlined,
                      AppColors.brandGreen,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller:    _pincodeCtrl,
                      focusNode:     _pincodeFocus,
                      keyboardType:  TextInputType.number,
                      maxLength:     6,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      onChanged: (_) {
                        if (_pincodeCtrl.text.isNotEmpty) {
                          _placeCtrl.clear();
                        }
                        if (_state != _LookupState.idle) _reset();
                      },
                      onSubmitted: (_) => _lookup(),
                      decoration: _inputDecoration(
                        hint: 'e.g. 600042',
                        icon: Icons.dialpad_rounded,
                      ),
                    ),

                    const SizedBox(height: 16),

                    // Divider with OR
                    Row(children: [
                      const Expanded(child: Divider(color: AppColors.divider)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('OR',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textHint,
                                fontWeight: FontWeight.w600)),
                      ),
                      const Expanded(child: Divider(color: AppColors.divider)),
                    ]),

                    const SizedBox(height: 16),

                    // Place name field
                    _FieldLabel(
                      'Area / Place Name',
                      Icons.place_outlined,
                      AppColors.blue,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller:  _placeCtrl,
                      focusNode:   _placeFocus,
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) {
                        if (_placeCtrl.text.isNotEmpty) {
                          _pincodeCtrl.clear();
                        }
                        if (_state != _LookupState.idle) _reset();
                      },
                      onSubmitted: (_) => _lookup(),
                      decoration: _inputDecoration(
                        hint: 'e.g. Anna Nagar, Velachery…',
                        icon: Icons.location_city_rounded,
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Find button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _state == _LookupState.loading
                            ? null
                            : _lookup,
                        icon: _state == _LookupState.loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white),
                              )
                            : const Icon(Icons.search_rounded, size: 20),
                        label: Text(
                          _state == _LookupState.loading
                              ? 'Searching…'
                              : 'Find My Branch',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              AppColors.brandGreen.withValues(alpha: 0.4),
                          padding:
                              const EdgeInsets.symmetric(vertical: 15),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // ── Result area ──────────────────────────────────────────────
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve:  Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: switch (_state) {
                  _LookupState.found    => _BranchCard(
                      key:      const ValueKey('found'),
                      branch:   _branch!,
                      onReset:  _reset,
                      onContinue: _continue,
                    ),
                  _LookupState.notFound => _StatusBanner(
                      key:   const ValueKey('notFound'),
                      icon:  Icons.location_off_rounded,
                      color: AppColors.amber,
                      bg:    AppColors.amberSurface,
                      title: 'No Branch Found',
                      body:  _errorMsg,
                      actionLabel: 'Try Different Location',
                      onAction: _reset,
                    ),
                  _LookupState.error    => _StatusBanner(
                      key:   const ValueKey('error'),
                      icon:  Icons.error_outline_rounded,
                      color: const Color(0xFFD32F2F),
                      bg:    const Color(0xFFFEF2F2),
                      title: 'Something Went Wrong',
                      body:  _errorMsg,
                      actionLabel: 'Try Again',
                      onAction: _reset,
                    ),
                  _               => const SizedBox.shrink(
                      key: ValueKey('idle'),
                    ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Input decoration helper ────────────────────────────────────────────────

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
  }) =>
      InputDecoration(
        hintText: hint,
        hintStyle:
            const TextStyle(fontSize: 14, color: AppColors.textHint),
        prefixIcon: Icon(icon, size: 20, color: AppColors.textHint),
        counterText: '',
        contentPadding:
            const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
        filled: true,
        fillColor: AppColors.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: AppColors.brandGreen, width: 2),
        ),
      );
}

// ── Branch result card ─────────────────────────────────────────────────────────

class _BranchCard extends StatelessWidget {
  final BranchModel branch;
  final VoidCallback onReset;
  final VoidCallback onContinue;

  const _BranchCard({
    super.key,
    required this.branch,
    required this.onReset,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // Header row
          Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                color: AppColors.brandGreenSurface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.local_hospital_rounded,
                  color: AppColors.brandGreen, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Branch Found',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.brandGreen,
                          letterSpacing: 0.4)),
                  const SizedBox(height: 2),
                  Text(branch.name,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                ],
              ),
            ),
            GestureDetector(
              onTap: onReset,
              child: const Icon(Icons.close_rounded,
                  size: 20, color: AppColors.textHint),
            ),
          ]),

          const SizedBox(height: 14),
          const Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 14),

          // Details
          if (branch.address.isNotEmpty)
            _DetailRow(
              Icons.location_on_outlined,
              branch.address,
            ),
          if (branch.location != null && branch.location!.isNotEmpty)
            _DetailRow(Icons.map_outlined, branch.location!),
          if (branch.pincode != null && branch.pincode!.isNotEmpty)
            _DetailRow(Icons.pin_drop_outlined, branch.pincode!),
          if (branch.mobileNo != null && branch.mobileNo!.isNotEmpty)
            _DetailRow(Icons.phone_outlined, branch.mobileNo!),

          const SizedBox(height: 18),

          // Success badge
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.brandGreenSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.brandGreenLight),
            ),
            child: const Row(children: [
              Icon(Icons.check_circle_rounded,
                  size: 16, color: AppColors.brandGreen),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'This branch will handle your home collection',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColors.brandGreen,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ]),
          ),

          const SizedBox(height: 16),

          // Continue button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onContinue,
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: const Text(
                'Continue to Book',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared small widgets ───────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      );
}

class _FieldLabel extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  const _FieldLabel(this.label, this.icon, this.color);

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color)),
      ]);
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String   text;
  const _DetailRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: AppColors.textHint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
            ),
          ],
        ),
      );
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   text;
  const _InfoBanner(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.brandGreen,
                      height: 1.4)),
            ),
          ],
        ),
      );
}

class _StatusBanner extends StatelessWidget {
  final IconData     icon;
  final Color        color;
  final Color        bg;
  final String       title;
  final String       body;
  final String       actionLabel;
  final VoidCallback onAction;

  const _StatusBanner({
    super.key,
    required this.icon,
    required this.color,
    required this.bg,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Text(title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ]),
            const SizedBox(height: 8),
            Text(body,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    height: 1.4)),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: onAction,
              child: Text(actionLabel,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color,
                      decoration: TextDecoration.underline,
                      decorationColor: color)),
            ),
          ],
        ),
      );
}
