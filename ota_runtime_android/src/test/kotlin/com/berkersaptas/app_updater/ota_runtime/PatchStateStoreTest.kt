package com.berkersaptas.app_updater.ota_runtime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class PatchStateStoreTest {
    private val context = TestFixtures.context()
    private val store = PatchStateStore(context)

    @Test
    fun `missing state file returns null`() {
        assertNull(store.read())
    }

    @Test
    fun `write then read round trips`() {
        val patch = samplePatch(state = PatchState.STATUS_PENDING)
        store.write(patch)
        assertEquals(patch, store.read())
    }

    @Test
    fun `unknown state value is rejected, not silently coerced`() {
        val stateFile = File(context.filesDir, "ota/patch_state.json")
        stateFile.parentFile?.mkdirs()
        stateFile.writeText(samplePatch(state = "not_a_real_state").toJson().toString())
        assertNull(store.read())
    }

    @Test
    fun `corrupt json degrades to null instead of crashing`() {
        val stateFile = File(context.filesDir, "ota/patch_state.json")
        stateFile.parentFile?.mkdirs()
        stateFile.writeText("{ this is not valid json")
        assertNull(store.read())
    }

    private fun samplePatch(state: String) = PatchState(
        enabled = true,
        release = "1.0+1",
        patchNumber = 1,
        artifactKind = OtaManifestContract.ARTIFACT_KIND_FULL_AOT_LIBRARY,
        artifactPath = "ota/patches/1/libapp.so",
        sha256 = "a".repeat(64),
        engineRevision = "engine",
        dartVersion = "3.0.0",
        abi = "arm64-v8a",
        buildMode = "release",
        signatureKeyId = "key-1",
        signatureAlgorithm = OtaManifestContract.SIGNATURE_ALGORITHM_RSA_PKCS1_SHA256,
        signature = "sig",
        state = state,
    )
}
