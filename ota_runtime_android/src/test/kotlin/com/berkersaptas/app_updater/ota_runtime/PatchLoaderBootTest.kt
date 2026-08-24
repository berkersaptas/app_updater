package com.berkersaptas.app_updater.ota_runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

/**
 * "Unfinished boot" regression: a previous patched boot wrote `pending_boot` and never confirmed
 * (the process crashed, or was killed, before `markBootSuccess`). The next process to run this
 * code must fail closed, exactly as `docs/rollback_model.md` describes.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class PatchLoaderBootTest {
    private val context = TestFixtures.context().also { TestFixtures.installMetaData(it) }
    private val stateStore = PatchStateStore(context)
    private val badPatches = BadPatchStore(context)

    @Test
    fun `a patch stuck in pending_boot is failed and blacklisted on next boot`() {
        val patchNumber = 42
        stateStore.write(pendingBootPatch(patchNumber))

        val artifact = PatchLoader(context, stateStore).artifactForThisBoot()

        assertNull(artifact)
        val persisted = requireNotNull(stateStore.read())
        assertEquals(PatchState.STATUS_FAILED, persisted.state)
        assertTrue(badPatches.contains(patchNumber))
    }

    @Test
    fun `a failed pending_boot patch is never selected again`() {
        stateStore.write(pendingBootPatch(patchNumber = 5))
        PatchLoader(context, stateStore).artifactForThisBoot()

        val secondAttempt = PatchLoader(context, stateStore).artifactForThisBoot()

        assertNull(secondAttempt)
    }

    private fun pendingBootPatch(patchNumber: Int) = PatchState(
        enabled = true,
        release = "1.0+1",
        patchNumber = patchNumber,
        artifactKind = OtaManifestContract.ARTIFACT_KIND_FULL_AOT_LIBRARY,
        artifactPath = "ota/patches/$patchNumber/libapp.so",
        sha256 = "a".repeat(64),
        engineRevision = "engine",
        dartVersion = "3.0.0",
        abi = "arm64-v8a",
        buildMode = "release",
        signatureKeyId = "key-1",
        signatureAlgorithm = OtaManifestContract.SIGNATURE_ALGORITHM_RSA_PKCS1_SHA256,
        signature = "sig",
        state = PatchState.STATUS_PENDING_BOOT,
    )
}
