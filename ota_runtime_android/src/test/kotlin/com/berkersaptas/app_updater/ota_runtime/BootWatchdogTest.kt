package com.berkersaptas.app_updater.ota_runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

/**
 * [BootWatchdog] runs on a real background thread (deliberately independent of the main looper,
 * so it still fires if the main thread is hung) — these tests use short real timeouts and poll,
 * rather than mocking time, to exercise that real scheduling.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class BootWatchdogTest {
    private val context = TestFixtures.context().also { TestFixtures.installMetaData(it) }
    private val stateStore = PatchStateStore(context)
    private val badPatches = BadPatchStore(context)

    @Test
    fun `an unconfirmed boot beyond the timeout is failed and blacklisted`() {
        val patchNumber = 11
        stateStore.write(pendingBootPatch(patchNumber))

        BootWatchdog.arm(context, patchNumber, timeoutMillis = 50)
        awaitUntil { stateStore.read()?.state == PatchState.STATUS_FAILED }

        assertTrue(badPatches.contains(patchNumber))
    }

    @Test
    fun `disarming before the timeout prevents the failure`() {
        val patchNumber = 12
        stateStore.write(pendingBootPatch(patchNumber))

        BootWatchdog.arm(context, patchNumber, timeoutMillis = 300)
        BootWatchdog.disarm()
        Thread.sleep(500)

        assertEquals(PatchState.STATUS_PENDING_BOOT, stateStore.read()?.state)
    }

    private fun awaitUntil(timeoutMillis: Long = 2_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(20)
        }
        if (!condition()) fail("Condition was not met within ${timeoutMillis}ms")
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
