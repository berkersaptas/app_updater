package com.berkersaptas.app_updater.ota_runtime

import android.util.Log

internal object BackendRollback {
    fun apply(
        stateStore: PatchStateStore,
        lifecycleStore: OtaLifecycleStore,
        patchNumber: Int,
    ): Boolean {
        val current = stateStore.read() ?: return false
        if (current.patchNumber != patchNumber || current.state == PatchState.STATUS_DISABLED) {
            return false
        }
        stateStore.write(
            current.withStatus(
                PatchState.STATUS_DISABLED,
                "Patch was disabled or its signing key was revoked by the backend",
            ),
        )
        lifecycleStore.cleanup(null)
        Log.w(TAG, "Patch $patchNumber was remotely disabled; base artifact will load next boot")
        return true
    }

    private const val TAG = "OtaUpdateClient"
}
