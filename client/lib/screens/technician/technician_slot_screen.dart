import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models/technician_booking.dart';
import 'technician_booking_detail_screen.dart';

class TechnicianSlotScreen extends StatefulWidget {
  final String mobile;
  final bool embedded;
  const TechnicianSlotScreen(
      {super.key, required this.mobile, this.embedded = false});

  @override
  State<TechnicianSlotScreen> createState() => _TechnicianSlotScreenState();
}

class _TechnicianSlotScreenState extends State<TechnicianSlotScreen> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _masterSlots = [];
  bool _slotsLoading = true;

  // Exactly 3 days: today, tomorrow, day+2
  late final List<DateTime> _days;
  int _selectedDayIndex = 0;

  final Map<String, Set<int>>       _selectedSlots     = {};
  final Map<String, Set<int>>       _savedSlots        = {};
  // slotId → appointment duration in minutes (null = no duration / old flow)
  final Map<String, Map<int, int?>> _selectedDurations = {};
  final Map<String, Map<int, int?>> _savedDurations    = {};

  static const _durationOptions = [15, 30, 40];

  bool _isSaving = false;
  Timer? _slotRefreshTimer;

  // ── Today's appointments (actual assigned bookings, not availability) ──────
  List<TechnicianBooking> _todayAppointments = [];
  bool _appointmentsLoading = true;
  bool _appointmentsExpanded = true;

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _months   = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  static const _dayNames = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

  String _dayLabel(DateTime d) {
    final today    = _days[0];
    final tomorrow = today.add(const Duration(days: 1));
    if (_key(d) == _key(today))    return 'Today';
    if (_key(d) == _key(tomorrow)) return 'Tomorrow';
    return _dayNames[d.weekday - 1];
  }

  int get _totalSlots =>
      _days.fold(0, (s, d) => s + (_selectedSlots[_key(d)]?.length ?? 0));

  // "08:00:00" → "8 AM"; combined into "8 AM – 10 AM" for a slot range.
  String _timeRangeLabel(String? start, String? end) {
    if (start == null || end == null) return '';
    String fmt(String t) {
      final parts = t.split(':');
      if (parts.length < 2) return t;
      final h = int.tryParse(parts[0]) ?? 0;
      final m = parts[1];
      final isPm = h >= 12;
      final h12  = h % 12 == 0 ? 12 : h % 12;
      return m == '00' ? '$h12 ${isPm ? 'PM' : 'AM'}' : '$h12:$m ${isPm ? 'PM' : 'AM'}';
    }
    return '${fmt(start)} – ${fmt(end)}';
  }

  IconData _slotTimeIcon(String? start) {
    final h = int.tryParse((start ?? '').split(':').first) ?? 9;
    if (h < 17) return Icons.wb_sunny_outlined;
    if (h < 20) return Icons.wb_twilight_rounded;
    return Icons.nightlight_round;
  }

  // ── Init ───────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _days = List.generate(3, (i) => today.add(Duration(days: i)));
    for (final d in _days) {
      _selectedSlots[_key(d)]     = <int>{};
      _selectedDurations[_key(d)] = <int, int?>{};
    }
    _loadSlots();
    _loadTodayAppointments();
    WidgetsBinding.instance.addObserver(this);
    // Rebuild every minute so past-slot locks apply without a network call.
    _slotRefreshTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) { if (mounted) setState(() {}); },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadSlots();
      _loadTodayAppointments();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slotRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSlots() async {
    setState(() => _slotsLoading = true);
    try {
      final prefs  = await SharedPreferences.getInstance();
      final techId = prefs.getInt('user_id')      ?? 0;
      final token  = prefs.getString('auth_token') ?? '';

      if (techId == 0) { setState(() => _slotsLoading = false); return; }

      final res = await ApiService.authClient.get(
        Uri.parse('${AppConstants.serverUrl}/api/technicians/$techId/slots'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (res.statusCode != 200) { setState(() => _slotsLoading = false); return; }

      final body      = jsonDecode(res.body) as Map<String, dynamic>;
      final masterRaw = body['masterSlots'] as List<dynamic>? ?? [];
      final techRaw   = body['techSlots']   as List<dynamic>? ?? [];

      // Deduplicate by slot_id — guards against duplicate rows in ip_slots table.
      final seenIds = <int>{};
      final master = masterRaw
          .map((e) => e as Map<String, dynamic>)
          .where((s) => seenIds.add(s['slot_id'] as int))
          .toList();

      // Pre-select slots and durations that match our 3 days
      final Map<String, Set<int>>       preSelected  = { for (final d in _days) _key(d): <int>{} };
      final Map<String, Map<int, int?>> preDurations = { for (final d in _days) _key(d): <int, int?>{} };

      for (final ts in techRaw) {
        final dateStr = (ts['slot_date'] as String).substring(0, 10);
        final slotId  = ts['slot_id'] as int;
        final avail   = (ts['is_available'] as int?) ?? 1;
        final dur     = ts['duration_minutes'] as int?;
        if (avail == 1 && preSelected.containsKey(dateStr)) {
          preSelected[dateStr]!.add(slotId);
          preDurations[dateStr]![slotId] = dur;
        }
      }

      // Remove expired slots from today's preselect — server may have stored
      // them from an earlier session, but they must not appear selected now.
      final todayKey = _key(_days[0]);
      preSelected[todayKey]?.removeWhere((slotId) {
        final slot = master.firstWhere(
          (s) => (s['slot_id'] as int) == slotId,
          orElse: () => <String, dynamic>{},
        );
        return _isPast(todayKey, slot);
      });
      preDurations[todayKey]?.removeWhere(
        (slotId, _) => !(preSelected[todayKey]?.contains(slotId) ?? false),
      );

      setState(() {
        _masterSlots = master;
        _selectedSlots.clear();
        _savedSlots.clear();
        _selectedDurations.clear();
        _savedDurations.clear();
        for (final d in _days) {
          final k = _key(d);
          _selectedSlots[k]     = Set.from(preSelected[k]  ?? {});
          _savedSlots[k]        = Set.from(preSelected[k]  ?? {});
          _selectedDurations[k] = Map.from(preDurations[k] ?? {});
          _savedDurations[k]    = Map.from(preDurations[k] ?? {});
        }
        _slotsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _slotsLoading = false);
    }
  }

  // Reuses the same /active-bookings endpoint the Dashboard tab already
  // calls, filtered down to just today — no new backend functionality.
  Future<void> _loadTodayAppointments() async {
    setState(() => _appointmentsLoading = true);
    try {
      final prefs  = await SharedPreferences.getInstance();
      final techId = prefs.getInt('user_id') ?? 0;
      if (techId == 0) { setState(() => _appointmentsLoading = false); return; }

      final res = await ApiService.authClient
          .get(Uri.parse('${AppConstants.serverUrl}/api/technicians/$techId/active-bookings'))
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (res.statusCode != 200) { setState(() => _appointmentsLoading = false); return; }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final rows = body['data'] as List<dynamic>? ?? [];
      final todayKey = _key(_days[0]);

      final all = rows.map((r) {
        final map = r as Map<String, dynamic>;
        final dateStr = map['collection_date'] as String?;
        final date = dateStr != null
            ? (DateTime.tryParse(dateStr)?.toLocal() ?? DateTime.now())
            : DateTime.now();
        final cs = map['collection_status'] as String? ?? '';
        final status = cs == 'en_route'               ? 'Journey Started'
            : cs == 'arrived'               ? 'Destination Reached'
            : cs == 'collection_started'    ? 'Collection Started'
            : cs == 'collected'             ? 'Sample Collected'
            : cs == 'sample_collected'      ? 'Sample Collected'
            : cs == 'otp_verified'          ? 'OTP Verified'
            : cs == 'handed_to_lab_pending' ? 'Handed to Lab'
            : cs == 'handed_to_lab'         ? 'Handed to Lab'
            : 'Confirmed';
        return TechnicianBooking(
          id:                map['booking_id']?.toString() ?? '',
          bookingRef:        map['booking_ref']        as String?,
          referenceNo:       map['reference_no']       as String?,
          patientId:         int.tryParse(map['patient_id']?.toString() ?? ''),
          customerName:      map['patient_name']       as String? ?? 'Patient',
          customerPhone:     map['patient_mobile']     as String? ?? '',
          address:           map['collection_address'] as String? ?? '',
          city:              map['city']               as String? ?? '',
          pincode:           map['postal_code']        as String? ?? '',
          date:              date,
          timeSlot:          (map['slot_time_formatted'] as String?) ??
                             (map['slot_label']         as String?) ?? '—',
          testNames:         const ['Home Collection'],
          mode:              'Home Collection',
          status:            status,
          docRequired:       map['doc_required'] == 1,
          docVerified:       map['doc_verified'] == 1,
          serviceChargePaid: 0,
          testsTotal:        double.tryParse(map['amount_paid']?.toString() ?? '') ?? 0,
          amountPaid:        double.tryParse(map['booking_amount_paid']?.toString() ?? '') ?? 0.0,
          paymentStatus:     map['payment_status'] as String? ?? 'pending',
          assignedAt:        date,
          visitGroupId:      map['visit_group_id'] as String?,
          patientLat:        double.tryParse(map['patient_lat']?.toString() ?? ''),
          patientLng:        double.tryParse(map['patient_lng']?.toString() ?? ''),
        );
      }).toList();

      setState(() {
        _todayAppointments = all.where((b) => _key(b.date) == todayKey).toList();
        _appointmentsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _appointmentsLoading = false);
    }
  }

  // ── Change detection ───────────────────────────────────────────────────────

  bool get _hasChanges {
    for (final d in _days) {
      final k   = _key(d);
      final cur = _selectedSlots[k] ?? {};
      final sav = _savedSlots[k]    ?? {};
      if (cur.length != sav.length || !cur.containsAll(sav)) return true;
      final curDur = _selectedDurations[k] ?? {};
      final savDur = _savedDurations[k]    ?? {};
      for (final slotId in cur) {
        if (curDur[slotId] != savDur[slotId]) return true;
      }
    }
    return false;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _toggleSlot(String k, int slotId) {
    final slot = _masterSlots.firstWhere(
      (s) => (s['slot_id'] as int) == slotId,
      orElse: () => <String, dynamic>{},
    );
    if (_isPast(k, slot)) return;
    setState(() {
      final s = _selectedSlots[k]!;
      if (s.contains(slotId)) {
        s.remove(slotId);
        _selectedDurations[k]?.remove(slotId);
      } else {
        s.add(slotId);
      }
    });
  }

  void _selectAll(String k) => setState(() =>
      _selectedSlots[k] = {
        for (final s in _masterSlots)
          if (!_isPast(k, s)) s['slot_id'] as int,
      });

  void _clearAll(String k) =>
      setState(() { _selectedSlots[k] = {}; _selectedDurations[k] = {}; });

  // Returns true when [slot] is past for today — its slot_end has been reached.
  // Always false for tomorrow and future dates.
  bool _isPast(String dateKey, Map<String, dynamic> slot) {
    if (dateKey != _key(_days[0])) return false;
    final endStr = slot['slot_end'] as String? ?? '';
    if (endStr.isEmpty) return false;
    final parts = endStr.split(':');
    if (parts.length < 2) return false;
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day,
        int.tryParse(parts[0]) ?? 0, int.tryParse(parts[1]) ?? 0);
    return !now.isBefore(end); // now >= slot_end → locked
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    try {
      final prefs  = await SharedPreferences.getInstance();
      final techId = prefs.getInt('user_id')      ?? 0;
      final token  = prefs.getString('auth_token') ?? '';

      final slotsPayload = _days.map((d) {
        final k      = _key(d);
        final durMap = <String, int>{};
        for (final slotId in (_selectedSlots[k] ?? {})) {
          final dur = _selectedDurations[k]?[slotId];
          if (dur != null) durMap[slotId.toString()] = dur;
        }
        return {
          'date':     k,
          'slot_ids': (_selectedSlots[k] ?? {}).toList(),
          if (durMap.isNotEmpty) 'durations': durMap,
        };
      }).toList();

      final res = await ApiService.authClient.put(
        Uri.parse('${AppConstants.serverUrl}/api/technicians/$techId/slots'),
        headers: {
          'Content-Type':  'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'slots': slotsPayload}),
      ).timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (res.statusCode == 200) {
        setState(() {
          _savedSlots.clear();
          _savedDurations.clear();
          for (final d in _days) {
            final k = _key(d);
            _savedSlots[k]     = Set.from(_selectedSlots[k]     ?? {});
            _savedDurations[k] = Map.from(_selectedDurations[k] ?? {});
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Availability saved — patients can now book your slots'),
          backgroundColor: AppColors.brandGreen,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to save. Try again.'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Connection failed. Check internet.'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── 3-day tab row ──────────────────────────────────────────────────────────

  Widget _buildDayTabs() => Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: List.generate(_days.length, (i) {
            final d      = _days[i];
            final isSel  = _selectedDayIndex == i;
            final k      = _key(d);
            final count  = _selectedSlots[k]?.length ?? 0;
            final hasAny = count > 0;

            return Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _selectedDayIndex = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: EdgeInsets.only(right: i < 2 ? 8 : 0),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: isSel ? AppColors.brandGreen : AppColors.background,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSel ? AppColors.brandGreen : AppColors.divider,
                      width: isSel ? 1.5 : 1,
                    ),
                    boxShadow: isSel
                        ? [BoxShadow(
                            color: AppColors.brandGreen.withValues(alpha: 0.25),
                            blurRadius: 10,
                            offset: const Offset(0, 3))]
                        : null,
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      _dayLabel(d),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isSel ? Colors.white70 : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${d.day} ${_months[d.month]}',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: isSel ? Colors.white : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        color: isSel
                            ? Colors.white.withValues(alpha: 0.2)
                            : (hasAny ? AppColors.brandGreenSurface : const Color(0xFFF5F5F5)),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        hasAny ? '$count slots' : 'Off',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: isSel
                              ? Colors.white
                              : (hasAny ? AppColors.brandGreen : AppColors.textHint),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          }),
        ),
      );

  // ── Today's appointments (actual assigned bookings) ───────────────────────

  Widget _buildTodayAppointments() {
    if (_appointmentsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen),
          ),
        ),
      );
    }
    if (_todayAppointments.isEmpty) return const SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => setState(() => _appointmentsExpanded = !_appointmentsExpanded),
        child: Row(children: [
          const Icon(Icons.access_time_filled_rounded, size: 15, color: AppColors.textPrimary),
          const SizedBox(width: 7),
          const Text("Today's Appointments",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const Spacer(),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 6, height: 6,
              decoration: const BoxDecoration(color: AppColors.brandGreen, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              '${_todayAppointments.length} slot${_todayAppointments.length == 1 ? '' : 's'} available',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
            ),
          ]),
          const SizedBox(width: 2),
          AnimatedRotation(
            turns: _appointmentsExpanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: AppColors.textSecondary),
          ),
        ]),
      ),
      if (_appointmentsExpanded) ...[
        const SizedBox(height: 10),
        ..._todayAppointments.map((apt) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _AppointmentCard(
            booking: apt,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => TechnicianBookingDetailScreen(booking: apt)),
            ),
          ),
        )),
      ],
    ]);
  }

  // ── Slot panel for the selected day ───────────────────────────────────────

  Widget _buildSlotPanel() {
    final d        = _days[_selectedDayIndex];
    final k        = _key(d);
    final selected = _selectedSlots[k] ?? {};
    final allCount  = _masterSlots.length;
    final pastCount = _masterSlots.where((s) => _isPast(k, s)).length;
    final allSel    = allCount > 0 && pastCount < allCount &&
                      selected.length == (allCount - pastCount);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_selectedDayIndex == 0) ...[
          _buildTodayAppointments(),
          const SizedBox(height: 20),
        ],

        // Section header
        Row(children: [
          const Icon(Icons.calendar_today_outlined, size: 15, color: AppColors.textPrimary),
          const SizedBox(width: 7),
          const Text(
            'Other Time Slots',
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          ),
          const Spacer(),
          _QuickButton(
            label: allSel ? 'Clear' : 'All',
            icon: allSel ? Icons.clear_all_rounded : Icons.select_all_rounded,
            onTap: () => allSel ? _clearAll(k) : _selectAll(k),
            destructive: allSel,
          ),
        ]),

        const SizedBox(height: 14),

        if (_masterSlots.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: const Center(
              child: Text('No slots configured by admin yet.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ),
          )
        else
          Column(
            children: _masterSlots.map((slot) {
              final slotId    = slot['slot_id']    as int;
              final slotLabel = slot['slot_label'] as String;
              final start     = slot['slot_start'] as String?;
              final end       = slot['slot_end']   as String?;
              final range     = _timeRangeLabel(start, end);
              final isSel     = selected.contains(slotId);
              final isPast    = _isPast(k, slot);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: isPast ? null : () => _toggleSlot(k, slotId),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: isPast ? const Color(0xFFF5F5F5) : Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isPast
                            ? AppColors.divider
                            : (isSel ? AppColors.brandGreen : AppColors.divider),
                        width: (!isPast && isSel) ? 1.5 : 1,
                      ),
                    ),
                    child: Row(children: [
                      Icon(
                        isPast
                            ? Icons.lock_outline_rounded
                            : (isSel
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded),
                        size: 20,
                        color: isPast
                            ? AppColors.textHint
                            : (isSel ? AppColors.brandGreen : AppColors.textHint),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          range.isNotEmpty ? '$slotLabel ($range)' : slotLabel,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: isPast ? AppColors.textHint : AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Icon(_slotTimeIcon(start),
                          size: 17, color: isPast ? AppColors.textHint : const Color(0xFFF5A623)),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: isPast ? const Color(0xFFF0F0F0) : AppColors.brandGreenSurface,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          isPast ? 'Past' : 'Available',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: isPast ? AppColors.textHint : AppColors.brandGreen,
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            }).toList(),
          ),

        // Duration picker — shown for every selected slot
        if (selected.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            'Appointment Duration',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          const Text(
            'Set how long each appointment takes (optional)',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          ...selected.map((slotId) {
            final slot  = _masterSlots.firstWhere((s) => s['slot_id'] == slotId,
                orElse: () => {'slot_label': 'Slot $slotId'});
            final label = slot['slot_label'] as String;
            final curDur = _selectedDurations[k]?[slotId];

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.divider),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    ..._durationOptions.map((min) => GestureDetector(
                      onTap: () => setState(() => _selectedDurations[k]![slotId] = min),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                        decoration: BoxDecoration(
                          color: curDur == min ? AppColors.brandGreen : const Color(0xFFF5F5F5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: curDur == min ? AppColors.brandGreen : AppColors.divider,
                          ),
                        ),
                        child: Text('$min min',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: curDur == min ? Colors.white : AppColors.textSecondary)),
                      ),
                    )),
                  ],
                ),
              ]),
            );
          }),

          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.brandGreenSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.brandGreenLight),
            ),
            child: Row(children: [
              const Icon(Icons.check_circle_outline_rounded,
                  size: 16, color: AppColors.brandGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${selected.length} of $allCount slots available for ${_dayLabel(d)}',
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.brandGreen,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
        ],

        if (selected.isEmpty && allCount > 0) ...[
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFFE082)),
            ),
            child: const Row(children: [
              Icon(Icons.info_outline_rounded, size: 16, color: Color(0xFFF57F17)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No slots selected — you will be unavailable this day.',
                  style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFFF57F17),
                      fontWeight: FontWeight.w500),
                ),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  // ── Save button ────────────────────────────────────────────────────────────

  Widget _buildSaveButton({required double bottomPadding}) {
    final hasChanges = _hasChanges;
    final total      = _totalSlots;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: AppColors.divider)),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, -4))],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: (!hasChanges || _isSaving) ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.brandGreen,
            disabledBackgroundColor: AppColors.brandGreen.withValues(alpha: 0.35),
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: _isSaving
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
              : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(
                    hasChanges
                        ? Icons.check_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    hasChanges
                        ? 'Save Availability  •  $total slot${total != 1 ? 's' : ''}'
                        : 'All Changes Saved',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                  ),
                ]),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final total = _totalSlots;
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$total slots',
        style: const TextStyle(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );

    Widget body;
    if (_slotsLoading) {
      body = const Center(
        child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen)),
      );
    } else if (_masterSlots.isEmpty) {
      body = const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.schedule_rounded, size: 48, color: AppColors.brandGreenLight),
          SizedBox(height: 14),
          Text('No slots configured yet.',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          SizedBox(height: 6),
          Text('Ask your admin to set up time slots.',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      );
    } else {
      body = Column(children: [
        _buildDayTabs(),
        const Divider(height: 1, color: AppColors.divider),
        Expanded(
          child: ColoredBox(
            color: AppColors.background,
            child: RefreshIndicator(
              onRefresh: () async => Future.wait([_loadSlots(), _loadTodayAppointments()]),
              color: AppColors.brandGreen,
              child: _buildSlotPanel(),
            ),
          ),
        ),
      ]);
    }

    if (widget.embedded) {
      final techName = SocketService.instance.userName.trim();
      final techFirstName = techName.isNotEmpty ? techName.split(RegExp(r'\s+')).first : 'Technician';

      return Column(children: [
        Container(
          color: AppColors.brandGreen,
          padding: EdgeInsets.fromLTRB(
              16, MediaQuery.of(context).padding.top + 14, 16, 14),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.calendar_month_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Schedule',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text('Your upcoming appointments',
                      style: TextStyle(color: Colors.white70, fontSize: 11.5)),
                ],
              ),
            ),
            CircleAvatar(
              radius: 15,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              child: const Icon(Icons.person_rounded, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(techFirstName,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                const Text('Field Service', style: TextStyle(color: Colors.white60, fontSize: 10)),
              ],
            ),
          ]),
        ),
        Expanded(child: body),
        if (!_slotsLoading && _masterSlots.isNotEmpty)
          _buildSaveButton(bottomPadding: 12),
      ]);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('My Availability',
            style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        actions: [
          if (!_slotsLoading) ...[
            GestureDetector(
              onTap: _loadSlots,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(Icons.refresh_rounded,
                    color: Colors.white70, size: 20),
              ),
            ),
            Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Center(child: badge)),
          ],
        ],
      ),
      body: body,
      bottomNavigationBar: (_slotsLoading || _masterSlots.isEmpty)
          ? null
          : _buildSaveButton(
              bottomPadding: MediaQuery.of(context).padding.bottom + 12),
    );
  }
}

