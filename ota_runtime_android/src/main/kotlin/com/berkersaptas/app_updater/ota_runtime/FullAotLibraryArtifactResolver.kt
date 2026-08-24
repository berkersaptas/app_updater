package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import java.io.File

internal class FullAotLibraryArtifactResolver(private val context: Context) : PatchArtifactResolver {
    override fun resolve(patch: PatchState): Result<PatchArtifact> =
        runCatching {
            val artifact = canonicalArtifact(patch)
            val filesRoot = context.filesDir.canonicalFile
            val isInsideFiles = artifact.path.startsWith(filesRoot.path + File.separator)
            require(isInsideFiles && artifact.extension == "so") {
                "Artifact must be a .so file below filesDir"
            }
            require(artifact.isFile) { "Artifact does not exist" }
            PatchArtifact(
                loadableAotLibrary = artifact,
                kind = OtaManifestContract.ARTIFACT_KIND_FULL_AOT_LIBRARY,
            )
        }

    private fun canonicalArtifact(patch: PatchState): File {
        val configuredPath = File(patch.artifactPath)
        val resolvedPath = if (configuredPath.isAbsolute) {
            configuredPath
        } else {
            File(context.filesDir, patch.artifactPath)
        }
        return resolvedPath.canonicalFile
    }
}
