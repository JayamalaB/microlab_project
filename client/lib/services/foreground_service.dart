import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// ─── Background isolate entry point ───────────────────────────────────────────
//
// Android calls this in a separate Dart isolate when the foreground service
// starts. @pragma('vm:keep') prevents the tree-shaker from removing it, since
// it is invoked by platform reflection code, not by the main isolate directly.
//
// All real work (socket, location stream, booking listeners) runs in the MAIN
// Flutter isolate. The foreground service's only job is to keep the main
// process alive by holding the "MicroLab — You are Online" notification.
@pragma('vm:keep')
void foregroundTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_ForegroundHandler());
}

class _ForegroundHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    ForegroundService._log('Background Isolate — onStart ✓');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    ForegroundService._log('Background Isolate — onDestroy');
  }
}

// ─── ForegroundService ────────────────────────────────────────────────────────
//
// Manages the "You are Online" persistent notification that keeps the Flutter
// engine alive while the technician's screen is off.
//
// Architecture note:
//   The notification is the only thing running in the background isolate.
//   Socket.IO reconnection, GPS streaming, and booking reception all happen
//   in the main isolate — the foreground service just prevents the OS from
//   killing the main isolate's process.
//
// Samsung / Xiaomi / Oppo compatibility:
//   Battery optimization must be granted BEFORE calling start(). Use
//   BatteryService.ensureStandardExemption() and showOemGuideIfNeeded()
//   before this class is involved. See battery_service.dart.

class ForegroundService {
  ForegroundService._();
  static final ForegroundService instance = ForegroundService._();

  // ── Init ───────────────────────────────────────────────────────────────────

  void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        // 'v2' suffix forces Android to create a fresh channel on existing
        // installs. Android locks channel importance on first creation — the
        // only way to change it afterwards is a new channel ID.
        // DEFAULT importance is required for the status bar icon to appear.
        // LOW channel importance suppresses the icon on Samsung One UI.
        channelId: 'microlab_foreground_v2',
        channelName: 'MicroLab Online Status',
        channelDescription:
            'Keeps your connection alive while you are online for bookings',
        channelImportance: NotificationChannelImportance.DEFAULT,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        // autoRunOnBoot: false — onStart() is empty (all real work is in
        // the main isolate). Setting true would show a ghost notification
        // after reboot with no socket or location running behind it.
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _log('init() ✓ — channel=microlab_foreground_v2  importance=DEFAULT');
  }

  // ── Start ──────────────────────────────────────────────────────────────────
  //
  // Returns true if the service entered RUNNING state (notification visible).
  // Returns false if the service timed out or failed.
  //
  // startService() NEVER throws — it catches all internal exceptions and
  // returns them as ServiceRequestFailure. The only way to know if the
  // service started is to check the returned ServiceRequestResult.
  //
  // Common failure — ServiceTimeoutException:
  //   isRunningService polled every 100 ms for 5 seconds and never became
  //   true. Cause: Samsung/Xiaomi/Oppo OEM battery management killed
  //   ForegroundTaskService before startForeground() could complete inside
  //   onStartCommand(). Fix: grant battery exemption (BatteryService) before
  //   calling start().
  Future<bool> start() async {
    _log('═══════════════════════════════════════════════════');
    _log('Foreground Service Starting...');
    _log('  Channel    : microlab_foreground_v2 (IMPORTANCE_DEFAULT)');
    _log('  Type       : dataSync (Android 14 — no background location required)');
    _log('  Service ID : 1001');
    _log('  autoRunOnBoot : false');
    _log('═══════════════════════════════════════════════════');

    final bool alreadyRunning = await FlutterForegroundTask.isRunningService;
    _log('isRunningService=$alreadyRunning');

    if (alreadyRunning) {
      _log('Stale service detected — stopping before restart');
      final stopResult = await FlutterForegroundTask.stopService();
      if (stopResult is ServiceRequestFailure) {
        _log('stopService FAILED: ${stopResult.error}');
      } else {
        _log('stopService OK ✓');
      }
    }

    _log('Calling startService() — polling isRunningService for up to 5s...');
    final ServiceRequestResult result = await FlutterForegroundTask.startService(
      serviceId: 1001,
      notificationTitle: 'MicroLab — You are Online',
      notificationText: 'Waiting for Booking...',
      callback: foregroundTaskEntryPoint,
    );

    switch (result) {
      case ServiceRequestSuccess():
        _log('Service Running Successfully ✓');
        _log('Notification Channel Created ✓');
        _log('Foreground Notification Displayed ✓');
        _log('Technician Online — Waiting for Booking...');
        return true;

      case ServiceRequestFailure(:final error):
        _log('❌ Foreground Service Failed');
        _log('   Error Type   : ${error.runtimeType}');
        _log('   Error Detail : $error');
        if (error is ServiceTimeoutException) {
          _log('');
          _log('   ServiceTimeoutException — isRunningService never became true');
          _log('   Service never entered RUNNING state within 5 seconds');
          _log('   Battery Restriction Detected — OEM manager killed the service');
          _log('   Fix: Grant battery exemption in phone battery settings');
          _log('   Samsung → Settings → Device Care → Battery → Never sleeping apps');
        } else if (error is ServiceAlreadyStartedException) {
          _log('   Service was already running when startService() was called');
        } else if (error is ServiceNotInitializedException) {
          _log('   init() was not called before start()');
        }
        return false;
    }
  }

  // ── Stop ───────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    _log('Stopping foreground service...');
    if (!await FlutterForegroundTask.isRunningService) {
      _log('stop() — service was not running');
      return;
    }
    final result = await FlutterForegroundTask.stopService();
    if (result is ServiceRequestFailure) {
      _log('stopService FAILED: ${result.error}');
    } else {
      _log('Service Stopped ✓');
    }
  }

  // ── Update notification text ───────────────────────────────────────────────

  Future<void> updateText(String text) async {
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: 'MicroLab — You are Online',
      notificationText: text,
    );
    if (result is ServiceRequestFailure) {
      _log('updateService FAILED: ${result.error}');
    } else {
      _log('Notification updated: "$text"');
    }
  }

  // ── Start with automatic retry ────────────────────────────────────────────
  //
  // Calls start() up to [maxAttempts] times with a 2-second pause between
  // each attempt. Returns true on the first success. Returns false only after
  // all attempts are exhausted.
  //
  // Each attempt polls isRunningService for up to 5 seconds — so worst-case
  // time is  (5s × maxAttempts) + (2s × (maxAttempts-1)) ≈ 19 seconds.
  // This is acceptable for a first-time setup; subsequent toggles typically
  // succeed on the first attempt once battery settings are configured.
  Future<bool> startWithRetry({int maxAttempts = 3}) async {
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      _log('─── Start Attempt $attempt / $maxAttempts ───');
      final success = await start();
      if (success) {
        _log('Service Started on Attempt $attempt ✓');
        return true;
      }
      if (attempt < maxAttempts) {
        _log('Attempt $attempt failed — retrying in 2s...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    _log('❌ All $maxAttempts attempts exhausted — technician stays OFFLINE');
    return false;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Whether the foreground service is currently in RUNNING state.
  Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  /// Open the system Battery Optimization settings list.
  /// Shows all apps — the technician can find MicroLab and select "Don't optimise".
  Future<void> openBatterySettings() =>
      FlutterForegroundTask.openIgnoreBatteryOptimizationSettings();

  static void _log(String msg) {
    if (kDebugMode) {
      final ts = DateTime.now().toIso8601String().substring(11, 23);
      debugPrint('$ts [FGS] $msg');
    }
  }
}
