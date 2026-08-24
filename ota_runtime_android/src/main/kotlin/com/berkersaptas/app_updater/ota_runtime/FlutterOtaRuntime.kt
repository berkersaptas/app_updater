package com.berkersaptas.app_updater.ota_runtime

import android.content.Context

class FlutterOtaRuntime(context: Context) {
    private val appContext = context.applicationContext
    private val stateStore = PatchStateStore(appContext)
    private val lifecycleStore = OtaLifecycleStore(appContext)
    private val badPatchStore = BadPatchStore(appContext)

    fun engineArgsForThisBoot(): Array<String>? {
        val patch = stateStore.read()
        val artifact = PatchLoader(appContext, stateStore).artifactForThisBoot()
        if (artifact != null && patch != null) {
            BootWatchdog.arm(appContext, patch.patchNumber)
        }
        return artifact?.let { arrayOf("--aot-shared-library-name=${it.absolutePath}") }
    }

    fun markBootSuccess() {
        BootWatchdog.disarm()
        PatchLoader(appContext, stateStore).markBootSuccess()
    }

    fun status(): OtaRuntimeStatus {
        val patch = stateStore.read()
        return OtaRuntimeStatus(
            state = patch?.state,
            patchNumber = patch?.patchNumber,
            failureReason = patch?.failureReason,
            hasLastKnownGood = lifecycleStore.hasLastKnownGood(),
            quarantineCount = lifecycleStore.quarantineCount(),
            storedPatchCount = lifecycleStore.storedPatchCount(),
            badPatchCount = badPatchStore.count(),
            circuitOpen = lifecycleStore.circuitOpen(),
        )
    }
}
