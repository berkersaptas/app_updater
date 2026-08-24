package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.util.AtomicFile
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

internal class BadPatchStore(context: Context) {
    private val badPatchesFile = AtomicFile(File(context.filesDir, "ota/bad_patches.json"))

    fun contains(patchNumber: Int): Boolean =
        readEntries().any { it.patchNumber == patchNumber }

    fun count(): Int = readEntries().size

    fun markBad(patchNumber: Int, reason: String) {
        val existing = readEntries().filterNot { it.patchNumber == patchNumber }
        writeEntries(
            existing + BadPatchEntry(
                patchNumber = patchNumber,
                reason = reason,
                markedAtMillis = System.currentTimeMillis(),
            ),
        )
    }

    private fun readEntries(): List<BadPatchEntry> {
        if (!badPatchesFile.baseFile.isFile) return emptyList()
        return try {
            badPatchesFile.openRead().bufferedReader().use { reader ->
                val root = JSONObject(reader.readText())
                val patches = root.optJSONArray("patches") ?: JSONArray()
                buildList {
                    for (index in 0 until patches.length()) {
                        val item = patches.optJSONObject(index) ?: continue
                        val patchNumber = item.optInt("patch_number", -1)
                        if (patchNumber > 0) {
                            add(
                                BadPatchEntry(
                                    patchNumber = patchNumber,
                                    reason = item.optString("reason"),
                                    markedAtMillis = item.optLong("marked_at_millis"),
                                ),
                            )
                        }
                    }
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "Invalid bad patch list; ignoring it", error)
            emptyList()
        }
    }

    private fun writeEntries(entries: List<BadPatchEntry>) {
        badPatchesFile.baseFile.parentFile?.mkdirs()
        val root = JSONObject().apply {
            put("schema_version", OtaManifestContract.SCHEMA_VERSION)
            put(
                "patches",
                JSONArray().apply {
                    entries.sortedBy { it.patchNumber }.forEach { entry ->
                        put(
                            JSONObject().apply {
                                put("patch_number", entry.patchNumber)
                                put("reason", entry.reason)
                                put("marked_at_millis", entry.markedAtMillis)
                            },
                        )
                    }
                },
            )
        }

        var output: FileOutputStream? = null
        try {
            output = badPatchesFile.startWrite()
            output.write(root.toString(2).toByteArray(Charsets.UTF_8))
            badPatchesFile.finishWrite(output)
        } catch (error: Exception) {
            output?.let(badPatchesFile::failWrite)
            throw error
        }
    }

    private data class BadPatchEntry(
        val patchNumber: Int,
        val reason: String,
        val markedAtMillis: Long,
    )

    companion object {
        private const val TAG = "BadPatchStore"
    }
}
