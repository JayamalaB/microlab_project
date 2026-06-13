import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:microlab/theme/app_theme.dart';
import 'customer_home_screen.dart';
import 'package:microlab/models.dart';

class AddMemberScreen extends StatefulWidget {
  final MemberModel? existingMember;
  const AddMemberScreen({super.key, this.existingMember});

  @override
  State<AddMemberScreen> createState() => _AddMemberScreenState();
}

class _AddMemberScreenState extends State<AddMemberScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  bool _isLoading = false;

  // ── Mandatory ─────────────────────────────────────────────
  final _nameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _locationController = TextEditingController();
  final _addressController = TextEditingController();
  String? _gender;

  // ── Optional ──────────────────────────────────────────────
  final _emailController = TextEditingController();
  final _dobController = TextEditingController();
  final _relationController = TextEditingController();
  final _healthController = TextEditingController();
  DateTime? _selectedDob;
  int? _calculatedAge;

  // ── Photo ─────────────────────────────────────────────────
  Uint8List? _imageBytes;       // newly picked image bytes (web-safe)
  Uint8List? _existingBytes;    // bytes from existing member (edit mode)
  final ImagePicker _picker = ImagePicker();

  bool get _isEditing => widget.existingMember != null;
  bool get _hasPhoto => _imageBytes != null || _existingBytes != null;

  final List<String> _genders = ['Male', 'Female', 'Other'];
  final List<String> _relations = [
    'Self', 'Spouse', 'Father', 'Mother',
    'Son', 'Daughter', 'Brother', 'Sister', 'Other'
  ];

  @override
  void initState() {
    super.initState();
    if (_isEditing) _populateFields();
  }

  void _populateFields() {
    final m = widget.existingMember!;
    _nameController.text = m.name;
    _mobileController.text = m.mobile;
    _locationController.text = m.location;
    _addressController.text = m.address;
    _gender = m.gender;
    _emailController.text = m.email ?? '';
    _relationController.text = m.relation ?? '';
    _healthController.text = m.healthCondition ?? '';
    _existingBytes = m.photoBytes;
    if (m.dob != null) {
      _selectedDob = m.dob;
      _dobController.text = _formatDate(m.dob!);
      _calculatedAge = m.age;
    }
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  // ── Image picking ─────────────────────────────────────────

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        setState(() {
          _imageBytes = bytes;
          _existingBytes = null; // override existing
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not access ${source == ImageSource.camera ? 'camera' : 'gallery'}: ${e.message}'),
            backgroundColor: Colors.red[700],
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  void _removePhoto() {
    setState(() {
      _imageBytes = null;
      _existingBytes = null;
    });
  }

  void _showImageSourceSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(
            20, 0, 20, MediaQuery.of(context).padding.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            const Text(
              'Upload Photo',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 4),
            const Text(
              'Choose a clear face photo',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),

            // Camera option
            _ImageSourceTile(
              icon: Icons.camera_alt_outlined,
              iconColor: const Color(0xFF1565C0),
              iconBg: const Color(0xFFEEF4FB),
              title: 'Take a photo',
              subtitle: 'Open camera to capture now',
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.camera);
              },
            ),

            const SizedBox(height: 10),

            // Gallery option
            _ImageSourceTile(
              icon: Icons.photo_library_outlined,
              iconColor: const Color(0xFF6A1B9A),
              iconBg: const Color(0xFFF3E5F5),
              title: 'Choose from gallery',
              subtitle: 'Pick an existing photo',
              onTap: () {
                Navigator.pop(context);
                _pickImage(ImageSource.gallery);
              },
            ),

            // Remove option (only when photo exists)
            if (_hasPhoto) ...[
              const SizedBox(height: 10),
              _ImageSourceTile(
                icon: Icons.delete_outline_rounded,
                iconColor: const Color(0xFFD32F2F),
                iconBg: const Color(0xFFFFF5F5),
                title: 'Remove photo',
                subtitle: 'Delete the current photo',
                onTap: () {
                  Navigator.pop(context);
                  _removePhoto();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Date picker ───────────────────────────────────────────

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDob ?? DateTime(now.year - 30),
      firstDate: DateTime(now.year - 120),
      lastDate: now,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: AppColors.brandGreen),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _selectedDob = picked;
        _dobController.text = _formatDate(picked);
        final today = DateTime.now();
        int age = today.year - picked.year;
        if (today.month < picked.month ||
            (today.month == picked.month && today.day < picked.day)) age--;
        _calculatedAge = age;
      });
    }
  }

  // ── Submit ────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      _scrollController.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      return;
    }
    if (_gender == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please select a gender'),
          backgroundColor: Colors.red[700],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    // TODO: Upload image first, get URL back
    // POST /api/upload/photo  multipart { bytes: _imageBytes }
    // Then POST /api/customer/members with photoUrl
    await Future.delayed(const Duration(milliseconds: 800));

    final finalBytes = _imageBytes ?? _existingBytes;

    final member = MemberModel(
      id: _isEditing
          ? widget.existingMember!.id
          : DateTime.now().millisecondsSinceEpoch.toString(),
      name: _nameController.text.trim(),
      mobile: _mobileController.text.trim(),
      gender: _gender!,
      location: _locationController.text.trim(),
      address: _addressController.text.trim(),
      email: _emailController.text.trim().isEmpty
          ? null
          : _emailController.text.trim(),
      dob: _selectedDob,
      relation: _relationController.text.trim().isEmpty
          ? null
          : _relationController.text.trim(),
      healthCondition: _healthController.text.trim().isEmpty
          ? null
          : _healthController.text.trim(),
      photoBytes: finalBytes,
    );

    if (mounted) {
      setState(() => _isLoading = false);
      Navigator.pop(context, member);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _mobileController.dispose();
    _locationController.dispose();
    _addressController.dispose();
    _emailController.dispose();
    _dobController.dispose();
    _relationController.dispose();
    _healthController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _isEditing ? 'Edit Customer' : 'Add Customer',
          style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
          children: [
            // ── Photo Picker ──────────────────────────────
            _PhotoPickerWidget(
              imageBytes: _imageBytes,
              existingBytes: _existingBytes,
              hasPhoto: _hasPhoto,
              onTap: _showImageSourceSheet,
            ),

            const SizedBox(height: 24),

            // ── Mandatory ─────────────────────────────────
            _SectionHeader(label: 'Required Information'),
            _FormCard(children: [
              _FieldLabel(label: 'Full Name', required: true),
              _AppTextField(
                controller: _nameController,
                hint: 'Enter full name',
                icon: Icons.person_outline,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Name is required'
                    : null,
              ),

              const SizedBox(height: 16),
              _FieldLabel(label: 'Mobile Number', required: true),
              _AppTextField(
                controller: _mobileController,
                hint: '10-digit mobile number',
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                prefix: '+91 ',
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Mobile is required';
                  if (!RegExp(r'^[6-9]\d{9}$').hasMatch(v.trim())) {
                    return 'Enter a valid 10-digit mobile number';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 16),
              _FieldLabel(label: 'Gender', required: true),
              Row(
                children: List.generate(_genders.length, (i) => Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i < _genders.length - 1 ? 8 : 0),
                    child: _GenderChip(
                      label: _genders[i],
                      selected: _gender == _genders[i],
                      onTap: () => setState(() => _gender = _genders[i]),
                    ),
                  ),
                )),
              ),

              const SizedBox(height: 16),
              _FieldLabel(label: 'City / Location', required: true),
              _AppTextField(
                controller: _locationController,
                hint: 'e.g. Chennai',
                icon: Icons.location_city_outlined,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Location is required'
                    : null,
              ),

              const SizedBox(height: 16),
              _FieldLabel(label: 'Full Address', required: true),
              _AppTextField(
                controller: _addressController,
                hint: 'House no, Street, Area, Pincode',
                icon: Icons.home_outlined,
                maxLines: 3,
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Address is required'
                    : null,
              ),
            ]),

            const SizedBox(height: 16),

            // ── Optional ──────────────────────────────────
            _SectionHeader(label: 'Optional Information'),
            _FormCard(children: [
              _FieldLabel(label: 'Email Address'),
              _AppTextField(
                controller: _emailController,
                hint: 'example@email.com',
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  if (!RegExp(r'^[\w.-]+@[\w.-]+\.\w{2,}$')
                      .hasMatch(v.trim())) {
                    return 'Enter a valid email address';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 16),
              _FieldLabel(label: 'Date of Birth'),
              GestureDetector(
                onTap: _pickDate,
                child: Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    border: Border.all(color: AppColors.divider),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.cake_outlined,
                          size: 18, color: AppColors.textHint),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _dobController.text.isEmpty
                              ? 'DD/MM/YYYY'
                              : _dobController.text,
                          style: TextStyle(
                              fontSize: 14,
                              color: _dobController.text.isEmpty
                                  ? AppColors.textHint
                                  : AppColors.textPrimary),
                        ),
                      ),
                      if (_calculatedAge != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: AppColors.brandGreenSurface,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${_calculatedAge ?? 0} yrs',
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.brandGreen,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      const SizedBox(width: 6),
                      const Icon(Icons.calendar_month_outlined,
                          size: 18, color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              _FieldLabel(label: 'Relation'),
              DropdownButtonFormField<String>(
                value: _relationController.text.isEmpty
                    ? null
                    : (_relations.contains(_relationController.text)
                        ? _relationController.text
                        : null),
                hint: const Text('Select relation',
                    style: TextStyle(
                        fontSize: 14, color: AppColors.textHint)),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.people_outline,
                      size: 18, color: AppColors.textHint),
                  filled: true,
                  fillColor: AppColors.white,
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
                    borderSide: const BorderSide(
                        color: AppColors.brandGreen, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
                style: const TextStyle(
                    fontSize: 14, color: AppColors.textPrimary),
                dropdownColor: AppColors.white,
                borderRadius: BorderRadius.circular(12),
                items: _relations
                    .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _relationController.text = v ?? ''),
              ),

              const SizedBox(height: 16),
              _FieldLabel(label: 'Health Condition / Notes'),
              _AppTextField(
                controller: _healthController,
                hint: 'e.g. Diabetes, Hypertension, Thyroid…',
                icon: Icons.medical_information_outlined,
                maxLines: 2,
              ),
            ]),

            const SizedBox(height: 24),
          ],
        ),
      ),

      bottomNavigationBar: Container(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
        decoration: const BoxDecoration(
          color: AppColors.white,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandGreen,
              disabledBackgroundColor:
                  AppColors.brandGreen.withOpacity(0.4),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(Colors.white)),
                  )
                : Text(
                    _isEditing ? 'Save Changes' : 'Add Customer',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500),
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Photo Picker Widget ──────────────────────────────────────────────────────

