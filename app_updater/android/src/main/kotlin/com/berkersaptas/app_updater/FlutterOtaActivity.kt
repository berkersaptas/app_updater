package com.berkersaptas.app_updater

import android.content.Context
import com.berkersaptas.app_updater.ota_runtime.FlutterOtaRuntime
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Base `Activity` that selects a verified patched AOT artifact before the Flutter engine (and
 * therefore the Dart VM) starts. Extend this instead of `FlutterActivity`:
 *
 * ```kotlin
 * class MainActivity : FlutterOtaActivity()
 * ```
 *
 * This is the one piece of native code an integrating app still has to write. Everything else
 * (boot-success reporting, update checks) is a normal Dart call through the `app_updater`
 * plugin — Android's Flutter embedding requires the artifact path before the engine exists, which
 * is before any Dart code (including this plugin's own MethodChannel) can run, so it cannot be
 * driven from Dart no matter how the rest of this package is packaged.
 */
abstract class FlutterOtaActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val engineArgs = FlutterOtaRuntime(context).engineArgsForThisBoot()
        return FlutterEngine(context, engineArgs)
    }
}
