package com.berkersaptas.app_updater_sample

import com.berkersaptas.app_updater.FlutterOtaActivity

/**
 * Boot-time patched-AOT-artifact selection is the one native touch point app_updater still
 * requires (Android's Flutter embedding needs it before the Dart VM starts). Everything else —
 * reporting boot success, checking for updates — is driven from Dart; see lib/app.dart.
 */
class MainActivity : FlutterOtaActivity()
