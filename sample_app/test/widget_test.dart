import 'package:flutter_test/flutter_test.dart';
import 'package:app_updater_sample/app.dart';

void main() {
  testWidgets('renders the selected release message', (tester) async {
    await tester.pumpWidget(const OtaDemoApp(message: 'Hello v1'));

    expect(find.text('Hello v1'), findsOneWidget);
    expect(find.text('Hello v2'), findsNothing);
  });
}
