package com.berkersaptas.app_updater.ota_runtime

import java.io.File

internal data class PatchArtifact(
    val loadableAotLibrary: File,
    val kind: String,
)

internal interface PatchArtifactResolver {
    fun resolve(patch: PatchState): Result<PatchArtifact>
}
