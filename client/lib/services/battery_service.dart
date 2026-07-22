import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── OEM manufacturer identifiers ─────────────────────────────────────────────

enum _Oem { samsung, xiaomi, oppo, vivo, realme, oneplus, motorola, pixel, generic }

// ─── BatteryService ───────────────────────────────────────────────────────────
//
// Single source of truth for all battery optimization logic.
//
// Two responsibilities:
//   1. Standard Android Doze/App-Standby exemption via
//      ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS (shows once per denial).
//   2. OEM-specific battery guide (Samsung, Xiaomi, Oppo, etc.) shown exactly
//      once per install — directs the technician to the manufacturer's extra
//      battery settings that the standard Android API cannot reach.
//
// Used by Uber Driver / Rapido Captain pattern:
//   ensureStandardExemption()  →  request if not granted
//   showOemGuideIfNeeded()     →  one-time manufacturer guide
//   Both called BEFORE ForegroundService.start() so Samsung does not kill
//   the service within the 5-second startForeground() window.

class BatteryService {
  BatteryService._();
  static final BatteryService instance = BatteryService._();

  // Persisted flag — set true once the OEM guide has been shown.
  // Never cleared automatically; reset only if the user reinstalls.
  static const _keyOemGuideDone = 'battery_oem_guide_done_v1';

  // ── Step 1: Standard Android battery exemption ─────────────────────────────
  //
  // Shows "Stop optimising battery for MicroLab?" system popup.
  // The popup is an in-app overlay — the Activity stays in the foreground,
  // so it is safe to call BEFORE startForegroundService().
  //
  // Returns true if the exemption is active after this call.
  Future<bool> ensureStandardExemption() async {
    if (kIsWeb || !Platform.isAndroid) return true;

    final isExempt = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    _log('Battery Optimization Check — isIgnoring=$isExempt');

    if (isExempt) {
      _log('Battery Optimization Already Granted ✓');
      return true;
    }

    _log('Requesting Battery Optimization Exemption...');
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();

    final nowExempt = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (nowExempt) {
      _log('Battery Optimization Granted ✓');
    } else {
      _log('Battery Optimization NOT Granted — user dismissed or denied');
    }
    return nowExempt;
  }

  // ── Step 2: OEM-specific battery guide ────────────────────────────────────
  //
  // Shown ONCE per install. Instructs the technician how to add MicroLab to
  // the manufacturer's "Never sleeping apps" / "Unrestricted background" list.
  // These settings are separate from Android's standard Doze exemption and
  // cannot be granted programmatically — the user must do it manually.
  //
  // For generic Android (Pixel, Motorola stock) or if already shown: no-op.
  Future<void> showOemGuideIfNeeded(BuildContext context) async {
    if (kIsWeb || !Platform.isAndroid) return;

    final prefs = await SharedPreferences.getInstance();
    final alreadyShown = prefs.getBool(_keyOemGuideDone) ?? false;
    if (alreadyShown) {
      _log('OEM Battery Guide — already shown, skipping');
      return;
    }

    final oem = await _detectOem();
    _log('OEM Battery Guide — manufacturer=${oem.name}');

    if (oem == _Oem.generic || oem == _Oem.pixel) {
      _log('OEM Battery Guide — not required for ${oem.name}');
      await prefs.setBool(_keyOemGuideDone, true);
      return;
    }

    if (!context.mounted) return;

    final content = _guideContent(oem);
    _log('OEM Battery Guide — showing for ${oem.name}');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _OemGuideSheet(content: content),
    );

