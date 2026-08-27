package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.os.Build
import android.os.Bundle
import android.util.Base64
import androidx.test.core.app.ApplicationProvider
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import org.robolectric.Shadows.shadowOf

/** Shared setup for tests that need a real, verifiable [PatchState] and its matching config. */
internal object TestFixtures {
    const val KEY_ID = "test-key-1"
    const val ENGINE_REVISION = "test-engine"
    const val DART_VERSION = "3.0.0"
    const val BUILD_MODE = "release"
    private val baseArtifactBytes = "test-base-libapp".toByteArray()
    val BASE_SHA256: String = MessageDigest.getInstance("SHA-256")
        .digest(baseArtifactBytes)
        .joinToString("") { "%02x".format(it) }

    fun context(): Context = ApplicationProvider.getApplicationContext()

    /**
     * Installs the `<meta-data>` a real app gets at build time (via `app_updater.yaml`) so
     * [OtaRuntimeConfig.from] and [PatchSignatureVerifier] work in a test. Goes through
     * `ShadowPackageManager.installPackage` rather than mutating a `getApplicationInfo()` result in
     * place — Robolectric does not guarantee that call returns a shared, mutable instance.
     */
    fun installMetaData(context: Context, trustedKeyBase64Url: String = "unused:unused") {
        val packageName = context.packageName
        val metaData = Bundle().apply {
            putString(OtaManifestContract.META_DATA_ENGINE_REVISION, ENGINE_REVISION)
            putString(OtaManifestContract.META_DATA_DART_VERSION, DART_VERSION)
            putString(OtaManifestContract.META_DATA_BUILD_MODE, BUILD_MODE)
            putString(OtaManifestContract.META_DATA_SIGNATURE_TRUSTED_KEYS, "$KEY_ID:$trustedKeyBase64Url")
            putString(OtaManifestContract.META_DATA_APP_SLUG, "test-app")
            putString(OtaManifestContract.META_DATA_BACKEND_URL, "https://example.invalid")
        }
        val packageInfo = PackageInfo().apply {
            this.packageName = packageName
            applicationInfo = ApplicationInfo().apply {
                this.packageName = packageName
                this.metaData = metaData
                nativeLibraryDir = context.filesDir.resolve("test-native-libs").also {
                    it.mkdirs()
                    it.resolve("libapp.so").writeBytes(baseArtifactBytes)
                }.absolutePath
            }
        }
        shadowOf(context.packageManager).installPackage(packageInfo)
    }

    data class SignedFixture(val patch: PatchState, val publicKeyBase64Url: String)

    /**
     * Builds a `pending` [PatchState] with a real RSA signature over the same canonical payload
     * [PatchSignatureVerifier] checks, plus the matching public key for [installMetaData]. Callers
     * override fields (e.g. `sha256`, `artifactPath`) via [PatchState.copy] as needed — re-signing
     * is only required if a *signed* field changes (see [PatchSignatureVerifier]'s payload).
     */
    fun signedPendingPatch(
        context: Context,
        patchNumber: Int,
        sha256: String,
        artifactPath: String,
    ): SignedFixture {
        val keyPair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.genKeyPair()
        val release = installedRelease(context)
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: "test-abi"
        val buildFingerprint = InstalledBuildIdentity.fingerprint(
            OtaManifestContract.OTA_PROTOCOL_VERSION,
            release,
            ENGINE_REVISION,
            DART_VERSION,
            abi,
            BUILD_MODE,
            BASE_SHA256,
        )
        var patch = PatchState(
            enabled = true,
            release = release,
            patchNumber = patchNumber,
            artifactKind = OtaManifestContract.ARTIFACT_KIND_FULL_AOT_LIBRARY,
            artifactPath = artifactPath,
            sha256 = sha256,
            engineRevision = ENGINE_REVISION,
            dartVersion = DART_VERSION,
            abi = abi,
            buildMode = BUILD_MODE,
            signatureKeyId = KEY_ID,
            signatureAlgorithm = OtaManifestContract.SIGNATURE_ALGORITHM_RSA_PKCS1_SHA256,
            signature = "",
            state = PatchState.STATUS_PENDING,
            baseSha256 = BASE_SHA256,
            buildFingerprint = buildFingerprint,
        )
        val signer = Signature.getInstance("SHA256withRSA").apply {
            initSign(keyPair.private)
            update(canonicalPayload(patch).toByteArray(Charsets.UTF_8))
        }
        patch = patch.copy(signature = encodeBase64Url(signer.sign()))
        return SignedFixture(patch, encodeBase64Url(keyPair.public.encoded))
    }

    // Mirrors PatchSignatureVerifier's private canonicalPayload — duplicated because it is
    // class-private (not merely internal), and a fixture must sign the exact bytes verify() checks.
    private fun canonicalPayload(patch: PatchState): String = buildString {
        append("schema_version=").append(patch.schemaVersion).append('\n')
        append("ota_protocol_version=").append(patch.otaProtocolVersion).append('\n')
        append("release=").append(patch.release).append('\n')
        append("patch_number=").append(patch.patchNumber).append('\n')
        append("artifact_kind=").append(patch.artifactKind).append('\n')
        append("engine_revision=").append(patch.engineRevision).append('\n')
        append("dart_version=").append(patch.dartVersion).append('\n')
        append("abi=").append(patch.abi).append('\n')
        append("build_mode=").append(patch.buildMode).append('\n')
        append("base_sha256=").append(patch.baseSha256).append('\n')
        append("build_fingerprint=").append(patch.buildFingerprint).append('\n')
        append("sha256=").append(patch.sha256).append('\n')
        append("signature_key_id=").append(patch.signatureKeyId).append('\n')
        append("signature_algorithm=").append(patch.signatureAlgorithm).append('\n')
    }

    private fun encodeBase64Url(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
}
