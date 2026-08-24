package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.util.AtomicFile
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

internal class OtaLifecycleStore(context: Context) {
    private val otaRoot = File(context.filesDir, "ota")
    private val patchesRoot = File(otaRoot, "patches")
    private val quarantineRoot = File(otaRoot, "quarantine")
    private val lastKnownGoodFile = AtomicFile(File(otaRoot, "last_known_good.json"))
    private val circuitBreakerFile = AtomicFile(File(otaRoot, "circuit_breaker.json"))

    fun recordLastKnownGood(state: PatchState) {
        writeAtomic(lastKnownGoodFile, state)
    }

    /**
     * Cross-patch circuit breaker, distinct from [BadPatchStore]'s permanent per-patch blacklist:
     * protects against a build pipeline that keeps pushing broken patches (which would otherwise
     * crash-once-per-relaunch indefinitely, one blacklisted patch number at a time). Trips after
     * [CIRCUIT_BREAKER_FAILURE_THRESHOLD] consecutive [PatchLoader] failures; resets on the next
     * successful boot, or automatically half-opens after [CIRCUIT_BREAKER_COOLDOWN_MILLIS] so a
     * fixed pipeline recovers without manual intervention.
     */
    fun recordFailure() {
        val current = readCircuitBreaker()
        writeCircuitBreaker(
            CircuitBreakerState(
                consecutiveFailures = current.consecutiveFailures + 1,
                lastFailureAtMillis = System.currentTimeMillis(),
            ),
        )
    }

    fun recordSuccess() {
        writeCircuitBreaker(CircuitBreakerState(consecutiveFailures = 0, lastFailureAtMillis = 0))
    }

    fun circuitOpen(now: Long = System.currentTimeMillis()): Boolean {
        val state = readCircuitBreaker()
        return state.consecutiveFailures >= CIRCUIT_BREAKER_FAILURE_THRESHOLD &&
            now - state.lastFailureAtMillis < CIRCUIT_BREAKER_COOLDOWN_MILLIS
    }

    private fun readCircuitBreaker(): CircuitBreakerState {
        if (!circuitBreakerFile.baseFile.isFile) return CircuitBreakerState(0, 0)
        return try {
            circuitBreakerFile.openRead().bufferedReader().use {
                val json = JSONObject(it.readText())
                CircuitBreakerState(
                    consecutiveFailures = json.optInt("consecutive_failures", 0),
                    lastFailureAtMillis = json.optLong("last_failure_at_millis", 0),
                )
            }
        } catch (error: Exception) {
            Log.e(TAG, "Ignoring invalid circuit breaker state", error)
            CircuitBreakerState(0, 0)
        }
    }

    private fun writeCircuitBreaker(state: CircuitBreakerState) {
        circuitBreakerFile.baseFile.parentFile?.mkdirs()
        var output: FileOutputStream? = null
        try {
            output = circuitBreakerFile.startWrite()
            val json = JSONObject().apply {
                put("consecutive_failures", state.consecutiveFailures)
                put("last_failure_at_millis", state.lastFailureAtMillis)
            }
            output.write(json.toString(2).toByteArray(Charsets.UTF_8))
            circuitBreakerFile.finishWrite(output)
        } catch (error: Exception) {
            output?.let(circuitBreakerFile::failWrite)
            throw error
        }
    }

    private data class CircuitBreakerState(val consecutiveFailures: Int, val lastFailureAtMillis: Long)