// ── Today's appointment card ───────────────────────────────────────────────

class _AppointmentCard extends StatelessWidget {
  final TechnicianBooking booking;
  final VoidCallback onTap;

  const _AppointmentCard({required this.booking, required this.onTap});

  String _partOfDay(DateTime d, String timeSlot) {
    final match = RegExp(r'^(\d{1,2}):').firstMatch(timeSlot);
    int hour = d.hour;
    if (match != null) hour = int.tryParse(match.group(1)!) ?? d.hour;
    final isPm = timeSlot.toUpperCase().contains('PM');
    if (isPm && hour != 12) hour += 12;
    if (!isPm && hour == 12) hour = 0;
    if (hour < 12) return 'Morning';
    if (hour < 16) return 'Afternoon';
    if (hour < 20) return 'Evening';
    return 'Night';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(booking.timeSlot,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.brandGreen)),
              const SizedBox(height: 2),
              Text(_partOfDay(booking.date, booking.timeSlot),
                  style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(booking.customerName,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.location_on_outlined, size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    [booking.address, booking.city, booking.pincode]
                        .where((s) => s.isNotEmpty).join(', '),
                    style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
                child: Text(booking.mode,
                    style: const TextStyle(
                        fontSize: 10.5, color: AppColors.brandGreen, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.brandGreen, size: 20),
        ]),
      ),
    );
  }
}

// ── Quick action button ────────────────────────────────────────────────────

class _QuickButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  const _QuickButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? const Color(0xFFD32F2F) : AppColors.brandGreen;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: destructive
              ? const Color(0xFFFFEBEE)
              : AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: destructive
                ? const Color(0xFFEF9A9A)
                : AppColors.brandGreenLight,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
    );
  }
}
