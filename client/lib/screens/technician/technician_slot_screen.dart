import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';

class TechnicianSlotScreen extends StatefulWidget {
  final String mobile;
  final bool embedded;
  const TechnicianSlotScreen(
      {super.key, required this.mobile, this.embedded = false});

  @override
  State<TechnicianSlotScreen> createState() => _TechnicianSlotScreenState();
}

class _TechnicianSlotScreenState extends State<TechnicianSlotScreen> {
  static const _lookAhead = 30;

  final List<String> _allSlots = [
    '6:00 AM', '7:00 AM', '8:00 AM', '9:00 AM',
    '10:00 AM', '11:00 AM', '12:00 PM',
    '1:00 PM', '2:00 PM', '3:00 PM',
    '4:00 PM', '5:00 PM', '6:00 PM', '7:00 PM',
  ];

  late final List<DateTime> _allDates; // next 30 calendar days
  List<DateTime> _activeDates = [];    // dates the technician configured

  // date key → slot state
  final Map<String, Set<String>> _selectedSlots = {};
  final Map<String, Set<String>> _savedSlots = {};
  final Map<String, String> _fromSlot = {};
  final Map<String, String> _toSlot = {};

  bool _isSaving = false;

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _key(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _months = [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static const _days = [
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'
  ];

  String _fmtLong(DateTime d) =>
      '${_days[d.weekday - 1]}, ${d.day} ${_months[d.month]}';

  bool _isActive(DateTime d) =>
      _activeDates.any((a) => _key(a) == _key(d));

  int get _totalSlots =>
      _activeDates.fold(0, (s, d) => s + (_selectedSlots[_key(d)]?.length ?? 0));

  // ── Init ───────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _allDates = List.generate(_lookAhead, (i) {
      final d = now.add(Duration(days: i + 1));
      return DateTime(d.year, d.month, d.day);
    });

