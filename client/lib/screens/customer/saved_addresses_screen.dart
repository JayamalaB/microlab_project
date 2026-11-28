import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/models.dart';
import 'package:geolocator/geolocator.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/utils/geocode.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';
import 'package:microlab/screens/shared/location_picker_screen.dart';

class SavedAddressesScreen extends StatefulWidget {
  /// When non-null, the screen shows a "Use this address" button on each card.
  /// Tapped address is returned via Navigator.pop().
  final bool selectionMode;

  const SavedAddressesScreen({super.key, this.selectionMode = false});

  @override
  State<SavedAddressesScreen> createState() => _SavedAddressesScreenState();
}

class _SavedAddressesScreenState extends State<SavedAddressesScreen> {
  List<AddressModel> _addresses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(msg),
        ]),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await ApiService.getAddresses();
    if (mounted) setState(() { _addresses = list; _loading = false; });
  }

  Future<void> _openSheet({AddressModel? editing}) async {
    final saved = await showModalBottomSheet<AddressModel>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddressSheet(editing: editing),
    );
    if (saved != null) {
      bool ok;
      if (editing == null) {
        final id = await ApiService.addAddress(_toBody(saved));
        ok = id != null;
      } else {
        ok = await ApiService.updateAddress(editing.id, _toBody(saved));
      }
      if (!mounted) return;
      if (ok) {
        _showSuccess(editing == null ? 'Address saved successfully' : 'Address updated successfully');
        _load();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save address')),
        );
      }
    }
  }

  Map<String, dynamic> _toBody(AddressModel a) => {
        'label': a.label,
        'full_address': a.fullAddress,
        if (a.pincode != null) 'pincode': a.pincode,
        if (a.city != null) 'city': a.city,
        if (a.lat != null) 'lat': a.lat,
        if (a.lng != null) 'lng': a.lng,
        'is_default': a.isDefault,
      };

  Future<void> _delete(AddressModel a) async {
    final confirmed = await showCxConfirm(
      context,
      icon: Icons.delete_outline_rounded,
      title: 'Delete address?',
      message: 'Remove "${a.label}" from your saved addresses?',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed != true) return;
    final ok = await ApiService.deleteAddress(a.id);
    if (!mounted) return;
    if (ok) {
      _showSuccess('Address deleted successfully');
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete address')),
      );
    }
  }

  Future<void> _setDefault(AddressModel a) async {
    final ok = await ApiService.setDefaultAddress(a.id);
    if (!mounted) return;
    if (ok) {
      _showSuccess('Default address updated');
      _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to set default')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomerThemeScope(
      child: Scaffold(
        backgroundColor: CxColors.page,
        appBar: AppBar(
          backgroundColor: AppColors.brandGreen,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: Text(
            widget.selectionMode ? 'Select Address' : 'Saved Addresses',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _addresses.isEmpty
                ? Center(
                    child: CxEmptyState(
                      icon: Icons.location_on_outlined,
                      title: 'No saved addresses',
                      message: 'Tap the + button to add your first address.',
                      actionLabel: 'Add Address',
                      onAction: () => _openSheet(),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    itemCount: _addresses.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _AddressCard(
                      address: _addresses[i],
                      selectionMode: widget.selectionMode,
                      onEdit: () => _openSheet(editing: _addresses[i]),
                      onDelete: () => _delete(_addresses[i]),
                      onSetDefault: () => _setDefault(_addresses[i]),
                      onSelect: widget.selectionMode
                          ? () => Navigator.pop(context, _addresses[i])
                          : null,
                    ),
                  ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openSheet(),
          backgroundColor: AppColors.brandGreen,
          icon: const Icon(Icons.add, color: Colors.white),
          label: const Text('Add Address', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

// ─── Address card ─────────────────────────────────────────────────────────────

class _AddressCard extends StatelessWidget {
  final AddressModel address;
  final bool selectionMode;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onSetDefault;
  final VoidCallback? onSelect;

  const _AddressCard({
    required this.address,
    required this.selectionMode,
    required this.onEdit,
    required this.onDelete,
    required this.onSetDefault,
    this.onSelect,
  });

  IconData get _icon {
    switch (address.label.toLowerCase()) {
      case 'home': return Icons.home_outlined;
      case 'work': return Icons.work_outline_rounded;
      default:     return Icons.location_on_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: CxRadius.lgAll,
        border: Border.all(
          color: address.isDefault ? AppColors.brandGreen : CxColors.border,
          width: address.isDefault ? 1.5 : 1,
        ),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icon, size: 20, color: AppColors.brandGreen),
                const SizedBox(width: 8),
                Text(address.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: CxColors.textPrimary)),
                if (address.isDefault) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('Default', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
                  ),
                ],
                const Spacer(),
                // Edit
                InkWell(
                  onTap: onEdit,
                  borderRadius: BorderRadius.circular(16),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.edit_outlined, size: 18, color: CxColors.textSecondary),
                  ),
                ),
                const SizedBox(width: 4),
                // Delete
                InkWell(
                  onTap: onDelete,
                  borderRadius: BorderRadius.circular(16),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.delete_outline_rounded, size: 18, color: CxColors.error),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(address.fullAddress, style: const TextStyle(fontSize: 13, color: CxColors.textSecondary, height: 1.4)),
            if (address.city != null || address.pincode != null) ...[
              const SizedBox(height: 4),
              Text(
                [if (address.city != null) address.city!, if (address.pincode != null) address.pincode!].join(' – '),
                style: const TextStyle(fontSize: 12, color: CxColors.textHint),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (!address.isDefault)
                  TextButton.icon(
                    onPressed: onSetDefault,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('Set as Default'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.brandGreen,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      minimumSize: const Size(0, 32),
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                const Spacer(),
                if (selectionMode && onSelect != null)
                  ElevatedButton(
                    onPressed: onSelect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      minimumSize: const Size(0, 34),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text('Use this address'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Add / Edit sheet ─────────────────────────────────────────────────────────

class _AddressSheet extends StatefulWidget {
  final AddressModel? editing;
  const _AddressSheet({this.editing});

  @override
  State<_AddressSheet> createState() => _AddressSheetState();
}

class _AddressSheetState extends State<_AddressSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _addressCtrl;
  late final TextEditingController _pincodeCtrl;
  late final TextEditingController _cityCtrl;
  late String _label;
  late bool _isDefault;
  static const _labels = ['Home', 'Work', 'Other'];

  // The address's point on the map — needed for Home Collection (service
  // charge distance, dispatch). From GPS, the map, or looked up on Save.
  double? _lat;
  double? _lng;
  String? _locSource;        // 'gps' | 'map' | 'pincode' — set in this sheet
  bool _locating = false;    // GPS fix in progress
  bool _saving   = false;    // address lookup on Save
  String? _locError;

  // Pincode lookup as it is typed (like "Enter Address Manually").
  bool _pinLookup = false;
  String? _pinArea;          // "Peelamedu, Coimbatore, Tamil Nadu"
  String? _pinError;
  String _lastPin = '';
  int _pinLookupId = 0;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _label       = e?.label ?? 'Home';
    _isDefault   = e?.isDefault ?? false;
    _addressCtrl = TextEditingController(text: e?.fullAddress ?? '');
    _pincodeCtrl = TextEditingController(text: e?.pincode ?? '');
    _cityCtrl    = TextEditingController(text: e?.city ?? '');
    _lat = e?.lat;
    _lng = e?.lng;
    // An edited address keeps its point until its pincode is changed.
    _lastPin = _pincodeCtrl.text.trim();
    _pincodeCtrl.addListener(_onPincodeChanged);
  }

  void _onPincodeChanged() {
    final pin = _pincodeCtrl.text.trim();
    if (pin == _lastPin) return;
    _lastPin = pin;
    if (pin.length != 6) {
      _pinLookupId++; // drop any lookup still running for the old pincode
      if (_pinArea != null || _pinError != null || _pinLookup) {
        setState(() { _pinArea = null; _pinError = null; _pinLookup = false; });
      }
      return;
    }
    _lookupPincode(pin);
  }

  Future<void> _lookupPincode(String pin) async {
    final id = ++_pinLookupId;
    setState(() { _pinLookup = true; _pinArea = null; _pinError = null; });
    final info = await lookupPincode(pin);
    if (!mounted || id != _pinLookupId) return; // pincode changed meanwhile
    setState(() {
      _pinLookup = false;
      if (info == null) {
        _pinError = 'Pincode not found — check it or pick the place on the map.';
        return;
      }
      _pinArea = [info.area, info.district, info.state].whereType<String>().join(', ');
      if (_cityCtrl.text.trim().isEmpty && info.district != null) _cityCtrl.text = info.district!;
      // An exact point from GPS or the map is kept; otherwise the pincode's.
      if (info.point != null && _locSource != 'gps' && _locSource != 'map') {
        _lat = info.point!.lat;
        _lng = info.point!.lng;
        _locSource = 'pincode';
        _locError = null;
      }
    });
  }

  Future<void> _useCurrentLocation() async {
    setState(() { _locating = true; _locError = null; });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() => _locError = 'Turn on location, or pick the place on the map.');
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        setState(() => _locError = 'Location access is off. Pick the place on the map instead.');
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() { _lat = pos.latitude; _lng = pos.longitude; _locSource = 'gps'; });
    } catch (_) {
      if (mounted) setState(() => _locError = 'Couldn\'t get your location. Try again or pick it on the map.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickOnMap() async {
    setState(() => _locError = null);
    final picked = await Navigator.push<PickedLocation>(
      context,
      MaterialPageRoute(builder: (_) => const LocationPickerScreen()),
    );
    if (picked == null || !mounted) return;
    setState(() { _lat = picked.lat; _lng = picked.lng; _locSource = 'map'; });
  }

  @override
  void dispose() {
    _pincodeCtrl.removeListener(_onPincodeChanged);
    _addressCtrl.dispose();
    _pincodeCtrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final address = _addressCtrl.text.trim();
    final pincode = _pincodeCtrl.text.trim();
    final city    = _cityCtrl.text.trim();

    // No point picked here: look it up from the address — also when an
    // edited address or pincode no longer matches its old point.
    final e = widget.editing;
    final textChanged = e != null && (e.fullAddress.trim() != address || (e.pincode ?? '') != pincode);
    var lat = _lat, lng = _lng;
    if (_locSource == null && (lat == null || lng == null || textChanged)) {
      setState(() { _saving = true; _locError = null; });
      final point = await geocodeAddress(address: address, pincode: pincode, city: city);
      if (!mounted) return;
      setState(() => _saving = false);
      if (point == null) {
        setState(() => _locError =
            'We couldn\'t find this address on the map. Use current location or pick it on the map.');
        return;
      }
      lat = point.lat;
      lng = point.lng;
    }

    final result = AddressModel(
      id: e?.id ?? 0,
      label: _label,
      fullAddress: address,
      pincode: pincode.isEmpty ? null : pincode,
      city: city.isEmpty ? null : city,
      lat: lat,
      lng: lng,
      isDefault: _isDefault,
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      margin: const EdgeInsets.only(top: 60),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, bottom + 20),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar + close (✕)
                const CxSheetHandleBar(),
                Text(widget.editing == null ? 'Add Address' : 'Edit Address',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: CxColors.textPrimary)),
                const SizedBox(height: 20),

                // Label
                const Text('Label', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textSecondary)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: _labels.map((l) => ChoiceChip(
                    label: Text(l),
                    selected: _label == l,
                    onSelected: (_) => setState(() => _label = l),
                    selectedColor: AppColors.brandGreenSurface,
                    labelStyle: TextStyle(
                      color: _label == l ? AppColors.brandGreen : CxColors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    side: BorderSide(color: _label == l ? AppColors.brandGreen : CxColors.border),
                    shape: const StadiumBorder(),
                  )).toList(),
                ),
                const SizedBox(height: 16),

                // Full address
                const Text('Address *', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textSecondary)),
                const SizedBox(height: 6),
                TextFormField(
                  controller: _addressCtrl,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: _inputDeco('e.g. 12 Gandhi St, T Nagar, Chennai'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Address is required' : null,
                ),
                const SizedBox(height: 14),

                // Pincode + City in same row
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Pincode *', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textSecondary)),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _pincodeCtrl,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                            decoration: _inputDeco('600001'),
                            validator: (v) => (v == null || v.trim().length != 6) ? 'Enter the 6-digit pincode' : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('City', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textSecondary)),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _cityCtrl,
                            textCapitalization: TextCapitalization.words,
                            decoration: _inputDeco('Chennai'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // What the pincode resolved to (looked up on the 6th digit).
                if (_pinLookup)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Row(children: [
                      SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                      SizedBox(width: 8),
                      Text('Finding pincode…', style: CxText.caption),
                    ]),
                  )
                else if (_pinArea != null && _pinArea!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.location_on_outlined, size: 15, color: AppColors.brandGreen),
                      const SizedBox(width: 4),
                      Expanded(child: Text(_pinArea!,
                          style: const TextStyle(fontSize: 12, color: CxColors.textSecondary, fontWeight: FontWeight.w600))),
                    ]),
                  )
                else if (_pinError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(Icons.error_outline_rounded, size: 15, color: CxColors.error),
                      const SizedBox(width: 4),
                      Expanded(child: Text(_pinError!, style: const TextStyle(fontSize: 12, color: CxColors.error))),
                    ]),
                  ),
                const SizedBox(height: 16),

                // Location on map — exact point from GPS or the map; when
                // neither is used it is looked up from the address on Save.
                const Text('Location on map', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textSecondary)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: _LocButton(
                      icon: Icons.my_location_rounded,
                      label: 'Current location',
                      busy: _locating,
                      selected: _locSource == 'gps',
                      onTap: (_locating || _saving) ? null : _useCurrentLocation,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _LocButton(
                      icon: Icons.map_outlined,
                      label: 'Pick on map',
                      selected: _locSource == 'map',
                      onTap: (_locating || _saving) ? null : _pickOnMap,
                    ),
                  ),
                ]),
                const SizedBox(height: 6),
                if (_locError != null)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.error_outline_rounded, size: 15, color: CxColors.error),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_locError!, style: const TextStyle(fontSize: 12, color: CxColors.error))),
                  ])
                else if (_locSource != null)
                  Row(children: [
                    const Icon(Icons.check_circle_rounded, size: 15, color: AppColors.brandGreen),
                    const SizedBox(width: 6),
                    Text(
                        _locSource == 'gps' ? 'Location set from your current position'
                            : _locSource == 'map' ? 'Location set on the map'
                            : 'Location found from pincode',
                        style: const TextStyle(fontSize: 12, color: AppColors.brandGreen, fontWeight: FontWeight.w600)),
                  ])
                else if (_lat != null && _lng != null)
                  const Text('Location saved. Tap above to change it.', style: CxText.caption)
                else
                  const Text('Found from the pincode, or set it exactly with the buttons above.', style: CxText.caption),
                const SizedBox(height: 12),

                // Default toggle
                InkWell(
                  onTap: () => setState(() => _isDefault = !_isDefault),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Checkbox(
                          value: _isDefault,
                          onChanged: (v) => setState(() => _isDefault = v ?? false),
                          activeColor: AppColors.brandGreen,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        const SizedBox(width: 6),
                        const Text('Set as default address', style: TextStyle(fontSize: 14, color: CxColors.textPrimary)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: (_saving || _locating || _pinLookup) ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    child: _saving
                        ? const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text(widget.editing == null ? 'Save Address' : 'Update Address'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: CxColors.textHint, fontSize: 13),
        filled: true,
        fillColor: CxColors.page,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: CxColors.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: CxColors.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.brandGreen, width: 1.5)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: CxColors.error)),
        focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: CxColors.error, width: 1.5)),
      );
}

// "Current location" / "Pick on map" button in the Add Address sheet.
class _LocButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool busy;
  final bool selected;
  final VoidCallback? onTap;
  const _LocButton({
    required this.icon,
    required this.label,
    this.busy = false,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? AppColors.brandGreenSurface : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? AppColors.brandGreen : CxColors.border, width: selected ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 44,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              busy
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen))
                  : Icon(icon, size: 18, color: AppColors.brandGreen),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
              ),
            ]),
          ),
        ),
      );
}
