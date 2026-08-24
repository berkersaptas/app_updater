package com.berkersaptas.app_updater.ota_runtime

data class OtaRuntimeStatus(
    val state: String?,
    val patchNumber: Int?,
    val failureReason: String?,
    val hasLastKnownGood: Boolean,
    val quarantineCount: Int,
    val storedPatchCount: Int,
    val badPatchCount: Int,
    val circuitOpen: Boolean,
)
