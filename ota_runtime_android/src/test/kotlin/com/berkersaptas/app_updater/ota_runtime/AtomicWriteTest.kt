package com.berkersaptas.app_updater.ota_runtime

import android.util.AtomicFile
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

/**
 * Regression coverage for the atomic-write guarantee `PatchStateStore`/`OtaLifecycleStore`/
 * `BadPatchStore` all rely on ([android.util.AtomicFile]): a torn/aborted write must never corrupt
 * the last successfully committed content, and a corrupted file on disk must degrade to "ignore it"
 * rather than crash the caller.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class AtomicWriteTest {
    private val context = TestFixtures.context()

    @Test
    fun `a failed write leaves the previously committed content untouched`() {
        val target = File(context.filesDir, "ota/atomic_write_test.json")
        target.parentFile?.mkdirs()
        val file = AtomicFile(target)

        val firstWrite = file.startWrite()
        firstWrite.write("committed".toByteArray())
        file.finishWrite(firstWrite)

        val abortedWrite = file.startWrite()
        abortedWrite.write("should-not-land".toByteArray())
        file.failWrite(abortedWrite)

        assertEquals("committed", file.readFully().toString(Charsets.UTF_8))
    }

    @Test
    fun `PatchStateStore ignores a file corrupted after the fact`() {
        val store = PatchStateStore(context)
        val target = File(context.filesDir, "ota/patch_state.json")
        target.parentFile?.mkdirs()
        target.writeBytes("{ truncated".toByteArray())

        assertNull(store.read())
        assertTrue(target.exists())
    }
}