    fun quarantine(state: PatchState, reason: String) {
        try {
            val source = File(state.artifactPath).let {
                if (it.isAbsolute) it else File(otaRoot.parentFile, state.artifactPath)
            }.canonicalFile
            val patchesCanonical = patchesRoot.canonicalFile
            if (!source.isFile || !source.path.startsWith(patchesCanonical.path + File.separator)) {
                return
            }

            val quarantineDirectory = File(
                quarantineRoot,
                "${state.patchNumber}-${System.currentTimeMillis()}",
            )
            check(quarantineDirectory.mkdirs()) { "Could not create quarantine directory" }
            val quarantinedArtifact = File(quarantineDirectory, source.name)
            if (!source.renameTo(quarantinedArtifact)) {
                source.copyTo(quarantinedArtifact, overwrite = true)
                check(source.delete()) { "Could not remove failed artifact after copying" }
            }
            val failure = state.withStatus(PatchState.STATUS_FAILED, reason).copy(
                artifactPath = quarantinedArtifact.absolutePath,
            )
            File(quarantineDirectory, "failure.json").writeText(
                failure.toJson().toString(2),
                Charsets.UTF_8,
            )
            source.parentFile?.delete()
        } catch (error: Exception) {
            Log.e(TAG, "Could not quarantine failed patch ${state.patchNumber}", error)
        }
    }

    fun cleanup(currentState: PatchState?) {
        val lastKnownGood = readLastKnownGood()
        val preservedPatchNumbers = setOfNotNull(
            currentState?.takeIf { it.state == PatchState.STATUS_ACTIVE }?.patchNumber,
            lastKnownGood?.patchNumber,
        ).map(Int::toString).toSet()

        patchesRoot.listFiles()
            ?.filter { it.isDirectory && it.name !in preservedPatchNumbers && !hasInProgressDownload(it) }
            ?.forEach(File::deleteRecursively)

        quarantineRoot.listFiles()
            ?.filter(File::isDirectory)
            ?.sortedByDescending(File::lastModified)
            ?.drop(MAX_QUARANTINE_ENTRIES)
            ?.forEach(File::deleteRecursively)
    }

    // markBootSuccess() runs this cleanup on every boot, before OtaUpdateClient.checkForUpdate()
    // gets a chance to run — without this exemption, a `.tmp` staged by an interrupted download
    // for a not-yet-active patch would be deleted here before the network client could ever resume
    // it, making resume unreachable in the exact scenario it exists for.
    private fun hasInProgressDownload(directory: File) =
        directory.listFiles()?.any { it.name.endsWith(".tmp") } == true

    fun hasLastKnownGood() = lastKnownGoodFile.baseFile.isFile

    fun quarantineCount() = quarantineRoot.listFiles()
        ?.count(File::isDirectory) ?: 0

    fun storedPatchCount() = patchesRoot.listFiles()
        ?.count { directory ->
            directory.isDirectory && STORED_ARTIFACT_NAMES.any { File(directory, it).isFile }
        } ?: 0

    private fun readLastKnownGood(): PatchState? {
        if (!lastKnownGoodFile.baseFile.isFile) return null
        return try {
            lastKnownGoodFile.openRead().bufferedReader().use {
                PatchState.fromJson(JSONObject(it.readText()))
            }
        } catch (error: Exception) {
            Log.e(TAG, "Ignoring invalid last-known-good metadata", error)
            null
        }
    }

    private fun writeAtomic(file: AtomicFile, state: PatchState) {
        file.baseFile.parentFile?.mkdirs()
        var output: FileOutputStream? = null
        try {
            output = file.startWrite()
            output.write(state.toJson().toString(2).toByteArray(Charsets.UTF_8))
            file.finishWrite(output)
        } catch (error: Exception) {
            output?.let(file::failWrite)
            throw error
        }
    }

    companion object {
        private const val TAG = "OtaLifecycleStore"
        private const val MAX_QUARANTINE_ENTRIES = 5
        private const val CIRCUIT_BREAKER_FAILURE_THRESHOLD = 3
        private const val CIRCUIT_BREAKER_COOLDOWN_MILLIS = 6 * 60 * 60 * 1000L
        private val STORED_ARTIFACT_NAMES = setOf(
            OtaManifestContract.ARTIFACT_NAME,
            OtaManifestContract.ARTIFACT_DIFF_NAME,
            OtaManifestContract.ARTIFACT_RECONSTRUCTED_NAME,
        )
    }
}