    await prefs.setBool(_keyOemGuideDone, true);
    _log('OEM Battery Guide — shown and flagged ✓');
  }

  // ── Open battery optimization settings (for error recovery) ───────────────
  Future<void> openBatterySettings() =>
      FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<_Oem> _detectOem() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final m = info.manufacturer.toLowerCase();
      _log('Device — manufacturer="${info.manufacturer}"  model="${info.model}"  SDK=${info.version.sdkInt}');
      if (m.contains('samsung'))                              return _Oem.samsung;
      if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) return _Oem.xiaomi;
      if (m.contains('oppo'))                                 return _Oem.oppo;
      if (m.contains('vivo'))                                 return _Oem.vivo;
      if (m.contains('realme'))                               return _Oem.realme;
      if (m.contains('oneplus') || m.contains('one plus'))    return _Oem.oneplus;
      if (m.contains('motorola') || m.contains('moto'))       return _Oem.motorola;
      if (m.contains('google'))                               return _Oem.pixel;
    } catch (e, st) {
      _log('OEM detection error: $e\n$st');
    }
    return _Oem.generic;
  }

  _GuideContent _guideContent(_Oem oem) {
    switch (oem) {
      case _Oem.samsung:
        return const _GuideContent(
          brand: 'Samsung',
          subtitle: 'One UI — Device Care',
          steps: [
            'Open  Settings',
            'Tap  Device Care  (or Device Maintenance)',
            'Tap  Battery',
            'Tap  Background usage limits',
            'Tap  Never auto sleeping apps',
            'Tap  +  (top right) and select  MicroLab',
            'Also tap  Deep sleeping apps  — remove  MicroLab  if listed there',
          ],
        );
      case _Oem.xiaomi:
        return const _GuideContent(
          brand: 'Xiaomi / Redmi / POCO',
          subtitle: 'MIUI — Battery Saver',
          steps: [
            'Open  Settings  →  Apps  →  Manage Apps',
            'Find and tap  MicroLab',
            'Tap  Battery Saver  and select  No Restrictions',
            'Also open the  Security  app',
            'Tap  Battery  →  App Battery Saver',
            'Find  MicroLab  and select  No Restrictions',
          ],
        );
      case _Oem.oppo:
        return const _GuideContent(
          brand: 'OPPO',
          subtitle: 'ColorOS — App Management',
          steps: [
            'Open  Settings  →  App Management',
            'Find and tap  MicroLab',
            'Tap  Battery',
            'Select  Allow background activity',
          ],
        );
      case _Oem.vivo:
        return const _GuideContent(
          brand: 'Vivo',
          subtitle: 'FuntouchOS — Battery',
          steps: [
            'Open  Settings  →  Battery',
            'Tap  High Background Power Consumption',
            'Enable the toggle for  MicroLab',
          ],
        );
      case _Oem.realme:
        return const _GuideContent(
          brand: 'Realme',
          subtitle: 'Realme UI — App Management',
          steps: [
            'Open  Settings  →  App Management',
            'Find and tap  MicroLab',
            'Tap  Battery',
            'Select  Allow background activity',
          ],
        );
      case _Oem.oneplus:
        return const _GuideContent(
          brand: 'OnePlus',
          subtitle: 'OxygenOS — App Info',
          steps: [
            'Open  Settings  →  Apps',
            'Find and tap  MicroLab',
            'Tap  Battery',
            'Enable  Allow background activity',
          ],
        );
      case _Oem.motorola:
        return const _GuideContent(
          brand: 'Motorola',
          subtitle: 'Moto — Battery Optimization',
          steps: [
            'Open  Settings  →  Battery',
            'Tap  Battery Optimization',
            'Find  MicroLab',
            'Select  Not optimized',
          ],
        );
      default:
        return const _GuideContent(brand: '', subtitle: '', steps: []);
    }
  }


  static void _log(String msg) {
    if (kDebugMode) {
      final ts = DateTime.now().toIso8601String().substring(11, 23);
      debugPrint('$ts [BatteryService] $msg');
    }
  }
}

// ─── Guide content model ───────────────────────────────────────────────────────

class _GuideContent {
  final String brand;
  final String subtitle;
  final List<String> steps;
  const _GuideContent({
    required this.brand,
    required this.subtitle,
    required this.steps,
  });
}

// ─── OEM guide bottom sheet ────────────────────────────────────────────────────

class _OemGuideSheet extends StatelessWidget {
  const _OemGuideSheet({required this.content});
  final _GuideContent content;

  static const _blue = Color(0xFF1565C0);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24, 20, 24,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.battery_alert_rounded,
                  color: Colors.orange.shade700,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Allow Background Activity',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      content.brand.isNotEmpty
                          ? '${content.brand} — ${content.subtitle}'
                          : 'Battery Setup Required',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Text(
            'To receive booking requests when your screen is off, MicroLab needs '
            'unrestricted background access. Follow these steps once:',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 16),

          // Numbered steps
          ...content.steps.asMap().entries.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: _blue,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Center(
                      child: Text(
                        '${e.key + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        e.value,
                        style: const TextStyle(fontSize: 14, height: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Open Battery Settings button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.settings_outlined, size: 18),
              label: const Text(
                'Open Battery Settings',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onPressed: () async {
                Navigator.of(context).pop();
                await BatteryService.instance.openBatterySettings();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: _blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Dismiss
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                "I'll do this later",
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
