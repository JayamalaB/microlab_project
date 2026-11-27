import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/utils/app_messages.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';
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
  final _ageCtrl    = TextEditingController();

  String? _gender;
  DateTime? _dob;
  int? _calculatedAge;
  bool _saving = false;

  @override
  void dispose() {
    _namCtrl.dispose();
    _cityCtrl.dispose();
    _addrCtrl.dispose();
    _dobCtrl.dispose();
    _ageCtrl.dispose();
    super.dispose();
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  void _onAgeChanged(String val) {
    final age = int.tryParse(val.trim());
    if (age == null) return;
    final now = DateTime.now();
    final dobYear = age == 0 ? now.year : now.year - age;
    final dob = DateTime(dobYear, now.month, now.day);
    setState(() {
      _dob = dob;
      _dobCtrl.text = _formatDate(dob);
      _calculatedAge = age;
    });
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
          colorScheme: const ColorScheme.light(primary: AppColors.brandGreen),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    int age = now.year - picked.year;
    if (now.month < picked.month ||
        (now.month == picked.month && now.day < picked.day)) { age--; }
    setState(() {
      _dob = picked;
      _dobCtrl.text = _formatDate(picked);
      _calculatedAge = age;
      _ageCtrl.text = age.toString();
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_gender == null || (_dob == null && _ageCtrl.text.trim().isEmpty)) {
      setState(() {});
      return;
    }
    setState(() => _saving = true);

    String? dobForApi;
    if (_dob != null) {
      dobForApi = '${_dob!.year}-'
          '${_dob!.month.toString().padLeft(2, '0')}-'
          '${_dob!.day.toString().padLeft(2, '0')}';
    }

    final body = <String, dynamic>{
      'name':     _namCtrl.text.trim(),
      'mobile':   widget.mobile,
      'gender':   _gender!,
      'location': _cityCtrl.text.trim(),
      'address':  _addrCtrl.text.trim(),
      'relation': 'Self',
      if (dobForApi != null) 'date_of_birth': dobForApi,
      if (_calculatedAge != null) 'age': _calculatedAge.toString(),
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
      AppMessages.error(context, AppMessages.serverMessage(result['message'],
          fallback: 'We couldn\'t save your profile. Please try again.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomerThemeScope(
      child: Scaffold(
      backgroundColor: CxColors.page,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──────────────────────────────────────────
            Container(
              color: AppColors.brandGreen,
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 22),
              child: Row(
                children: [
                  Container(
                    width: 44, height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: CxRadius.mdAll,
                    ),
                    child: const Icon(Icons.person_outline_rounded,
                        color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Complete Your Profile',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Required to proceed',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Form ────────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                child: Center(
                child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: CxSize.contentMaxWidth),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Mobile — read only
                      const _Label('Mobile Number'),
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
                          suffix: const CxChip(
                            label: 'Verified',
                            icon: Icons.verified_rounded,
                            tone: CxTone.brand,
                          ),
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Full name
                      const _Label('Full Name', required: true),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _namCtrl,
                        textCapitalization: TextCapitalization.words,
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z ]'))],
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
                      const _Label('Gender', required: true),
                      const SizedBox(height: 8),
                      Row(
                        children: ['Male', 'Female', 'Other'].map((g) {
                          final selected = _gender == g;
                          return Expanded(
                            child: Semantics(
                              button: true,
                              selected: selected,
                              label: 'Gender $g',
                              excludeSemantics: true,
                              child: GestureDetector(
                              onTap: () => setState(() => _gender = g),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                margin: EdgeInsets.only(
                                    right: g != 'Other' ? 10 : 0),
                                height: CxSize.minTouch,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: selected
                                      ? CxColors.brand
                                      : Colors.white,
                                  borderRadius: CxRadius.mdAll,
                                  border: Border.all(
                                    color: selected
                                        ? CxColors.brand
                                        : CxColors.border,
                                    width: selected ? 1.5 : 1,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (selected) ...[
                                      const Icon(Icons.check_rounded,
                                          size: 16, color: Colors.white),
                                      const SizedBox(width: 4),
                                    ],
                                    Flexible(
                                      child: Text(g,
                                          textAlign: TextAlign.center,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: selected
                                                  ? Colors.white
                                                  : AppColors.textSecondary)),
                                    ),
                                  ],
                                ),
                              ),
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
                                  color: CxColors.error)),
                        ),

                      const SizedBox(height: 18),

                      // DOB or Age
                      const _Label('DOB or Age', required: true),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: GestureDetector(
                              onTap: _pickDob,
                              child: Container(
                                height: 50,
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: CxRadius.mdAll,
                                  border: Border.all(color: CxColors.border),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.cake_outlined,
                                        size: 18, color: AppColors.textHint),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _dobCtrl.text.isEmpty ? 'DD/MM/YYYY' : _dobCtrl.text,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: _dobCtrl.text.isEmpty
                                              ? AppColors.textHint
                                              : AppColors.textPrimary,
                                        ),
                                      ),
                                    ),
                                    const Icon(Icons.calendar_month_outlined,
                                        size: 18, color: CxColors.brand),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: TextFormField(
                              controller: _ageCtrl,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              onChanged: _onAgeChanged,
                              style: const TextStyle(
                                  fontSize: 14, color: AppColors.textPrimary),
                              decoration: _inputDec(
                                hint: 'Age',
                                prefix: const Icon(Icons.numbers_outlined,
                                    size: 18, color: AppColors.textHint),
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_saving && _dob == null && _ageCtrl.text.trim().isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 6, left: 4),
                          child: Text('Date of birth or age is required',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: CxColors.error)),
                        ),

                      const SizedBox(height: 18),

                      // City
                      const _Label('City', required: true),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _cityCtrl,
                        textCapitalization: TextCapitalization.words,
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z ]'))],
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
                      const _Label('Address', required: true),
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
                      CxButton(
                        label: 'Save & Continue',
                        loading: _saving,
                        onPressed: _saving
                            ? null
                            : () {
                                if (_gender == null || (_dob == null && _ageCtrl.text.trim().isEmpty)) {
                                  setState(() {});
                                  return;
                                }
                                _save();
                              },
                      ),
                    ],
                  ),
                ),
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

// ── Helpers ───────────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  final bool required;
  const _Label(this.text, {this.required = false});

  @override
  Widget build(BuildContext context) {
    if (!required) {
      return Text(text, style: CxText.label);
    }
    return RichText(
      text: TextSpan(
        style: CxText.label,
        children: [
          TextSpan(text: text),
          const TextSpan(text: ' *', style: TextStyle(color: CxColors.error)),
        ],
      ),
    );
  }
}

InputDecoration _inputDec({
  required String hint,
  Widget? prefix,
  Widget? suffix,
}) =>
    InputDecoration(
      hintText: hint,
      hintStyle:
          const TextStyle(fontSize: 14, color: AppColors.textHint),
      errorStyle: const TextStyle(fontSize: 12, color: CxColors.error),
      errorMaxLines: 2,
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
          const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: const OutlineInputBorder(
        borderRadius: CxRadius.mdAll,
        borderSide: BorderSide(color: CxColors.border),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: CxRadius.mdAll,
        borderSide: BorderSide(color: CxColors.border),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: CxRadius.mdAll,
        borderSide:
            BorderSide(color: CxColors.brand, width: 1.5),
      ),
      errorBorder: const OutlineInputBorder(
        borderRadius: CxRadius.mdAll,
        borderSide:
            BorderSide(color: CxColors.error, width: 1.5),
      ),
      focusedErrorBorder: const OutlineInputBorder(
        borderRadius: CxRadius.mdAll,
        borderSide:
            BorderSide(color: CxColors.error, width: 1.5),
      ),
    );
