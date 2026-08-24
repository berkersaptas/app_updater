package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile
import io.sigpipe.jbsdiff.Patch as BsPatch

/**
 * Reconstructs a loadable `libapp.so` from the base release's own packaged AOT library plus a
 * bsdiff-format diff blob staged at [PatchState.artifactPath]. The base artifact is never shipped
 * separately: it is read from the installed APK, mirroring what the build-time diff was computed
 * against (see scripts/build_patch.sh). Reconstruction is cached per patch number so repeated boots
 * of an already-applied patch do not re-run bspatch every launch.
 */
internal class BinaryDiffArtifactResolver(
    private val context: Context,
) : PatchArtifactResolver {
    override fun resolve(patch: PatchState): Result<PatchArtifact> =
        runCatching {
            val diffFile = canonicalDiffArtifact(patch)
            require(diffFile.isFile) { "Binary diff artifact does not exist" }

            val reconstructed = File(
                context.filesDir.canonicalFile,
                "ota/patches/${patch.patchNumber}/${OtaManifestContract.ARTIFACT_RECONSTRUCTED_NAME}",
            )
            if (!reconstructed.isFile || !sha256(reconstructed).equals(patch.sha256, ignoreCase = true)) {
                reconstruct(patch, diffFile, reconstructed)
            }

            PatchArtifact(
                loadableAotLibrary = reconstructed,
                kind = OtaManifestContract.ARTIFACT_KIND_BINARY_DIFF,
            )
        }

    private fun reconstruct(patch: PatchState, diffFile: File, reconstructed: File) {
        val baseBytes = readBaseArtifact(patch.abi)
        val diffBytes = diffFile.readBytes()
        val output = ByteArrayOutputStream()
        BsPatch.patch(baseBytes, diffBytes, output)

        reconstructed.parentFile?.mkdirs()
        val staging = File(
            reconstructed.parentFile,
            "${OtaManifestContract.ARTIFACT_RECONSTRUCTED_NAME}.tmp",
        )
        staging.writeBytes(output.toByteArray())
        require(staging.renameTo(reconstructed)) {
            "Could not atomically stage reconstructed binary_diff artifact"
        }
    }

    private fun canonicalDiffArtifact(patch: PatchState): File {
        val configuredPath = File(patch.artifactPath)
        val resolvedPath = if (configuredPath.isAbsolute) {
            configuredPath
        } else {
            File(context.filesDir, patch.artifactPath)
        }
        val canonical = resolvedPath.canonicalFile
        val filesRoot = context.filesDir.canonicalFile
        require(canonical.path.startsWith(filesRoot.path + File.separator)) {
            "Binary diff artifact must be below filesDir"
        }
        return canonical
    }

    /**
     * Reads the base release's own packaged AOT library directly from the installed APK. This
     * assumes the default AGP packaging mode (native libs mapped, not extracted); see
     * engine_notes/phase_2_engine_feasibility.md.
     */
    private fun readBaseArtifact(abi: String): ByteArray {
        val apkPath = context.applicationInfo.sourceDir
        ZipFile(apkPath).use { zip ->
            val entryName = "lib/$abi/${OtaManifestContract.ARTIFACT_NAME}"
            val entry = zip.getEntry(entryName)
                ?: error("Base artifact $entryName not found in installed APK")
            zip.getInputStream(entry).use { return it.readBytes() }
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

internal class UnsupportedPatchArtifactResolver(private val reason: String) : PatchArtifactResolver {
    override fun resolve(patch: PatchState): Result<PatchArtifact> =
        Result.failure(IllegalArgumentException(reason))
}
