import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/utils/app_messages.dart';
import 'package:microlab/widgets/tech/tech_widgets.dart';
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

  // Branches this technician works at ({branchId, name, isDefault}), and per
  // day the branches each selected slot is offered at. One slot can be offered
  // at several branches — the first booking takes it for all of them. Only
  // shown when the technician has more than one branch.
  List<Map<String, dynamic>> _branches = [];
  final Map<String, Map<int, List<int>>> _selectedBranches = {};
  final Map<String, Map<int, List<int>>> _savedBranches    = {};

  bool get _multiBranch => _branches.length > 1;

  int? get _defaultBranchId {
    if (_branches.isEmpty) return null;
    final def = _branches.firstWhere((b) => b['isDefault'] == true, orElse: () => _branches.first);
    return (def['branchId'] as num?)?.toInt();
  }

  List<int> get _defaultBranches => _defaultBranchId != null ? [_defaultBranchId!] : <int>[];

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
      _selectedBranches[_key(d)]  = <int, List<int>>{};
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
      final branchRaw = body['branches']    as List<dynamic>? ?? [];

      // Deduplicate by slot_id — guards against duplicate rows in ip_slots table.
      final seenIds = <int>{};
      final master = masterRaw
          .map((e) => e as Map<String, dynamic>)
          .where((s) => seenIds.add(s['slot_id'] as int))
          .toList();

      // Pre-select slots and durations that match our 3 days
      final Map<String, Set<int>>       preSelected  = { for (final d in _days) _key(d): <int>{} };
      final Map<String, Map<int, int?>> preDurations = { for (final d in _days) _key(d): <int, int?>{} };
      final Map<String, Map<int, List<int>>> preBranches = { for (final d in _days) _key(d): <int, List<int>>{} };

      for (final ts in techRaw) {
        final dateStr = (ts['slot_date'] as String).substring(0, 10);
        final slotId  = ts['slot_id'] as int;
        final avail   = (ts['is_available'] as int?) ?? 1;
        final dur     = ts['duration_minutes'] as int?;
        if (avail == 1 && preSelected.containsKey(dateStr)) {
          preSelected[dateStr]!.add(slotId);
          preDurations[dateStr]![slotId] = dur;
          preBranches[dateStr]![slotId] = (ts['branch_ids'] as List<dynamic>? ?? [])
              .map((b) => (b as num).toInt()).toList();
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
        _branches    = branchRaw.map((b) => b as Map<String, dynamic>).toList();
        _selectedSlots.clear();
        _savedSlots.clear();
        _selectedDurations.clear();
        _savedDurations.clear();
        _selectedBranches.clear();
        _savedBranches.clear();
        for (final d in _days) {
          final k = _key(d);
          _selectedSlots[k]     = Set.from(preSelected[k]  ?? {});
          _savedSlots[k]        = Set.from(preSelected[k]  ?? {});
          _selectedDurations[k] = Map.from(preDurations[k] ?? {});
          _savedDurations[k]    = Map.from(preDurations[k] ?? {});
          _selectedBranches[k]  = { for (final e in (preBranches[k] ?? {}).entries) e.key: List<int>.from(e.value) };
          _savedBranches[k]     = { for (final e in (preBranches[k] ?? {}).entries) e.key: List<int>.from(e.value) };
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
      final token  = prefs.getString('auth_token') ?? '';
      if (techId == 0) { setState(() => _appointmentsLoading = false); return; }

      final res = await ApiService.authClient
          .get(
            Uri.parse('${AppConstants.serverUrl}/api/technicians/$techId/active-bookings'),
            headers: {'Authorization': 'Bearer $token'},
          )
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
          collectionNotes:   map['collection_notes']   as String?,
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
        final curBr = {...(_selectedBranches[k]?[slotId] ?? const <int>[])};
        final savBr = {...(_savedBranches[k]?[slotId] ?? const <int>[])};
        if (curBr.length != savBr.length || !curBr.containsAll(savBr)) return true;
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
        _selectedBranches[k]?.remove(slotId);
      } else {
        s.add(slotId);
        // Offered at the default branch until the technician picks others.
        _selectedBranches[k]![slotId] = List<int>.from(_defaultBranches);
      }
    });
  }

  void _selectAll(String k) => setState(() {
        _selectedSlots[k] = {
          for (final s in _masterSlots)
            if (!_isPast(k, s)) s['slot_id'] as int,
        };
        for (final slotId in _selectedSlots[k]!) {
          _selectedBranches[k]!.putIfAbsent(slotId, () => List<int>.from(_defaultBranches));
        }
      });

  void _clearAll(String k) => setState(() {
        _selectedSlots[k] = {};
        _selectedDurations[k] = {};
        _selectedBranches[k] = {};
      });

  // Ticks / unticks a branch for one slot on one day. The last branch can't
  // be unticked — a slot is always offered somewhere.
  void _toggleBranch(String k, int slotId, int branchId) {
    final list = _selectedBranches[k]!.putIfAbsent(slotId, () => List<int>.from(_defaultBranches));
    if (list.contains(branchId)) {
      if (list.length == 1) return;
      setState(() => list.remove(branchId));
    } else {
      setState(() => list.add(branchId));
    }
  }

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

  // Every selected slot needs an appointment duration: without one the slot
  // has no bookable times, so customers could never book it. Save stays
  // disabled while this lists anything ("Today – 2:00–4:00 PM", …).
  List<String> get _missingDurations {
    final missing = <String>[];
    for (final d in _days) {
      final k = _key(d);
      for (final slotId in (_selectedSlots[k] ?? <int>{})) {
        if (_selectedDurations[k]?[slotId] != null) continue;
        final slot = _masterSlots.firstWhere((s) => s['slot_id'] == slotId,
            orElse: () => {'slot_label': 'Slot $slotId'});
        missing.add('${_dayLabel(d)} – ${slot['slot_label']}');
      }
    }
    return missing;
  }

  Future<void> _save() async {
    if (_missingDurations.isNotEmpty) return; // the button is disabled then too
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
        // Branches per slot — only when there is a choice; otherwise the
        // server uses the technician's own branch.
        final branchMap = <String, List<int>>{
          if (_multiBranch)
            for (final slotId in (_selectedSlots[k] ?? {}))
              slotId.toString(): _selectedBranches[k]?[slotId] ?? _defaultBranches,
        };
        return {
          'date':     k,
          'slot_ids': (_selectedSlots[k] ?? {}).toList(),
          if (durMap.isNotEmpty) 'durations': durMap,
          if (branchMap.isNotEmpty) 'branches': branchMap,
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
          _savedBranches.clear();
          for (final d in _days) {
            final k = _key(d);
            _savedSlots[k]     = Set.from(_selectedSlots[k]     ?? {});
            _savedDurations[k] = Map.from(_selectedDurations[k] ?? {});
            _savedBranches[k]  = {
              for (final e in (_selectedBranches[k] ?? {}).entries) e.key: List<int>.from(e.value)
            };
          }
        });
        AppMessages.success(context, 'Availability saved — patients can now book your slots',
            duration: const Duration(seconds: 3));
      } else {
        AppMessages.error(context, 'Failed to save. Try again.');
      }
    } catch (_) {
      if (mounted) {
        AppMessages.error(context, 'Connection failed. Check internet.');
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
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
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
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
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
                fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
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
                          // Name exactly as saved in ip_slots — it already
                          // carries the timing, so none is added here.
                          slotLabel,
                          style: TextStyle(
                            fontSize: 13,
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
            'Set how long each appointment takes — required for every selected slot',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          ...selected.map((slotId) {
            final slot  = _masterSlots.firstWhere((s) => s['slot_id'] == slotId,
                orElse: () => {'slot_label': 'Slot $slotId'});
            final label = slot['slot_label'] as String;
            final curDur = _selectedDurations[k]?[slotId];
            final durationMissing = curDur == null;

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: durationMissing ? const Color(0xFFFFF5F5) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: durationMissing ? const Color(0xFFD32F2F) : AppColors.divider),
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
                if (durationMissing) ...[
                  const SizedBox(height: 6),
                  const Text('Please choose a duration',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFD32F2F))),
                ],
                if (_multiBranch) ...[
                  const SizedBox(height: 10),
                  const Text('Offer this slot at',
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _branches.map((b) {
                      final branchId = (b['branchId'] as num).toInt();
                      final on = (_selectedBranches[k]?[slotId] ?? _defaultBranches).contains(branchId);
                      return GestureDetector(
                        onTap: () => _toggleBranch(k, slotId, branchId),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: on ? AppColors.brandGreenSurface : const Color(0xFFF5F5F5),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: on ? AppColors.brandGreen : AppColors.divider),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(on ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                size: 14, color: on ? AppColors.brandGreen : AppColors.textHint),
                            const SizedBox(width: 4),
                            Text(b['name'] as String? ?? 'Branch',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: on ? AppColors.brandGreen : AppColors.textSecondary)),
                          ]),
                        ),
                      );
                    }).toList(),
                  ),
                ],
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
          const TechBanner(
            tone: TechTone.warning,
            message: 'No slots selected — you will be unavailable this day.',
          ),
        ],
      ]),
    );
  }

  // ── Save button ────────────────────────────────────────────────────────────

  Widget _buildSaveButton({required double bottomPadding}) {
    final hasChanges = _hasChanges;
    final total      = _totalSlots;
    final missing    = _missingDurations;
    return Container(
      padding: EdgeInsets.fromLTRB(TechSpace.lg, TechSpace.md, TechSpace.lg, bottomPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: TechColors.border)),
        boxShadow: [BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, -4))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Why Save is disabled: the selected slots still without a duration.
        if (hasChanges && missing.isNotEmpty) ...[
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline_rounded, size: 16, color: TechColors.warning),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Duration needed: ${missing.join(', ')}',
                style: const TextStyle(fontSize: 13, color: TechColors.warning, height: 1.35),
              ),
            ),
          ]),
          const SizedBox(height: 8),
        ],
        TechButton(
          onPressed: (!hasChanges || _isSaving || missing.isNotEmpty) ? null : _save,
          loading: _isSaving,
          icon: hasChanges
              ? Icons.check_rounded
              : Icons.check_circle_outline_rounded,
          label: !hasChanges
              ? 'All Changes Saved'
              : missing.isNotEmpty
                  ? 'Choose a duration  •  ${missing.length} slot${missing.length != 1 ? 's' : ''}'
                  : 'Save Availability  •  $total slot${total != 1 ? 's' : ''}',
        ),
      ]),
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
      body = const TechLoadingState(label: 'Loading your slots…');
    } else if (_masterSlots.isEmpty) {
      body = const TechEmptyState(
        icon: Icons.schedule_rounded,
        title: 'No slots configured yet.',
        message: 'Ask your admin to set up time slots.',
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
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
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

    return TechThemeScope(
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 20),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('My Availability',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        actions: [
          if (!_slotsLoading) ...[
            IconButton(
              onPressed: _loadSlots,
              tooltip: 'Reload slots',
              icon: const Icon(Icons.refresh_rounded,
                  color: Colors.white70, size: 22),
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
      ),
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
    return Material(
      color: TechColors.brandSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: TechRadius.lgAll,
        side: BorderSide(color: AppColors.brandGreenLight),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
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
                      fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
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
          const Icon(Icons.chevron_right_rounded, color: AppColors.brandGreen, size: 22),
        ]),
      ),
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
    final color = destructive ? TechColors.error : TechColors.brand;
    return Material(
      color: destructive ? TechColors.errorSurface : TechColors.brandSurface,
      shape: StadiumBorder(
        side: BorderSide(
          color: destructive
              ? TechColors.error.withValues(alpha: 0.35)
              : AppColors.brandGreenLight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: color)),
          ]),
        ),
      ),
    );
  }
}
