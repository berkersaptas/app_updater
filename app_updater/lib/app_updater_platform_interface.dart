import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'app_updater_method_channel.dart';
import 'src/ota_runtime_status.dart';
import 'src/ota_update_result.dart';

abstract class AppUpdaterPlatform extends PlatformInterface {
  AppUpdaterPlatform() : super(token: _token);

  static final Object _token = Object();

  static AppUpdaterPlatform _instance = MethodChannelAppUpdater();

  static AppUpdaterPlatform get instance => _instance;

  static set instance(AppUpdaterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<void> markBootSuccess() {
    throw UnimplementedError('markBootSuccess() has not been implemented.');
  }

  Future<OtaUpdateResult> checkForUpdate({String? baseUrl, String? appSlug, required String channel}) {
    throw UnimplementedError('checkForUpdate() has not been implemented.');
  }

  Future<OtaRuntimeStatus> status() {
    throw UnimplementedError('status() has not been implemented.');
  }
}
