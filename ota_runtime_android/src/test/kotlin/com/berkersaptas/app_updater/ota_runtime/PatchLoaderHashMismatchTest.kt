package com.berkersaptas.app_updater.ota_runtime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

/**
 * A patch that passes signature verification and compatibility checks but whose downloaded
 * artifact doesn't hash to the signed `sha256` must still fail closed — and, unlike a stuck
 * `pending_boot`, must NOT blacklist the patch number, since the artifact on disk (not the patch
 * itself) is what's suspect; a retried download could still succeed. See `PatchLoader`.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class PatchLoaderHashMismatchTest {
    private val context = TestFixtures.context()
    private val stateStore = PatchStateStore(context)
    private val badPatches = BadPatchStore(context)

    @Test
    fun `sha256 mismatch fails closed without blacklisting the patch number`() {
        val patchNumber = 9
        val relativePath = "ota/patches/$patchNumber/libapp.so"
        val artifactFile = File(context.filesDir, relativePath)
        artifactFile.parentFile?.mkdirs()
        artifactFile.writeBytes("not-the-signed-bytes".toByteArray())

        val fixture = TestFixtures.signedPendingPatch(
            context = context,
            patchNumber = patchNumber,
            sha256 = "b".repeat(64), // does not match the real sha256 of artifactFile's bytes
            artifactPath = relativePath,
        )
        TestFixtures.installMetaData(context, fixture.publicKeyBase64Url)
        stateStore.write(fixture.patch)

        val artifact = PatchLoader(context, stateStore).artifactForThisBoot()

        assertNull(artifact)
        val persisted = requireNotNull(stateStore.read())
        assertEquals(PatchState.STATUS_FAILED, persisted.state)
        assertTrue(persisted.failureReason.orEmpty().contains("SHA-256 mismatch"))
        assertFalse(badPatches.contains(patchNumber))
    }
}
