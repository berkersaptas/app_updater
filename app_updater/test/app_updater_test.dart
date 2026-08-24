import 'package:app_updater/app_updater.dart';
import 'package:app_updater/app_updater_method_channel.dart';
import 'package:app_updater/app_updater_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockAppUpdaterPlatform
    with MockPlatformInterfaceMixin
    implements AppUpdaterPlatform {
  bool bootSuccessReported = false;

  @override
  Future<void> markBootSuccess() async {
    bootSuccessReported = true;
  }

  @override
  Future<OtaUpdateResult> checkForUpdate({
    String? baseUrl,
    String? appSlug,
    required String channel,
  }) => Future.value(const OtaUpdateInstalled(2));

  @override
  Future<OtaRuntimeStatus> status() => Future.value(
    const OtaRuntimeStatus(
      state: 'active',
      patchNumber: 2,
      failureReason: null,
      hasLastKnownGood: true,
      quarantineCount: 0,
      storedPatchCount: 1,
      badPatchCount: 0,
      circuitOpen: false,
    ),
  );
}

void main() {
  final AppUpdaterPlatform initialPlatform =
      AppUpdaterPlatform.instance;

  test('$MethodChannelAppUpdater is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelAppUpdater>());
  });

  test('checkForUpdate delegates to the platform implementation', () async {
    final fakePlatform = MockAppUpdaterPlatform();
    AppUpdaterPlatform.instance = fakePlatform;

    final result = await AppUpdater.instance.checkForUpdate(
      baseUrl: 'https://ota.example.com',
      appSlug: 'my-app-android',
    );

    expect(result, isA<OtaUpdateInstalled>());
    expect((result as OtaUpdateInstalled).patchNumber, 2);
  });

  test('status delegates to the platform implementation', () async {
    final fakePlatform = MockAppUpdaterPlatform();
    AppUpdaterPlatform.instance = fakePlatform;

    final status = await AppUpdater.instance.status();

    expect(status.state, 'active');
    expect(status.patchNumber, 2);
  });
}