class _PhotoPickerWidget extends StatelessWidget {
  final Uint8List? imageBytes;
  final Uint8List? existingBytes;
  final bool hasPhoto;
  final VoidCallback onTap;

  const _PhotoPickerWidget({
    required this.imageBytes,
    required this.existingBytes,
    required this.hasPhoto,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          GestureDetector(
            onTap: onTap,
            child: Stack(
              alignment: Alignment.bottomRight,
              children: [
                // Avatar circle
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: AppColors.brandGreenSurface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: hasPhoto
                          ? AppColors.brandGreen
                          : AppColors.brandGreenLight,
                      width: 2,
                    ),
                  ),
                  child: ClipOval(
                    child: _buildImage(),
                  ),
                ),

                // Camera badge
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.brandGreen,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.brandGreen.withOpacity(0.3),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Icon(
                    hasPhoto ? Icons.edit_outlined : Icons.camera_alt_outlined,
                    size: 15,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Label
          Text(
            hasPhoto ? 'Tap to change photo' : 'Add photo (optional)',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),

          // Uploaded indicator
          if (hasPhoto) ...[
            const SizedBox(height: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.brandGreenSurface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.brandGreenLight),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline,
                      size: 13, color: AppColors.brandGreen),
                  SizedBox(width: 4),
                  Text('Photo uploaded',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppColors.brandGreen,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImage() {
    final bytes = imageBytes ?? existingBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        width: 100,
        height: 100,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return const Center(
      child: Icon(Icons.person_outline, size: 42, color: AppColors.brandGreen),
    );
  }
}

// ─── Image Source Tile ────────────────────────────────────────────────────────

class _ImageSourceTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ImageSourceTile({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded,
                size: 14, color: AppColors.textHint),
          ],
        ),
      ),
    );
  }
}