    // Pre-populate 2 days — replace with GET /api/technician/slots
    _activeDates = [_allDates[0], _allDates[1]];
    final presets = [
      {'9:00 AM', '10:00 AM', '11:00 AM', '1:00 PM', '4:00 PM'},
      {'10:00 AM', '11:00 AM', '12:00 PM', '3:00 PM', '5:00 PM'},
    ];
    for (var i = 0; i < _activeDates.length; i++) {
      final k = _key(_activeDates[i]);
      _selectedSlots[k] = presets[i];
      _savedSlots[k] = Set.from(presets[i]);
      _fromSlot[k] = '9:00 AM';
      _toSlot[k] = '5:00 PM';
    }
  }

  // ── Change detection ───────────────────────────────────────────────────────

  bool get _hasChanges {
    final activeKeys = _activeDates.map(_key).toSet();
    final savedKeys = _savedSlots.keys.toSet();
    if (activeKeys.length != savedKeys.length ||
        !activeKeys.containsAll(savedKeys)) {
      return true;
    }
    for (final d in _activeDates) {
      final k = _key(d);
      final cur = _selectedSlots[k] ?? {};
      final sav = _savedSlots[k] ?? {};
      if (cur.length != sav.length || !cur.containsAll(sav)) return true;
    }
    return false;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _addDate(DateTime d) {
    if (_isActive(d)) return;
    final k = _key(d);
    setState(() {
      _activeDates = [..._activeDates, d]..sort((a, b) => a.compareTo(b));
      _selectedSlots[k] = {};
      _fromSlot[k] = '9:00 AM';
      _toSlot[k] = '5:00 PM';
    });
  }

  void _removeDate(DateTime d) {
    final k = _key(d);
    setState(() {
      _activeDates = _activeDates.where((a) => _key(a) != k).toList();
      _selectedSlots.remove(k);
      _fromSlot.remove(k);
      _toSlot.remove(k);
    });
  }

  void _applyRange(String k) {
    final fromIdx = _allSlots.indexOf(_fromSlot[k] ?? '');
    final toIdx = _allSlots.indexOf(_toSlot[k] ?? '');
    if (fromIdx < 0 || toIdx < 0) return;
    final start = fromIdx <= toIdx ? fromIdx : toIdx;
    final end = fromIdx <= toIdx ? toIdx : fromIdx;
    setState(() {
      _selectedSlots[k] = Set.from(_allSlots.sublist(start, end + 1));
    });
  }

  void _toggleSlot(String k, String slot) {
    setState(() {
      final s = _selectedSlots[k]!;
      s.contains(slot) ? s.remove(slot) : s.add(slot);
    });
  }

  Future<void> _save() async {
    setState(() => _isSaving = true);
    // TODO: PUT /api/technician/slots
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      _savedSlots.clear();
      for (final d in _activeDates) {
        final k = _key(d);
        _savedSlots[k] = Set.from(_selectedSlots[k] ?? {});
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Availability saved — customers can now book your slots'),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  // ── Date strip ─────────────────────────────────────────────────────────────

  Widget _buildDateStrip() {
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(children: [
              const Icon(Icons.calendar_month_outlined,
                  size: 13, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              const Text('Select dates',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
              const Spacer(),
              Text('${_activeDates.length} date${_activeDates.length != 1 ? 's' : ''} selected',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textHint)),
            ]),
          ),
          SizedBox(
            height: 70,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.fromLTRB(14, 0, 14, 10),
              itemCount: _allDates.length,
              itemBuilder: (_, i) {
                final d = _allDates[i];
                final active = _isActive(d);
                return GestureDetector(
                  onTap: () =>
                      active ? _removeDate(d) : _addDate(d),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.only(right: 8),
                    width: 50,
                    decoration: BoxDecoration(
                      color: active
                          ? AppColors.brandGreen
                          : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: active
                            ? AppColors.brandGreen
                            : AppColors.divider,
                        width: active ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('${d.day}',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: active
                                    ? Colors.white
                                    : AppColors.textPrimary)),
                        const SizedBox(height: 1),
                        Text(_days[d.weekday - 1],
                            style: TextStyle(
                                fontSize: 9,
                                color: active
                                    ? Colors.white70
                                    : AppColors.textHint)),
                        Text(_months[d.month],
                            style: TextStyle(
                                fontSize: 9,
                                color: active
                                    ? Colors.white70
                                    : AppColors.textHint)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Day card ───────────────────────────────────────────────────────────────

  Widget _buildDayCard(DateTime day) {
    final k = _key(day);
    final selected = _selectedSlots[k] ?? {};
    final from = _fromSlot[k] ?? _allSlots.first;
    final to = _toSlot[k] ?? _allSlots.last;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Card header ──────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
            decoration: const BoxDecoration(
              color: AppColors.brandGreenSurface,
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(children: [
              const Icon(Icons.calendar_today_outlined,
                  size: 14, color: AppColors.brandGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_fmtLong(day),
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.brandGreen)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: selected.isNotEmpty
                      ? AppColors.brandGreen
                      : AppColors.divider,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${selected.length} / ${_allSlots.length}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: selected.isNotEmpty
                          ? Colors.white
                          : AppColors.textHint),
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert,
                    size: 18, color: AppColors.textSecondary),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                onSelected: (v) {
                  if (v == 'all') {
                    setState(() =>
                        _selectedSlots[k] = Set.from(_allSlots));
                  } else if (v == 'clear') {
                    setState(() => _selectedSlots[k] = {});
                  } else if (v == 'remove') {
                    _removeDate(day);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'all', height: 40,
                    child: Row(children: [
                      Icon(Icons.select_all_rounded,
                          size: 16, color: AppColors.brandGreen),
                      SizedBox(width: 8),
                      Text('Select all', style: TextStyle(fontSize: 13)),
                    ]),
                  ),
                  const PopupMenuItem(
                    value: 'clear', height: 40,
                    child: Row(children: [
                      Icon(Icons.clear_all_rounded,
                          size: 16, color: AppColors.textSecondary),
                      SizedBox(width: 8),
                      Text('Clear all', style: TextStyle(fontSize: 13)),
                    ]),
                  ),
                  const PopupMenuItem(
                    value: 'remove', height: 40,
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 16, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Remove date',
                          style: TextStyle(
                              fontSize: 13, color: Colors.red)),
                    ]),
                  ),
                ],
              ),
            ]),
          ),

          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── From / To range ──────────────────────────
                const Row(
                  children: [
                    Icon(Icons.access_time_rounded,
                        size: 14, color: AppColors.textSecondary),
                    SizedBox(width: 6),
                    Text('Available time:',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 10),

                Row(children: [
                  // From dropdown
                  Expanded(
                    child: _SlotDropdown(
                      label: 'From',
                      value: from,
                      slots: _allSlots,
                      onChanged: (v) => setState(() {
                        _fromSlot[k] = v!;
                        _applyRange(k);
                      }),
                    ),
                  ),
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 10),
                    child: Column(children: [
                      Icon(Icons.arrow_forward_rounded,
                          size: 16, color: AppColors.textHint),
                      SizedBox(height: 2),
                      Text('to',
                          style: TextStyle(
                              fontSize: 10,
                              color: AppColors.textHint)),
                    ]),
                  ),
                  // To dropdown
                  Expanded(
                    child: _SlotDropdown(
                      label: 'To',
                      value: to,
                      slots: _allSlots,
                      onChanged: (v) => setState(() {
                        _toSlot[k] = v!;
                        _applyRange(k);
                      }),
                    ),
                  ),
                ]),

                // Range summary chip
                if (selected.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: AppColors.brandGreenLight),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle_outline,
                            size: 12, color: AppColors.brandGreen),
                        const SizedBox(width: 6),
                        Text(
                          '${selected.length} slot${selected.length != 1 ? 's' : ''} set  ·  $from → $to',
                          style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.brandGreen,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 14),
                const Divider(height: 1, color: AppColors.divider),
                const SizedBox(height: 12),

                // ── Fine-tune individual slots ────────────────
                const Row(children: [
                  Icon(Icons.tune_rounded,
                      size: 13, color: AppColors.textHint),
                  SizedBox(width: 5),
                  Text('Fine-tune — tap to toggle:',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textHint)),
                ]),
                const SizedBox(height: 8),

                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: _allSlots.map((slot) {
                    final isSel = selected.contains(slot);
                    return GestureDetector(
                      onTap: () => _toggleSlot(k, slot),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 11, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSel
                              ? AppColors.brandGreen
                              : AppColors.background,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSel
                                ? AppColors.brandGreen
                                : AppColors.divider,
                            width: isSel ? 1.5 : 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (isSel) ...[
                              const Icon(Icons.check_rounded,
                                  size: 11, color: Colors.white),
                              const SizedBox(width: 3),
                            ],
                            Text(slot,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: isSel
                                        ? Colors.white
                                        : AppColors.textSecondary)),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Save button bar ────────────────────────────────────────────────────────

  Widget _buildSaveButton({required double bottomPadding}) {
    final hasChanges = _hasChanges;
    final total = _totalSlots;

    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, bottomPadding),
      decoration: BoxDecoration(
        color: Colors.white,
        border: const Border(top: BorderSide(color: AppColors.divider)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.07),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Horizontal summary scroll
          if (_activeDates.isNotEmpty) ...[
            SizedBox(
              height: 56,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _activeDates.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final d = _activeDates[i];
                  final count =
                      _selectedSlots[_key(d)]?.length ?? 0;
                  final active = count > 0;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: active
                          ? AppColors.brandGreenSurface
                          : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: active
                              ? AppColors.brandGreenLight
                              : AppColors.divider),
                    ),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: [
                        Text(
                          '${_days[d.weekday - 1]}, ${d.day} ${_months[d.month]}',
                          style: TextStyle(
                              fontSize: 10,
                              color: active
                                  ? AppColors.brandGreen
                                  : AppColors.textSecondary,
                              fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          active ? '$count slots' : 'No slots',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: active
                                  ? AppColors.brandGreen
                                  : AppColors.textHint),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
          ],

          // Save button
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed:
                  (!hasChanges || _isSaving) ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                disabledBackgroundColor:
                    AppColors.brandGreen.withValues(alpha: 0.35),
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              Colors.white)))
                  : Row(
                      mainAxisAlignment:
                          MainAxisAlignment.center,
                      children: [
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
                              ? 'Save $total Slots'
                              : 'Saved',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Info banner ────────────────────────────────────────────────────────────

  Widget get _infoBanner => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: const Row(children: [
          Icon(Icons.info_outline_rounded,
              size: 14, color: AppColors.brandGreen),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Set From → To to fill a range instantly. Tap individual slots to fine-tune. Tap a date tile above to add or remove it.',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.brandGreen,
                  height: 1.4),
            ),
          ),
        ]),
      );

  // ── Empty state ────────────────────────────────────────────────────────────

  Widget get _emptyState => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_today_outlined,
                size: 44, color: AppColors.brandGreenLight),
            SizedBox(height: 14),
            Text('No dates selected',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            SizedBox(height: 6),
            Text(
              'Tap a date in the strip above\nto set your availability.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  height: 1.5),
            ),
          ],
        ),
      );

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final total = _totalSlots;
    final badge = Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text('$total slots',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600)),
    );

    final listView = _activeDates.isEmpty
        ? _emptyState
        : ListView(
            padding:
                const EdgeInsets.fromLTRB(16, 16, 16, 16),
            children: [
              _infoBanner,
              for (final d in _activeDates) _buildDayCard(d),
            ],
          );

    if (widget.embedded) {
      return Column(
        children: [
          Container(
            color: AppColors.brandGreen,
            padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.of(context).padding.top + 14,
                16,
                14),
            child: Row(children: [
              const Expanded(
                child: Text('My Schedule',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
              ),
              badge,
            ]),
          ),
          _buildDateStrip(),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(child: listView),
          _buildSaveButton(bottomPadding: 12),
        ],
      );
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
          Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(child: badge)),
        ],
      ),
      body: Column(
        children: [
          _buildDateStrip(),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(child: listView),
        ],
      ),
      bottomNavigationBar: _buildSaveButton(
          bottomPadding:
              MediaQuery.of(context).padding.bottom + 12),
    );
  }
}

// ─── Slot dropdown ────────────────────────────────────────────────────────────

class _SlotDropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<String> slots;
  final ValueChanged<String?> onChanged;

  const _SlotDropdown({
    required this.label,
    required this.value,
    required this.slots,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            isDense: true,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.brandGreen),
            icon: const Icon(Icons.expand_more_rounded,
                size: 16, color: AppColors.brandGreen),
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(10),
            items: slots
                .map((s) => DropdownMenuItem(
                      value: s,
                      child: Text(s,
                          style: const TextStyle(
                              fontSize: 12,
                              color: AppColors.textPrimary)),
                    ))
                .toList(),
            onChanged: onChanged,
          ),
        ),
      );
}
