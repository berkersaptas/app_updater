package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets

/** Backend base URL, app slug, and channel for [OtaUpdateClient]. See `backend/README.md`. */
data class OtaUpdateConfig(
    val baseUrl: String,
    val appSlug: String,
    val channel: String = "stable",
)

sealed class OtaUpdateResult {
    object NoUpdateAvailable : OtaUpdateResult()
    data class Installed(val patchNumber: Int) : OtaUpdateResult()
    data class Failed(val reason: String) : OtaUpdateResult()
}

/**
 * Network update-client implementing `docs/production_installer_contract.md` against the backend
 * in `backend/`. Runs entirely on a background thread and never throws back to the caller: any
 * network/backend failure resolves as [OtaUpdateResult.Failed] so a down or unreachable backend
 * never affects the current boot, matching the contract's "must tolerate backend/CDN
 * unavailability" requirement. Only prepares a patch for the *next* launch — never touches the
 * artifact selected for the current boot ([FlutterOtaRuntime.engineArgsForThisBoot]).
 *
 * Call this only after [FlutterOtaRuntime.markBootSuccess] has returned (e.g. from the same
 * MethodChannel handler, right after reporting boot success), not from `onCreate`/startup
 * directly. This class reads and writes `ota/patch_state.json` on a background thread;
 * `engineArgsForThisBoot`/`markBootSuccess` synchronously mutate that same file earlier in the
 * boot sequence, and calling this any earlier would race those transitions.
 */
class OtaUpdateClient(context: Context) {
    private val appContext = context.applicationContext
    private val stateStore = PatchStateStore(appContext)
    private val badPatchStore = BadPatchStore(appContext)
    private val signatureVerifier = PatchSignatureVerifier(OtaRuntimeConfig.from(appContext))
    private val lifecycleStore = OtaLifecycleStore(appContext)

    fun checkForUpdate(config: OtaUpdateConfig, callback: (OtaUpdateResult) -> Unit) {
        Thread {
            callback(runCheck(config))
        }.start()
    }

    /**
     * Same as [checkForUpdate], but takes `baseUrl`/`appSlug` from [OtaRuntimeConfig] (i.e. from
     * `<meta-data>`, generated at build time from `app_updater.yaml` when consumed through
     * that package) instead of requiring the caller to pass them explicitly.
     */
    fun checkForUpdate(channel: String = "stable", callback: (OtaUpdateResult) -> Unit) {
        val runtimeConfig = OtaRuntimeConfig.from(appContext)
        checkForUpdate(
            OtaUpdateConfig(baseUrl = runtimeConfig.backendUrl, appSlug = runtimeConfig.appSlug, channel = channel),
            callback,
        )
    }

    private fun runCheck(config: OtaUpdateConfig): OtaUpdateResult {
        if (lifecycleStore.circuitOpen()) {
            return OtaUpdateResult.Failed(
                "Circuit breaker open: too many consecutive patch failures; refusing to install a new patch",
            )
        }

        val releaseVersion = installedRelease(appContext)
        val abi = Build.SUPPORTED_ABIS.firstOrNull()
            ?: return OtaUpdateResult.Failed("Device reports no supported ABI")
        val currentPatchNumber = stateStore.read()
            ?.takeIf { it.state == PatchState.STATUS_ACTIVE || it.state == PatchState.STATUS_PENDING }
            ?.patchNumber ?: 0

        val checkResponse = try {
            postJson(
                "${config.baseUrl}/v1/apps/${config.appSlug}/patch-check",
                JSONObject().apply {
                    put("channel", config.channel)
                    put("release_version", releaseVersion)
                    put("current_patch_number", currentPatchNumber)
                    put("platform", "android")
                    put("arch", abi)
                },
            )
        } catch (error: IOException) {
            return OtaUpdateResult.Failed("Patch check request failed: ${error.message}")
        }

        if (!checkResponse.optBoolean("patch_available", false)) {
            return OtaUpdateResult.NoUpdateAvailable
        }
        val patch = checkResponse.optJSONObject("patch")
            ?: return OtaUpdateResult.Failed("patch_available was true but patch was missing")
        val manifest = patch.optJSONObject("manifest")
            ?: return OtaUpdateResult.Failed("Patch response was missing its manifest")
        val patchNumber = manifest.optInt("patch_number", -1)
        if (patchNumber <= 0) return OtaUpdateResult.Failed("Invalid patch_number in manifest")
        if (badPatchStore.contains(patchNumber)) {
            return OtaUpdateResult.Failed("Patch $patchNumber was previously marked bad; refusing to reinstall")
        }
        val downloadUrl = patch.optString("download_url").ifBlank {
            return OtaUpdateResult.Failed("Patch response was missing download_url")
        }
        val artifactKind = manifest.optString("artifact_kind")
        val artifactFileName = if (artifactKind == OtaManifestContract.ARTIFACT_KIND_BINARY_DIFF) {
            OtaManifestContract.ARTIFACT_DIFF_NAME
        } else {
            OtaManifestContract.ARTIFACT_NAME
        }
        val relativePath = "ota/patches/$patchNumber/$artifactFileName"

        postEvent(config, "PatchInstallStarted", patchNumber, releaseVersion, abi)

        val destination = File(appContext.filesDir, relativePath)
        try {
            downloadTo(downloadUrl, destination)
        } catch (error: IOException) {
            postEvent(config, "PatchInstallFailure", patchNumber, releaseVersion, abi)
            return OtaUpdateResult.Failed("Artifact download failed: ${error.message}")
        }

        val expectedSize = manifest.optLong("artifact_size", -1)
        if (expectedSize > 0 && destination.length() != expectedSize) {
            postEvent(config, "PatchInstallFailure", patchNumber, releaseVersion, abi)
            return OtaUpdateResult.Failed(
                "Downloaded artifact size mismatch: expected $expectedSize, got ${destination.length()}",
            )
        }

        val candidate = try {
            manifestToPatchState(manifest, relativePath)
        } catch (error: Exception) {
            postEvent(config, "PatchInstallFailure", patchNumber, releaseVersion, abi)
            return OtaUpdateResult.Failed("Malformed manifest: ${error.message}")
        }

        return PatchInstaller.install(stateStore, candidate, signatureVerifier).fold(
            onSuccess = {
                postEvent(config, "PatchInstallSuccess", patchNumber, releaseVersion, abi)
                OtaUpdateResult.Installed(patchNumber)
            },
            onFailure = { error ->
                postEvent(config, "PatchInstallFailure", patchNumber, releaseVersion, abi)
                OtaUpdateResult.Failed(error.message ?: "Patch installation failed")
            },
        )
    }

