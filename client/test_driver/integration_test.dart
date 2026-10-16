// Standard flutter_driver bridge required to run integration_test files on
// a target that needs `flutter drive` instead of `flutter test -d <device>`
// — currently that's the web target here, since `flutter test -d chrome`
// itself reports "Web devices are not supported for integration tests yet."
// (confirmed directly against this project's Flutter 3.41.1 install).
//
// Once a chromedriver/msedgedriver binary matching the installed browser is
// available (see the test report for exactly what's missing), run e.g.:
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/login_flow_web_test.dart \
//     -d chrome \
//     --dart-define=MICROLAB_SERVER_URL=http://localhost:4001
// with server/tests/e2e-web/bootstrapTestServer.js already running on that
// port (see that file's own header).
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
