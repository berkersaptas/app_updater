package com.berkersaptas.app_updater.ota_runtime

internal object PatchRetryPolicy {
    private val permanentCompatibilityFailures = listOf(
        "Base release mismatch:",
        "Flutter engine mismatch:",
        "Dart version mismatch:",
        "Build mode mismatch:",
        "ABI mismatch:",
        "OTA protocol mismatch:",
        "Base libapp.so identity could not be determined",
        "Base libapp.so mismatch:",
        "Build fingerprint mismatch:",
    )

    /**
     * Reports a permanently incompatible local patch as already seen so the backend can offer a
     * newer patch but cannot make the device download the same immutable manifest every launch.
     * Artifact/hash failures remain retryable because a fresh download may repair corrupted bytes.
     */
    fun patchNumberForCheck(state: PatchState?): Int = when {
        state == null -> 0
        state.state == PatchState.STATUS_ACTIVE || state.state == PatchState.STATUS_PENDING ->
            state.patchNumber
        state.state == PatchState.STATUS_FAILED &&
            permanentCompatibilityFailures.any { state.failureReason.orEmpty().startsWith(it) } ->
            state.patchNumber
        else -> 0
    }
}
