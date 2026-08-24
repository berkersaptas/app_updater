// This is a basic Flutter integration test.
//
// Since integration tests run in a full Flutter application, they can interact
// with the host side of a plugin implementation, unlike Dart unit tests.
//
// For more information about Flutter integration tests, please see
// https://flutter.dev/to/integration-testing

import 'package:app_updater/app_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('status reaches the native side and returns', (WidgetTester tester) async {
    final status = await AppUpdater.instance.status();
    // No patch installed on a fresh test run: state should be null/none, not an exception.
    expect(status.quarantineCount, greaterThanOrEqualTo(0));
  });
}
