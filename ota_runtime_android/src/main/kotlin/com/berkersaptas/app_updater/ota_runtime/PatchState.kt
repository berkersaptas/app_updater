package com.berkersaptas.app_updater.ota_runtime

import org.json.JSONObject

internal data class PatchState(
    val schemaVersion: Int = OtaManifestContract.SCHEMA_VERSION,
    val enabled: Boolean,
    val release: String,
    val patchNumber: Int,
    val artifactKind: String,
    val artifactPath: String,
    val sha256: String,
    // Byte size of the uploaded/downloaded artifact file itself (not the reconstructed target
    // for binary_diff) — -1 means unknown, only possible for state persisted before this field
    // existed, and skips the size check rather than failing closed on an upgrade.
    val artifactSize: Long = -1,
    val engineRevision: String,
    val dartVersion: String,
    val abi: String,
    val buildMode: String,
    val signatureKeyId: String,
    val signatureAlgorithm: String,
    val signature: String,
    val state: String,
    val failureReason: String? = null,
) {
    fun withStatus(status: String, reason: String? = null) = copy(
        enabled = status != STATUS_FAILED && status != STATUS_DISABLED,
        state = status,
        failureReason = reason,
    )

    fun toJson() = JSONObject().apply {
        put("schema_version", schemaVersion)
        put("enabled", enabled)
        put("release", release)
        put("patch_number", patchNumber)
        put("artifact_kind", artifactKind)
        put("artifact_path", artifactPath)
        put("sha256", sha256)
        put("artifact_size", artifactSize)
        put("engine_revision", engineRevision)
        put("dart_version", dartVersion)
        put("abi", abi)
        put("build_mode", buildMode)
        put("signature_key_id", signatureKeyId)
        put("signature_algorithm", signatureAlgorithm)
        put("signature", signature)
        put("state", state)
        failureReason?.let { put("failure_reason", it) }
    }

    companion object {
        const val STATUS_NONE = "none"
        const val STATUS_PENDING = "pending"
        const val STATUS_PENDING_BOOT = "pending_boot"
        const val STATUS_ACTIVE = "active"
        const val STATUS_FAILED = "failed"
        const val STATUS_DISABLED = "disabled"

        private val knownStatuses = setOf(
            STATUS_NONE,
            STATUS_PENDING,
            STATUS_PENDING_BOOT,
            STATUS_ACTIVE,
            STATUS_FAILED,
            STATUS_DISABLED,
        )

        fun fromJson(json: JSONObject): PatchState {
            val status = json.getString("state")
            require(status in knownStatuses) { "Unknown patch state: $status" }
            val schemaVersion = json.optInt("schema_version", 0)
            require(schemaVersion == OtaManifestContract.SCHEMA_VERSION) {
                "Unsupported patch schema: $schemaVersion"
            }
            return PatchState(
                schemaVersion = schemaVersion,
                enabled = json.getBoolean("enabled"),
                release = json.getString("release"),
                patchNumber = json.getInt("patch_number"),
                artifactKind = json.optString(
                    "artifact_kind",
                    OtaManifestContract.ARTIFACT_KIND_FULL_AOT_LIBRARY,
                ),
                artifactPath = json.getString("artifact_path"),
                sha256 = json.getString("sha256").lowercase(),
                artifactSize = json.optLong("artifact_size", -1),
                engineRevision = json.getString("engine_revision"),
                dartVersion = json.getString("dart_version"),
                abi = json.getString("abi"),
                buildMode = json.getString("build_mode"),
                signatureKeyId = json.getString("signature_key_id"),
                signatureAlgorithm = json.getString("signature_algorithm"),
                signature = json.getString("signature"),
                state = status,
                failureReason = json.optString("failure_reason").ifBlank { null },
            )
        }
    }
}
