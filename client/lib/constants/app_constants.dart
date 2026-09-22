class AppConstants {
  // Compile-time override so automated tests can point the app at a local
  // test server instead of production, without touching this file per run:
  //   flutter test integration_test/foo.dart -d chrome \
  //     --dart-define=MICROLAB_SERVER_URL=http://localhost:PORT
  // Omitting the flag (every normal build/run) keeps the exact production
  // URL below — this is a test-infrastructure addition, not a behavior
  // change. Added for the automated integration-testing effort; see the
  // test report for how it's used.
  static const String serverUrl = String.fromEnvironment(
    'MICROLAB_SERVER_URL',
    defaultValue: 'https://microlab.neuralarc.com', // Node.js — booking, socket, OTP
  );
  static const String phpServerUrl = 'https://jayamala.neuralarc.com'; // PHP — user registry
  static const String socketUrl    = serverUrl;
  static const String googleMapsApiKey = 'AIzaSyBIGPfna9mxSXpAJOhp0xigKhyZeeU0L0I';

  // How often the technician pings location while on an active job
  static const int locationPingSeconds = 5;

  // How often the technician pings while idle (logged in but no active job)
  static const int idlePingSeconds = 30;

  // Seconds each booking request alarm stays on screen before timing out
  static const int bookingRequestTimeoutSeconds = 40;

  // Max time to wait for a technician before showing "not found" to customer
  static const int bookingSearchTimeoutSeconds = 400;
}
