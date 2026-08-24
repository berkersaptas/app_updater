package com.berkersaptas.app_updater.ota_runtime

import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

internal class PatchSignatureVerifier(private val config: OtaRuntimeConfig) {
    fun verify(patch: PatchState): Boolean {
        if (patch.schemaVersion != OtaManifestContract.SCHEMA_VERSION) return false
        if (patch.signatureKeyId in revokedKeyIds()) return false
        val publicKeyBase64 = trustedKeys()[patch.signatureKeyId] ?: return false

        return try {
            val publicKeyBytes = decodeBase64Url(publicKeyBase64)
            val signatureBytes = decodeBase64Url(patch.signature)
            val algorithm = signatureAlgorithm(patch.signatureAlgorithm) ?: return false
            val publicKey = KeyFactory.getInstance(algorithm.keyFactory)
                .generatePublic(X509EncodedKeySpec(publicKeyBytes))
            val verifier = Signature.getInstance(algorithm.signature)
            verifier.initVerify(publicKey)
            verifier.update(canonicalPayload(patch).toByteArray(StandardCharsets.UTF_8))
            verifier.verify(signatureBytes)
        } catch (_: Exception) {
            false
        }
    }

    private fun canonicalPayload(patch: PatchState): String =
        buildString {
            append("schema_version=").append(patch.schemaVersion).append('\n')
            append("release=").append(patch.release).append('\n')
            append("patch_number=").append(patch.patchNumber).append('\n')
            append("artifact_kind=").append(patch.artifactKind).append('\n')
            append("engine_revision=").append(patch.engineRevision).append('\n')
            append("dart_version=").append(patch.dartVersion).append('\n')
            append("abi=").append(patch.abi).append('\n')
            append("build_mode=").append(patch.buildMode).append('\n')
            append("sha256=").append(patch.sha256).append('\n')
            append("signature_key_id=").append(patch.signatureKeyId).append('\n')
            append("signature_algorithm=").append(patch.signatureAlgorithm).append('\n')
        }

    private fun decodeBase64Url(value: String): ByteArray =
        Base64.decode(value, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    private fun signatureAlgorithm(manifestAlgorithm: String): VerificationAlgorithm? =
        when (manifestAlgorithm) {
            OtaManifestContract.SIGNATURE_ALGORITHM_ED25519 ->
                VerificationAlgorithm(keyFactory = "Ed25519", signature = "Ed25519")
            OtaManifestContract.SIGNATURE_ALGORITHM_RSA_PKCS1_SHA256 ->
                VerificationAlgorithm(keyFactory = "RSA", signature = "SHA256withRSA")
            else -> null
        }

    private fun trustedKeys(): Map<String, String> = config.signatureTrustedKeys

    private fun revokedKeyIds(): Set<String> = config.signatureRevokedKeyIds

    private data class VerificationAlgorithm(
        val keyFactory: String,
        val signature: String,
    )
}
