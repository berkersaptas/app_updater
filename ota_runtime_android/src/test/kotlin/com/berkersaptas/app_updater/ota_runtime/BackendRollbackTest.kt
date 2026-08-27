package com.berkersaptas.app_updater.ota_runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class BackendRollbackTest {
    private val context = TestFixtures.context()
    private val stateStore = PatchStateStore(context)
    private val lifecycleStore = OtaLifecycleStore(context)

    @Test
    fun `matching active patch is disabled for the next boot`() {
        stateStore.write(activePatch(7))

        val applied = BackendRollback.apply(stateStore, lifecycleStore, 7)

        assertTrue(applied)
        val persisted = requireNotNull(stateStore.read())
        assertEquals(PatchState.STATUS_DISABLED, persisted.state)
        assertFalse(persisted.enabled)
        assertTrue(persisted.failureReason!!.contains("backend"))
    }

    @Test
    fun `rollback for another patch number does not change local state`() {
        stateStore.write(activePatch(7))

        val applied = BackendRollback.apply(stateStore, lifecycleStore, 8)

        assertFalse(applied)
        assertEquals(PatchState.STATUS_ACTIVE, stateStore.read()!!.state)
    }

    private fun activePatch(patchNumber: Int) = PatchState(
        enabled = true,
        release = "1.0.0+1",
        patchNumber = patchNumber,
        artifactKind = OtaManifestContract.ARTIFACT_KIND_BINARY_DIFF,
        artifactPath = "ota/patches/$patchNumber/libapp.so.diff",
        sha256 = "a".repeat(64),
        artifactSize = 1,
        engineRevision = "engine",
        dartVersion = "3.0.0",
        abi = "arm64-v8a",
        buildMode = "release",
        signatureKeyId = "key-1",
        signatureAlgorithm = OtaManifestContract.SIGNATURE_ALGORITHM_RSA_PKCS1_SHA256,
        signature = "signature",
        state = PatchState.STATUS_ACTIVE,
    )
}
