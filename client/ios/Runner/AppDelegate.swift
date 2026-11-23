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
  }
}
