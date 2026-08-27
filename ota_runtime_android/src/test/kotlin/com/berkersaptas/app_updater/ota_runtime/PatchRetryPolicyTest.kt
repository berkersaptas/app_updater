package com.berkersaptas.app_updater.ota_runtime

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class PatchRetryPolicyTest {
    private fun patch(patchNumber: Int) = TestFixtures.signedPendingPatch(
        context = TestFixtures.context(),
        patchNumber = patchNumber,
        sha256 = "a".repeat(64),
        artifactPath = "ota/patches/$patchNumber/libapp.so",
    ).patch

    @Test
    fun `permanent compatibility failure is reported as already seen`() {
        val state = patch(7).withStatus(
            PatchState.STATUS_FAILED,
            "Flutter engine mismatch: patch=old, app=new",
        )

        assertEquals(7, PatchRetryPolicy.patchNumberForCheck(state))
    }

    @Test
    fun `download corruption remains retryable`() {
        val state = patch(7).withStatus(PatchState.STATUS_FAILED, "SHA-256 mismatch")

        assertEquals(0, PatchRetryPolicy.patchNumberForCheck(state))
    }

    @Test
    fun `remote rollback remains reinstallable`() {
        val state = patch(7).withStatus(PatchState.STATUS_DISABLED, "Disabled by backend")

        assertEquals(0, PatchRetryPolicy.patchNumberForCheck(state))
    }
}