    private fun manifestToPatchState(manifest: JSONObject, artifactPath: String) = PatchState(
        schemaVersion = manifest.getInt("schema_version"),
        enabled = true,
        release = manifest.getString("release"),
        patchNumber = manifest.getInt("patch_number"),
        artifactKind = manifest.getString("artifact_kind"),
        artifactPath = artifactPath,
        sha256 = manifest.getString("sha256").lowercase(),
        artifactSize = manifest.optLong("artifact_size", -1),
        engineRevision = manifest.getString("engine_revision"),
        dartVersion = manifest.getString("dart_version"),
        abi = manifest.getString("abi"),
        buildMode = manifest.getString("build_mode"),
        signatureKeyId = manifest.getString("signature_key_id"),
        signatureAlgorithm = manifest.getString("signature_algorithm"),
        signature = manifest.getString("signature"),
        state = PatchState.STATUS_PENDING,
    )

    private fun postEvent(config: OtaUpdateConfig, type: String, patchNumber: Int, release: String, abi: String) {
        try {
            postJson(
                "${config.baseUrl}/v1/apps/${config.appSlug}/events",
                JSONObject().apply {
                    put("platform", "android")
                    put("arch", abi)
                    put("type", type)
                    put("release_version", release)
                    put("patch_number", patchNumber)
                },
            )
        } catch (_: IOException) {
            // Events are best-effort; a failed post must never affect patch install/boot.
        }
    }

    private fun postJson(url: String, body: JSONObject): JSONObject {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.outputStream.use { it.write(body.toString().toByteArray(StandardCharsets.UTF_8)) }

            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() } ?: ""
            if (status !in 200..299) {
                throw IOException("HTTP $status from $url: $text")
            }
            return if (text.isBlank()) JSONObject() else JSONObject(text)
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Resumable download: a `.tmp` staging file left over from a previous interrupted attempt for
     * this same patch is resumed with an HTTP `Range` request rather than re-downloaded from
     * scratch. Safe because [relativePath] is keyed by patch number and a given patch's artifact
     * content never changes after upload (see `backend/`'s admin patch-upload route), so leftover
     * bytes on disk are always a valid prefix of the current artifact. If the server doesn't honor
     * the `Range` request (plain `200` instead of `206`), the staging file is restarted from
     * scratch. The final SHA-256 check already performed at patch-load time (`PatchLoader`,
     * `BinaryDiffArtifactResolver`) remains the safety net against a corrupted resume.
     */
    private fun downloadTo(url: String, destination: File, allowRetryFromScratch: Boolean = true) {
        destination.parentFile?.mkdirs()
        val staging = File(destination.parentFile, "${destination.name}.tmp")
        val resumeFrom = staging.length().takeIf { it > 0 } ?: 0L

        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = DOWNLOAD_READ_TIMEOUT_MS
            if (resumeFrom > 0) {
                connection.setRequestProperty("Range", "bytes=$resumeFrom-")
                Log.i(TAG, "Resuming download of $url from byte $resumeFrom")
            }
            val status = connection.responseCode
            if (status == HTTP_REQUESTED_RANGE_NOT_SATISFIABLE && allowRetryFromScratch) {
                // Our resume offset no longer matches the server (e.g. a stale staging file from an
                // artifact that no longer exists at this offset); discard it and download fresh.
                connection.disconnect()
                staging.delete()
                return downloadTo(url, destination, allowRetryFromScratch = false)
            }
            val append = when (status) {
                HttpURLConnection.HTTP_PARTIAL -> true
                HttpURLConnection.HTTP_OK -> false
                else -> throw IOException("HTTP $status downloading $url")
            }

            connection.inputStream.use { input ->
                java.io.FileOutputStream(staging, append).use { output -> input.copyTo(output) }
            }
            if (!staging.renameTo(destination)) {
                throw IOException("Could not atomically stage downloaded artifact")
            }
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val READ_TIMEOUT_MS = 10_000
        private const val DOWNLOAD_READ_TIMEOUT_MS = 30_000
        private const val HTTP_REQUESTED_RANGE_NOT_SATISFIABLE = 416
        private const val TAG = "OtaUpdateClient"
    }
}
