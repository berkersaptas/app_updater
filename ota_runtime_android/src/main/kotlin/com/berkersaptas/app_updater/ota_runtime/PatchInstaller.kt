package com.berkersaptas.app_updater.ota_runtime

/**
 * Verifies a candidate [PatchState] (schema version, revoked/trusted key, signature) and, if
 * valid, persists it as `pending` for the next boot. Shared by the debug/test
 * [OtaInstallProvider] and [OtaUpdateClient] so both ingress paths enforce identical checks before
 * a patch can ever be selected by [PatchLoader].
 */
internal object PatchInstaller {
    fun install(
        store: PatchStateStore,
        patch: PatchState,
        verifier: PatchSignatureVerifier,
    ): Result<PatchState> = runCatching {
        require(patch.schemaVersion == OtaManifestContract.SCHEMA_VERSION) {
            "Unsupported patch schema: ${patch.schemaVersion}"
        }
        require(verifier.verify(patch)) {
            "Patch manifest signature could not be verified"
        }
        val pending = patch.withStatus(PatchState.STATUS_PENDING)
        store.write(pending)
        pending
    }
}
