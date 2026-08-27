package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

internal class PatchLoader(private val context: Context, private val store: PatchStateStore) {
    private val config = OtaRuntimeConfig.from(context)
    private val lifecycle = OtaLifecycleStore(context)
    private val badPatches = BadPatchStore(context)
    private val signatureVerifier = PatchSignatureVerifier(config)

    fun artifactForThisBoot(): File? {
        val patch = store.read() ?: return null
        if (!patch.enabled || patch.state in setOf(
                PatchState.STATUS_NONE,
                PatchState.STATUS_FAILED,
                PatchState.STATUS_DISABLED,
            )
        ) return null

        if (badPatches.contains(patch.patchNumber)) {
            fail(patch, "Patch number was marked bad", markBad = false)
            return null
        }

        if (patch.state == PatchState.STATUS_PENDING_BOOT) {
            fail(patch, "Previous patched boot did not report success", markBad = true)
            return null
        }

        if (!signatureVerifier.verify(patch)) {
            fail(patch, "Patch signature mismatch")
            return null
        }

        compatibilityFailure(patch)?.let { reason ->
            fail(patch, reason)
            return null
        }

        val artifact = artifactResolverFor(patch).resolve(patch).getOrElse { error ->
            fail(patch, error.message ?: "Artifact cannot be resolved")
            return null
        }

        val actualHash = sha256(artifact.loadableAotLibrary)
        if (!actualHash.equals(patch.sha256, ignoreCase = true)) {
            fail(patch, "SHA-256 mismatch")
            return null
        }

        store.write(patch.withStatus(PatchState.STATUS_PENDING_BOOT))
        Log.i(
            TAG,
            "Verified ${artifact.kind} patch ${patch.patchNumber}; attempting patched boot",
        )
        return artifact.loadableAotLibrary
    }

    fun markBootSuccess() {
        val patch = store.read() ?: return
        if (patch.enabled && patch.state == PatchState.STATUS_PENDING_BOOT) {
            val activePatch = patch.withStatus(PatchState.STATUS_ACTIVE)
            store.write(activePatch)
            lifecycle.recordLastKnownGood(activePatch)
            lifecycle.recordSuccess()
            lifecycle.cleanup(activePatch)
            Log.i(TAG, "Patch ${patch.patchNumber} is active")
        }
    }

    /**
     * Called by [BootWatchdog] when a patched boot never confirms within the watchdog timeout
     * (main thread hung/deadlocked rather than crashed, so the process-restart-based
     * [STATUS_PENDING_BOOT] detection above never gets a chance to run). Only takes effect if
     * [patch] is still the current, still-pending-boot state — a no-op if boot already succeeded
     * or a different patch is now current.
     */
    fun failStuckBoot(patch: PatchState, reason: String) {
        val current = store.read() ?: return
        if (current.patchNumber == patch.patchNumber && current.state == PatchState.STATUS_PENDING_BOOT) {
            fail(current, reason, markBad = true)
        }
    }

    private fun fail(patch: PatchState, reason: String, markBad: Boolean = false) {
        if (markBad) badPatches.markBad(patch.patchNumber, reason)
        lifecycle.quarantine(patch, reason)
        store.write(patch.withStatus(PatchState.STATUS_FAILED, reason))
        lifecycle.recordFailure()
        lifecycle.cleanup(null)
        Log.e(TAG, "Patch ${patch.patchNumber} disabled: $reason")
    }

    private fun artifactResolverFor(patch: PatchState): PatchArtifactResolver =
        when (patch.artifactKind) {
            OtaManifestContract.ARTIFACT_KIND_FULL_AOT_LIBRARY ->
                FullAotLibraryArtifactResolver(context)
            OtaManifestContract.ARTIFACT_KIND_BINARY_DIFF ->
                BinaryDiffArtifactResolver(context)
            else -> UnsupportedPatchArtifactResolver("Unsupported artifact kind: ${patch.artifactKind}")
        }

    private fun compatibilityFailure(patch: PatchState): String? {
        val installedRelease = installedRelease(context)
        val basicFailure = when {
            patch.otaProtocolVersion != OtaManifestContract.OTA_PROTOCOL_VERSION ->
                "OTA protocol mismatch: patch=${patch.otaProtocolVersion}, app=${OtaManifestContract.OTA_PROTOCOL_VERSION}"
            patch.release != installedRelease ->
                "Base release mismatch: patch=${patch.release}, app=$installedRelease"
            patch.engineRevision != config.engineRevision ->
                "Flutter engine mismatch: patch=${patch.engineRevision}, app=${config.engineRevision}"
            patch.dartVersion != config.dartVersion ->
                "Dart version mismatch: patch=${patch.dartVersion}, app=${config.dartVersion}"
            patch.buildMode != config.buildMode ->
                "Build mode mismatch: patch=${patch.buildMode}, app=${config.buildMode}"
            Build.SUPPORTED_ABIS.firstOrNull() != patch.abi ->
                "ABI mismatch: patch=${patch.abi}, device=${Build.SUPPORTED_ABIS.firstOrNull()}"
            else -> null
        }
        if (basicFailure != null) return basicFailure

        val identity = InstalledBuildIdentity.resolve(
            context,
            installedRelease,
            config.engineRevision,
            config.dartVersion,
            patch.abi,
            config.buildMode,
        ) ?: return "Base libapp.so identity could not be determined"
        return when {
            patch.baseSha256 != identity.baseSha256 ->
                "Base libapp.so mismatch: patch=${patch.baseSha256}, app=${identity.baseSha256}"
            patch.buildFingerprint != identity.fingerprint ->
                "Build fingerprint mismatch: patch=${patch.buildFingerprint}, app=${identity.fingerprint}"
            else -> null
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    companion object {
        private const val TAG = "OtaPatchLoader"
    }
}
