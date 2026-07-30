// slot_selection_screen.dart
//
// Step 2 of the branch-based booking flow (after BranchSelectionScreen).
//
// Flow:
//  1. Patient picks a collection date (today or any future date).
//  2. Available slots are loaded from GET /api/branches/slots?branchId=&date=.
//  3. Patient picks a time slot.
//  4. "Confirm & Proceed" → navigates to CheckoutScreen with branch +
//     collection date + slot pre-filled so the booking API call carries them.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/models.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'checkout_screen.dart';

// ── Slot model (from API response) ────────────────────────────────────────────

class _SlotItem {
  final int    timeSlotId;
  final String label;
  final String time;
  final int    remaining;

  const _SlotItem({
    required this.timeSlotId,
    required this.label,
    required this.time,
    required this.remaining,
  });

  factory _SlotItem.fromJson(Map<String, dynamic> j) => _SlotItem(
        timeSlotId: (j['time_slot_id'] as num).toInt(),
        label:      j['label']     as String? ?? '',
        time:       j['time']      as String? ?? '',
        remaining:  (j['remaining'] as num?)?.toInt() ?? 0,
      );
}

// ── Screen ─────────────────────────────────────────────────────────────────────

class SlotSelectionScreen extends StatefulWidget {
  final MemberModel     member;
  final List<TestModel> cart;
  final int             patientId;
  final double?         patientLat;
  final double?         patientLng;
  final BranchModel     branch;

  const SlotSelectionScreen({
    super.key,
    required this.member,
    required this.cart,
    required this.patientId,
    required this.branch,
    this.patientLat,
    this.patientLng,
  });

  @override
  State<SlotSelectionScreen> createState() => _SlotSelectionScreenState();
}

class _SlotSelectionScreenState extends State<SlotSelectionScreen> {
  DateTime?       _selectedDate;
  _SlotItem?      _selectedSlot;
  List<_SlotItem> _slots        = [];
  bool            _loadingSlots = false;
  String          _slotError    = '';

  // ── Date helpers ───────────────────────────────────────────────────────────

