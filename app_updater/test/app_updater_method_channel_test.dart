import 'package:app_updater/app_updater_method_channel.dart';
import 'package:app_updater/src/ota_update_result.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelAppUpdater();
  const channel = MethodChannel('app_updater');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'markBootSuccess':
              return null;
            case 'checkForUpdate':
              return {'status': 'noUpdateAvailable'};
            case 'status':
              return {
                'state': 'active',
                'patchNumber': 2,
                'failureReason': null,
                'hasLastKnownGood': true,
                'quarantineCount': 0,
                'storedPatchCount': 1,
                'badPatchCount': 0,
              };
            default:
              throw MissingPluginException();
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('markBootSuccess invokes the channel without throwing', () async {
    await platform.markBootSuccess();
  });

  test('checkForUpdate parses a noUpdateAvailable response', () async {
    final result = await platform.checkForUpdate(
      baseUrl: 'https://ota.example.com',
      appSlug: 'my-app-android',
      channel: 'stable',
    );
    expect(result, isA<OtaNoUpdateAvailable>());
  });

  test('checkForUpdate parses a rolledBack response', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (MethodCall methodCall) async => {
            'status': 'rolledBack',
            'patchNumber': 7,
          },
        );

    final result = await platform.checkForUpdate(
      baseUrl: 'https://ota.example.com',
      appSlug: 'my-app-android',
      channel: 'stable',
    );

    expect(result, isA<OtaUpdateRolledBack>());
    expect((result as OtaUpdateRolledBack).patchNumber, 7);
  });

  test('status parses the native status map', () async {
    final status = await platform.status();
    expect(status.state, 'active');
    expect(status.patchNumber, 2);
    expect(status.hasLastKnownGood, isTrue);
  });
}
