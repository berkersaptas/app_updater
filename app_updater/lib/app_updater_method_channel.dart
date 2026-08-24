import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_updater_platform_interface.dart';
import 'src/ota_runtime_status.dart';
import 'src/ota_update_result.dart';

/// An implementation of [AppUpdaterPlatform] that uses method channels.
class MethodChannelAppUpdater extends AppUpdaterPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('app_updater');

  @override
  Future<void> markBootSuccess() async {
    await methodChannel.invokeMethod<void>('markBootSuccess');
  }

  @override
  Future<OtaUpdateResult> checkForUpdate({String? baseUrl, String? appSlug, required String channel}) async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>(
      'checkForUpdate',
      {'baseUrl': baseUrl, 'appSlug': appSlug, 'channel': channel},
    );
    return OtaUpdateResult.fromChannelMap(result!);
  }

  @override
  Future<OtaRuntimeStatus> status() async {
    final result = await methodChannel.invokeMapMethod<Object?, Object?>('status');
    return OtaRuntimeStatus.fromChannelMap(result!);
  }
}