  String _formatDate(DateTime d) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  String _toApiDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  // ── Date picker ────────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final now   = DateTime.now();
    // Normalize to midnight — the picker returns dates at midnight, so firstDate
    // must also be midnight or initialDate (a prior selection) will be "before"
    // firstDate and today gets greyed out on subsequent opens.
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context:     context,
      initialDate: _selectedDate ?? today,
      firstDate:   today,                            // today allowed
      lastDate:    today.add(const Duration(days: 30)),
      helpText:    'SELECT COLLECTION DATE',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary:   AppColors.brandGreen,
            onPrimary: Colors.white,
            surface:   Colors.white,
          ),
        ),
        child: child!,
      ),
    );

    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
        _selectedSlot = null;
        _slots        = [];
        _slotError    = '';
      });
      _loadSlots(picked);
    }
  }

  // ── Load slots from API ────────────────────────────────────────────────────

  Future<void> _loadSlots(DateTime date) async {
    setState(() {
      _loadingSlots = true;
      _slotError    = '';
    });

    try {
      final uri = Uri.parse(
        '${AppConstants.serverUrl}/api/slots',
      ).replace(queryParameters: {
        'branch_id': widget.branch.id,
        'date':      _toApiDate(date),
        'slot_type': 'home_collection',
      });

      final res  = await http.get(uri).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;

      if (!mounted) return;

      if (res.statusCode == 200 && body['success'] == true) {
        final list = (body['slots'] as List)
            .map((s) => _SlotItem.fromJson(s as Map<String, dynamic>))
            .toList();
        setState(() {
          _slots        = list;
          _loadingSlots = false;
          _slotError    = list.isEmpty
              ? 'No slots available for this date. Try another date.'
              : '';
        });
      } else {
        setState(() {
          _loadingSlots = false;
          _slotError    = body['message'] as String? ?? 'Could not load slots.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingSlots = false;
        _slotError    = 'Could not reach the server. Check your connection.';
      });
    }
  }

  // ── Proceed to checkout ────────────────────────────────────────────────────

  void _proceed() {
    if (_selectedDate == null || _selectedSlot == null) return;

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
          branch:     widget.branch,
          // Pass pre-selected date + slot so CheckoutScreen skips its picker
          preSelectedDate: _selectedDate,
          preSelectedSlotLabel: _selectedSlot!.label,
          // New branch booking fields forwarded to POST /api/bookings
          branchId:           int.parse(widget.branch.id),
          collectionDate:     _toApiDate(_selectedDate!),
          timeSlotId:         _selectedSlot!.timeSlotId,
        ),
      ),
    );
  }

  bool get _canProceed => _selectedDate != null && _selectedSlot != null;

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
            'Select Date & Slot',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: AppColors.divider),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    // ── Branch summary chip ──────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.brandGreenLight),
                      ),
                      child: Row(children: [
                        const Icon(Icons.local_hospital_rounded,
                            size: 16, color: AppColors.brandGreen),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.branch.name,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.brandGreen),
                          ),
                        ),
                      ]),
                    ),

                    const SizedBox(height: 20),

                    // ── Date card ────────────────────────────────────────
                    _SectionCard(
                      title: 'Collection Date',
                      icon:  Icons.calendar_today_outlined,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: _pickDate,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 14),
                              decoration: BoxDecoration(
                                color: _selectedDate != null
                                    ? AppColors.brandGreenSurface
                                    : AppColors.background,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _selectedDate != null
                                      ? AppColors.brandGreen
                                      : AppColors.divider,
                                  width: _selectedDate != null ? 1.5 : 1,
                                ),
                              ),
                              child: Row(children: [
                                Icon(
                                  Icons.event_outlined,
                                  size: 20,
                                  color: _selectedDate != null
                                      ? AppColors.brandGreen
                                      : AppColors.textHint,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _selectedDate != null
                                        ? _formatDate(_selectedDate!)
                                        : 'Tap to select date',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: _selectedDate != null
                                          ? FontWeight.w500
                                          : FontWeight.w400,
                                      color: _selectedDate != null
                                          ? AppColors.textPrimary
                                          : AppColors.textHint,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: _selectedDate != null
                                      ? AppColors.brandGreen
                                      : AppColors.textHint,
                                ),
                              ]),
                            ),
                          ),

                          // Same-day notice
                          if (_selectedDate != null && _isToday(_selectedDate!))
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: _InfoChip(
                                icon:  Icons.flash_on_rounded,
                                color: AppColors.amber,
                                bg:    AppColors.amberSurface,
                                text:  'Same-day collection — '
                                    'branch admin will dispatch immediately.',
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── Slots card ───────────────────────────────────────
                    _SectionCard(
                      title: 'Time Slot',
                      icon:  Icons.schedule_outlined,
                      child: _buildSlotsBody(),
                    ),
                  ],
                ),
              ),
            ),

            // ── Bottom bar ───────────────────────────────────────────────
            Container(
              padding: EdgeInsets.fromLTRB(
                  16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
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
                            ? 'Please select a collection date'
                            : 'Please select a time slot',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFD32F2F)),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _canProceed ? _proceed : null,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                      label: const Text(
                        'Confirm & Proceed',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            AppColors.brandGreen.withValues(alpha: 0.35),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
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

  // ── Slots body (loading / error / grid) ───────────────────────────────────

  Widget _buildSlotsBody() {
    if (_selectedDate == null) {
      return const Text(
        'Select a date above to see available slots',
        style: TextStyle(
            fontSize: 13,
            color: AppColors.textHint,
            fontStyle: FontStyle.italic),
      );
    }

    if (_loadingSlots) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: CircularProgressIndicator(
              strokeWidth: 2, color: AppColors.brandGreen),
        ),
      );
    }

    if (_slotError.isNotEmpty) {
      return _InfoChip(
        icon:  Icons.info_outline_rounded,
        color: AppColors.amber,
        bg:    AppColors.amberSurface,
        text:  _slotError,
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _slots.map((slot) {
        final isSelected = _selectedSlot?.timeSlotId == slot.timeSlotId;
        return GestureDetector(
          onTap: () => setState(() => _selectedSlot = slot),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.brandGreen
                  : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected
                    ? AppColors.brandGreen
                    : AppColors.divider,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  slot.label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? Colors.white
                          : AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  '${slot.remaining} left',
                  style: TextStyle(
                      fontSize: 10,
                      color: isSelected
                          ? Colors.white70
                          : AppColors.textHint),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Shared widgets ─────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String  title;
  final IconData icon;
  final Widget  child;
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

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
              Text(title,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary)),
            ]),
            const SizedBox(height: 14),
            child,
          ],
        ),
      );
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final Color    bg;
  final String   text;
  const _InfoChip({
    required this.icon,
    required this.color,
    required this.bg,
    required this.text,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 12, color: color, height: 1.4)),
            ),
          ],
        ),
      );
}
