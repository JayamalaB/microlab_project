import Flutter
import UIKit
import UserNotifications
import GoogleMaps
import flutter_foreground_task

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GMSServices.provideAPIKey("AIzaSyBIGPfna9mxSXpAJOhp0xigKhyZeeU0L0I")
    // flutter_foreground_task runs its task in a separate engine; register
    // plugins there too.
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Let flutter_local_notifications / flutter_foreground_task receive
    // notification callbacks while the app is in the foreground.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    // With the UIScene lifecycle the firebase_messaging plugin is registered
    // after launch and misses its own registerForRemoteNotifications() call,
    // so the APNs token never arrives. Request it here explicitly.
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "MicroLabBookingAction") {
      let channel = FlutterMethodChannel(
        name: "microlab/booking_action", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "takePendingAction" else {
          result(FlutterMethodNotImplemented)
          return
        }
        result(self?.pendingBookingAction)
        self?.pendingBookingAction = nil
      }
      bookingActionChannel = channel
    }
  }

  // ── Booking request push: Accept / Decline buttons and tap (iOS) ──────────
  // The server's booking_request push carries aps.category = BOOKING_REQUEST,
  // which shows the Accept / Decline buttons registered in Dart
  // (NotificationService.initialize). firebase_messaging does not report which
  // button was pressed, so catch the response here, keep it until Dart takes
  // it (also covers a cold start from a killed app), and nudge Dart if it is
  // already running. Dart then runs the same handler as the Android
  // notification (BookingNotificationService.handleNotificationAction).
  private var pendingBookingAction: [String: Any]?
  private var bookingActionChannel: FlutterMethodChannel?

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let request = response.notification.request
    // Remote pushes only — local notifications go through flutter_local_notifications.
    if request.trigger is UNPushNotificationTrigger,
       request.content.categoryIdentifier == "BOOKING_REQUEST" {
      var action: String?
      switch response.actionIdentifier {
      case "accept_booking", "decline_booking": action = response.actionIdentifier
      case UNNotificationDefaultActionIdentifier: action = "tap"
      default: action = nil
      }
      if let action = action {
        // FCM data fields arrive as top-level string keys; drop aps/gcm/google keys.
        var data: [String: String] = [:]
        for (key, value) in request.content.userInfo {
          guard let k = key as? String, let v = value as? String,
                k != "aps", !k.hasPrefix("gcm."), !k.hasPrefix("google.") else { continue }
          data[k] = v
        }
        pendingBookingAction = ["action": action, "data": data]
        bookingActionChannel?.invokeMethod("bookingActionAvailable", arguments: nil)
      }
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }
}