// ─── Reusable form widgets ────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
                letterSpacing: 0.3)),
      );
}

class _FormCard extends StatelessWidget {
  final List<Widget> children;
  const _FormCard({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

class _FieldLabel extends StatelessWidget {
  final String label;
  final bool required;
  const _FieldLabel({required this.label, this.required = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: RichText(
          text: TextSpan(
            text: label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary),
            children: required
                ? const [
                    TextSpan(
                        text: ' *',
                        style: TextStyle(color: Color(0xFFD32F2F)))
                  ]
                : [],
          ),
        ),
      );
}

class _AppTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType keyboardType;
  final int? maxLength;
  final int maxLines;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final String? prefix;

  const _AppTextField({
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType = TextInputType.text,
    this.maxLength,
    this.maxLines = 1,
    this.inputFormatters,
    this.validator,
    this.prefix,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        maxLength: maxLength,
        maxLines: maxLines,
        inputFormatters: inputFormatters,
        validator: validator,
        style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              const TextStyle(fontSize: 14, color: AppColors.textHint),
          prefixIcon: Icon(icon, size: 18, color: AppColors.textHint),
          prefixText: prefix,
          isDense: true,
          prefixStyle: const TextStyle(
              fontSize: 14,
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w500),
          filled: true,
          fillColor: AppColors.white,
          counterText: '',
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
          contentPadding: EdgeInsets.symmetric(
              vertical: maxLines > 1 ? 14 : 0, horizontal: 14),
        ),
      );
}

class _GenderChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _GenderChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 42,
          decoration: BoxDecoration(
            color: selected ? AppColors.brandGreen : AppColors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? AppColors.brandGreen : AppColors.divider,
                width: selected ? 1.5 : 1),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : AppColors.textSecondary),
          ),
        ),
      );
}
