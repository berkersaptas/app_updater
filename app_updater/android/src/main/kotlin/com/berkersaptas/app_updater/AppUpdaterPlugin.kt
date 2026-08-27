package com.berkersaptas.app_updater

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.berkersaptas.app_updater.ota_runtime.FlutterOtaRuntime
import com.berkersaptas.app_updater.ota_runtime.OtaUpdateClient
import com.berkersaptas.app_updater.ota_runtime.OtaUpdateConfig
import com.berkersaptas.app_updater.ota_runtime.OtaUpdateResult
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Dart-facing bridge for `ota_runtime_android`. Apps consume this plugin, not the native module
 * directly — the only native code an integrating app still needs to write is
 * [FlutterOtaActivity], because Android's Flutter embedding requires the patched AOT library path
 * before the Dart VM (and therefore this plugin's MethodChannel) exists. Everything reachable after
 * that point (boot-success reporting, update checks) is a normal Dart API call.
 */
class AppUpdaterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var appContext: Context
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app_updater")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "markBootSuccess" -> markBootSuccess(result)
            "checkForUpdate" -> checkForUpdate(call, result)
            "status" -> status(result)
            else -> result.notImplemented()
        }
    }

    private fun markBootSuccess(result: Result) {
        try {
            FlutterOtaRuntime(appContext).markBootSuccess()
            result.success(null)
        } catch (error: Exception) {
            result.error("mark_boot_success_failed", error.message, null)
        }
    }

    private fun checkForUpdate(call: MethodCall, result: Result) {
        val baseUrl = call.argument<String>("baseUrl")
        val appSlug = call.argument<String>("appSlug")
        val channelName = call.argument<String>("channel") ?: "stable"
        val client = OtaUpdateClient(appContext)
        val onResult: (OtaUpdateResult) -> Unit = { updateResult ->
            mainHandler.post { result.success(updateResult.toChannelMap()) }
        }

        // baseUrl/appSlug are optional from Dart: when omitted, OtaUpdateClient falls back to
        // <flutter-project-root>/app_updater.yaml's values (baked into <meta-data> at build
        // time), which is the normal path — see app_updater/README.md.
        if (baseUrl.isNullOrBlank() && appSlug.isNullOrBlank()) {
            client.checkForUpdate(channel = channelName, callback = onResult)
        } else if (!baseUrl.isNullOrBlank() && !appSlug.isNullOrBlank()) {
            client.checkForUpdate(
                OtaUpdateConfig(baseUrl = baseUrl, appSlug = appSlug, channel = channelName),
                onResult,
            )
        } else {
            result.error("invalid_arguments", "baseUrl and appSlug must both be set or both omitted", null)
        }
    }

    private fun status(result: Result) {
        val status = FlutterOtaRuntime(appContext).status()
        result.success(
            mapOf(
                "state" to status.state,
                "patchNumber" to status.patchNumber,
                "failureReason" to status.failureReason,
                "hasLastKnownGood" to status.hasLastKnownGood,
                "quarantineCount" to status.quarantineCount,
                "storedPatchCount" to status.storedPatchCount,
                "badPatchCount" to status.badPatchCount,
                "circuitOpen" to status.circuitOpen,
            ),
        )
    }

    private fun OtaUpdateResult.toChannelMap(): Map<String, Any?> = when (this) {
        is OtaUpdateResult.NoUpdateAvailable -> mapOf("status" to "noUpdateAvailable")
        is OtaUpdateResult.Installed -> mapOf("status" to "installed", "patchNumber" to patchNumber)
        is OtaUpdateResult.RolledBack -> mapOf("status" to "rolledBack", "patchNumber" to patchNumber)
        is OtaUpdateResult.Failed -> mapOf("status" to "failed", "reason" to reason)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
