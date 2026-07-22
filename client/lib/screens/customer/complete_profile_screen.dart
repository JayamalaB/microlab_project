import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/api_service.dart';
import 'customer_home_screen.dart';

class CompleteProfileScreen extends StatefulWidget {
  final String mobile;
  final int patientId;
  final bool isVip;

  const CompleteProfileScreen({
    super.key,
    required this.mobile,
    required this.patientId,
    this.isVip = false,
  });

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _formKey    = GlobalKey<FormState>();
  final _namCtrl    = TextEditingController();
  final _cityCtrl   = TextEditingController();
  final _addrCtrl   = TextEditingController();
  final _dobCtrl    = TextEditingController();

  String? _gender;
  DateTime? _dob;
  bool _saving = false;

  @override
  void dispose() {
    _namCtrl.dispose();
    _cityCtrl.dispose();
    _addrCtrl.dispose();
    _dobCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(1990),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: AppColors.brandGreen),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      _dob = picked;
      _dobCtrl.text =
          '${picked.day.toString().padLeft(2, '0')}/'
          '${picked.month.toString().padLeft(2, '0')}/'
          '${picked.year}';
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final body = {
      'name':          _namCtrl.text.trim(),
      'mobile':        widget.mobile,
      'gender':        _gender!,
      'location':      _cityCtrl.text.trim(),
      'address':       _addrCtrl.text.trim(),
      'relation':      'Self',
      if (_dob != null)
        'date_of_birth': '${_dob!.year}-'
            '${_dob!.month.toString().padLeft(2, '0')}-'
            '${_dob!.day.toString().padLeft(2, '0')}',
    };

    final result = await ApiService.updatePatient(
        widget.patientId.toString(), body);

    if (!mounted) return;
    setState(() => _saving = false);

    if (result['success'] == true) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => CustomerHomeScreen(
            mobile: widget.mobile,
            isVip:  widget.isVip,
          ),
        ),
        (route) => false,
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result['message'] as String? ?? 'Could not save profile'),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────
            Container(
              color: AppColors.brandGreen,
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
              child: Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.person_outline_rounded,
                        color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Complete Your Profile',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Required to proceed',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Form ────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Mobile — read only
                      _Label('Mobile Number'),
                      const SizedBox(height: 6),
                      TextFormField(
                        initialValue: widget.mobile,
                        readOnly: true,
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textSecondary),
                        decoration: _inputDec(
                          hint: widget.mobile,
                          prefix: const Icon(Icons.phone_outlined,
                              size: 18, color: AppColors.textHint),
                          suffix: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.brandGreenSurface,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('Verified',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.brandGreen,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Full name
                      _Label('Full Name *'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _namCtrl,
                        textCapitalization: TextCapitalization.words,
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textPrimary),
                        decoration: _inputDec(
                          hint: 'Enter your full name',
                          prefix: const Icon(Icons.person_outline_rounded,
                              size: 18, color: AppColors.textHint),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Name is required'
                            : null,
                      ),

                      const SizedBox(height: 18),

                      // Gender
                      _Label('Gender *'),
                      const SizedBox(height: 8),
                      Row(
                        children: ['Male', 'Female', 'Other'].map((g) {
                          final selected = _gender == g;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _gender = g),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                margin: EdgeInsets.only(
                                    right: g != 'Other' ? 10 : 0),
                                padding: const EdgeInsets.symmetric(
                                    vertical: 11),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? AppColors.brandGreen
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: selected
                                        ? AppColors.brandGreen
                                        : AppColors.divider,
                                    width: selected ? 1.5 : 1,
                                  ),
                                ),
                                child: Text(g,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: selected
                                            ? Colors.white
                                            : AppColors.textSecondary)),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      if (_saving && _gender == null)
                        const Padding(
                          padding: EdgeInsets.only(top: 6, left: 4),
                          child: Text('Gender is required',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFD32F2F))),
                        ),

                      const SizedBox(height: 18),

                      // Date of birth
                      _Label('Date of Birth'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _dobCtrl,
                        readOnly: true,
                        onTap: _pickDob,
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textPrimary),
                        decoration: _inputDec(
                          hint: 'DD/MM/YYYY  (optional)',
                          prefix: const Icon(Icons.cake_outlined,
                              size: 18, color: AppColors.textHint),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // City
                      _Label('City *'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _cityCtrl,
                        textCapitalization: TextCapitalization.words,
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textPrimary),
                        decoration: _inputDec(
                          hint: 'e.g. Chennai',
                          prefix: const Icon(Icons.location_city_outlined,
                              size: 18, color: AppColors.textHint),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'City is required'
                            : null,
                      ),

                      const SizedBox(height: 18),

                      // Address
                      _Label('Address *'),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _addrCtrl,
                        maxLines: 3,
                        textCapitalization: TextCapitalization.sentences,
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textPrimary),
                        decoration: _inputDec(
                          hint: 'House / flat, street, area',
                          prefix: const Padding(
                            padding: EdgeInsets.only(bottom: 42),
                            child: Icon(Icons.home_outlined,
                                size: 18, color: AppColors.textHint),
                          ),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Address is required'
                            : null,
                      ),

                      const SizedBox(height: 32),

                      // Save button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _saving
                              ? null
                              : () {
                                  if (_gender == null) {
                                    setState(() {});
                                    return;
                                  }
                                  _save();
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.brandGreen,
                            disabledBackgroundColor:
                                AppColors.brandGreen.withValues(alpha: 0.5),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white))
                              : const Text('Save & Continue',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary),
      );
}

InputDecoration _inputDec({
  required String hint,
  Widget? prefix,
  Widget? suffix,
}) =>
    InputDecoration(
      hintText: hint,
      hintStyle:
          const TextStyle(fontSize: 13, color: AppColors.textHint),
      prefixIcon: prefix,
      suffixIcon: suffix != null
          ? Padding(
              padding: const EdgeInsets.only(right: 10),
              child: suffix,
            )
          : null,
      suffixIconConstraints:
          const BoxConstraints(minWidth: 0, minHeight: 0),
      filled: true,
      fillColor: Colors.white,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
            const BorderSide(color: AppColors.brandGreen, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            const BorderSide(color: Color(0xFFD32F2F), width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide:
            const BorderSide(color: Color(0xFFD32F2F), width: 1.5),
      ),
    );
