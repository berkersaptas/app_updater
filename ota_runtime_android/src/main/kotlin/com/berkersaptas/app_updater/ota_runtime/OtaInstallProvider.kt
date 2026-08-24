package com.berkersaptas.app_updater.ota_runtime

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/** Shell-only ingress used to place POC artifacts in app-private storage. */
class OtaInstallProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val appContext = requireNotNull(context)
        val segments = uri.pathSegments
        if (mode == "r" && segments == listOf(OtaManifestContract.STATE_PATH)) {
            val state = File(appContext.filesDir, "ota/patch_state.json")
            if (!state.isFile) throw FileNotFoundException("No patch state")
            return ParcelFileDescriptor.open(state, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        val writableNames = setOf(
            OtaManifestContract.ARTIFACT_NAME,
            OtaManifestContract.ARTIFACT_DIFF_NAME,
            // `.tmp` staging names are writable too, so acceptance tests can plant a truncated
            // partial download and exercise OtaUpdateClient's resume path on a real device.
            "${OtaManifestContract.ARTIFACT_NAME}.tmp",
            "${OtaManifestContract.ARTIFACT_DIFF_NAME}.tmp",
        )
        if (mode == "r" && segments.size == 3 && segments[0] == "patches" &&
            segments[1].toIntOrNull() != null && segments[2] in writableNames
        ) {
            val target = File(appContext.filesDir, "ota/patches/${segments[1]}/${segments[2]}")
            if (!target.isFile) throw FileNotFoundException("No such staged artifact: $target")
            return ParcelFileDescriptor.open(target, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        if (mode != "w" || segments.size != 3 || segments[0] != "patches" ||
            segments[1].toIntOrNull() == null ||
            segments[2] !in writableNames
        ) {
            throw FileNotFoundException(
                "Expected writable /patches/<number>/${OtaManifestContract.ARTIFACT_NAME} or " +
                    "/patches/<number>/${OtaManifestContract.ARTIFACT_DIFF_NAME} (optionally with a " +
                    "trailing .tmp for staging)",
            )
        }

        val target = File(
            appContext.filesDir,
            "ota/patches/${segments[1]}/${segments[2]}",
        )
        target.parentFile?.mkdirs()
        return ParcelFileDescriptor.open(
            target,
            ParcelFileDescriptor.MODE_CREATE or
                ParcelFileDescriptor.MODE_TRUNCATE or
                ParcelFileDescriptor.MODE_WRITE_ONLY,
        )
    }

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        if (method == OtaManifestContract.METHOD_LIFECYCLE_STATUS) {
            val status = FlutterOtaRuntime(requireNotNull(context)).status()
            return Bundle().apply {
                putBoolean("last_known_good", status.hasLastKnownGood)
                putInt("quarantine_count", status.quarantineCount)
                putInt("stored_patch_count", status.storedPatchCount)
                putInt("bad_patch_count", status.badPatchCount)
            }
        }
        if (method == OtaManifestContract.METHOD_RESET) {
            val otaDirectory = File(requireNotNull(context).filesDir, "ota")
            check(!otaDirectory.exists() || otaDirectory.deleteRecursively()) {
                "Could not reset the POC OTA directory"
            }
            return Bundle().apply { putBoolean("reset", true) }
        }
        if (method != OtaManifestContract.METHOD_ACTIVATE || arg == null) {
            throw IllegalArgumentException(
                "Expected activate with release~patchNumber~artifactKind~sha256~engine~dart~abi~mode~keyId~algorithm~signature",
            )
        }
        val fields = arg.split('~')
        val patchNumber = fields.getOrNull(1)?.toIntOrNull()
        val artifactKind = fields.getOrNull(2)
        val sha256 = fields.getOrNull(3)
        require(fields.size == 11 && fields[0].isNotBlank() && patchNumber != null)
        require(
            artifactKind == OtaManifestContract.ARTIFACT_KIND_FULL_AOT_LIBRARY ||
                artifactKind == OtaManifestContract.ARTIFACT_KIND_BINARY_DIFF,
        )
        require(sha256?.matches(Regex("[0-9a-fA-F]{64}")) == true)
        require(fields.drop(4).all(String::isNotBlank))

        val artifactFileName = if (artifactKind == OtaManifestContract.ARTIFACT_KIND_BINARY_DIFF) {
            OtaManifestContract.ARTIFACT_DIFF_NAME
        } else {
            OtaManifestContract.ARTIFACT_NAME
        }
        val appContext = requireNotNull(context)
        val artifactRelativePath = "ota/patches/$patchNumber/$artifactFileName"
        // The debug provider's caller (e.g. scripts/install_patch_artifact.sh) already staged the
        // artifact via a prior `content write` before calling activate — derive the size from that
        // real file rather than requiring a new caller-supplied field for this test-only path.
        val stagedArtifact = File(appContext.filesDir, artifactRelativePath)
        val artifactSize = if (stagedArtifact.isFile) stagedArtifact.length() else -1L
        val patch = PatchState(
            enabled = true,
            release = fields[0],
            patchNumber = patchNumber,
            artifactKind = artifactKind,
            artifactPath = artifactRelativePath,
            sha256 = sha256.lowercase(),
            artifactSize = artifactSize,
            engineRevision = fields[4],
            dartVersion = fields[5],
            abi = fields[6],
            buildMode = fields[7],
            signatureKeyId = fields[8],
            signatureAlgorithm = fields[9],
            signature = fields[10],
            state = PatchState.STATUS_PENDING,
        )
        val store = PatchStateStore(appContext)
        val verifier = PatchSignatureVerifier(OtaRuntimeConfig.from(appContext))
        PatchInstaller.install(store, patch, verifier).getOrThrow()
        return Bundle().apply { putBoolean("installed", true) }
    }

    override fun getType(uri: Uri): String = "application/x-elf"
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
        val segments = uri.pathSegments
        if (segments.size != 3 || segments[0] != "patches" ||
            segments[1].toIntOrNull() == null ||
            segments[2] !in setOf(OtaManifestContract.ARTIFACT_NAME, OtaManifestContract.ARTIFACT_DIFF_NAME)
        ) return 0
        val target = File(
            requireNotNull(context).filesDir,
            "ota/patches/${segments[1]}/${segments[2]}",
        )
        return if (target.delete()) 1 else 0
    }

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ) = 0
}
