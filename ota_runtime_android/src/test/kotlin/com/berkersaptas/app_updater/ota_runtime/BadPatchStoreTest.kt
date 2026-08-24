package com.berkersaptas.app_updater.ota_runtime

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class BadPatchStoreTest {
    private val context = TestFixtures.context()
    private val store = BadPatchStore(context)

    @Test
    fun `unmarked patch number is not contained`() {
        assertFalse(store.contains(7))
    }

    @Test
    fun `marking bad makes it contained and counted`() {
        store.markBad(7, "SHA-256 mismatch")
        assertTrue(store.contains(7))
        assertEquals(1, store.count())
    }

    @Test
    fun `marking the same patch number twice does not double count`() {
        store.markBad(7, "first reason")
        store.markBad(7, "second reason")
        assertEquals(1, store.count())
    }

    @Test
    fun `corrupt file degrades to empty list instead of crashing`() {
        val badPatchesFile = File(context.filesDir, "ota/bad_patches.json")
        badPatchesFile.parentFile?.mkdirs()
        badPatchesFile.writeText("not json at all")
        assertFalse(store.contains(7))
        assertEquals(0, store.count())
    }
}
