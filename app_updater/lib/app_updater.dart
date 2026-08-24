import 'package:flutter/widgets.dart';

import 'app_updater_platform_interface.dart';
import 'src/ota_runtime_status.dart';
import 'src/ota_update_result.dart';

export 'src/ota_runtime_status.dart';
export 'src/ota_update_result.dart';

/// Dart-facing API for the self-hosted OTA code-push system implemented in `ota_runtime_android`
/// and `backend/`. See the package README for the one native touch point ([FlutterOtaActivity])
/// this still requires and why.
///
/// `baseUrl`/`appSlug` are optional everywhere in this API: when omitted, the native side reads
/// them from `<flutter-project-root>/app_updater.yaml`, generated into `<meta-data>` at build
/// time. There is nothing else to configure per platform — pass them explicitly only to override
/// the config file (e.g. pointing a debug build at a different backend).
class AppUpdater {
  AppUpdater._();

  /// The single instance of this API, matching how most Flutter plugins in this style expose
  /// themselves (e.g. `FirebaseAuth.instance`).
  static final AppUpdater instance = AppUpdater._();

  /// Reports that this boot's patch (if any) rendered successfully. Must be called before
  /// [checkForUpdate] — prefer [autoUpdate] over calling this directly unless you need to report
  /// boot success without also checking for a new patch.
  Future<void> markBootSuccess() => AppUpdaterPlatform.instance.markBootSuccess();

  /// Checks the backend for a newer patch and, if one exists, downloads, verifies, and stages it
  /// as `pending` for the *next* launch. Never throws for network/backend failures — those come
  /// back as [OtaUpdateFailed] so a down or unreachable backend never affects the app.
  ///
  /// Must be called only after [markBootSuccess] (or after [autoUpdate], which sequences this
  /// correctly for you) — calling it any earlier races this boot's own patch-selection state
  /// writes. See `ota_runtime_android`'s `OtaUpdateClient` doc comment for why.
  Future<OtaUpdateResult> checkForUpdate({String? baseUrl, String? appSlug, String channel = 'stable'}) =>
      AppUpdaterPlatform.instance.checkForUpdate(baseUrl: baseUrl, appSlug: appSlug, channel: channel);

  /// Local patch lifecycle snapshot (current state, last-known-good, quarantine/bad-patch counts).
  Future<OtaRuntimeStatus> status() => AppUpdaterPlatform.instance.status();

  /// Convenience entrypoint: after the first frame renders, reports boot success and then checks
  /// for an update, in the correct order, exactly once. Call this once in `main()`, before or
  /// after `runApp` — it schedules itself via [WidgetsBinding.addPostFrameCallback]:
  ///
  /// ```dart
  /// void main() {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   AppUpdater.instance.autoUpdate();
  ///   runApp(const MyApp());
  /// }
  /// ```
  ///
  /// [onResult] is optional and only for logging/telemetry — do not block app behavior on it.
  void autoUpdate({
    String? baseUrl,
    String? appSlug,
    String channel = 'stable',
    void Function(OtaUpdateResult result)? onResult,
    void Function(Object error)? onError,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await markBootSuccess();
        final result = await checkForUpdate(baseUrl: baseUrl, appSlug: appSlug, channel: channel);
        onResult?.call(result);
      } catch (error) {
        onError?.call(error);
      }
    });
  }
}
