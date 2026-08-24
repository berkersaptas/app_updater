package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.util.AtomicFile
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

internal class PatchStateStore(context: Context) {
    private val stateFile = AtomicFile(File(context.filesDir, "ota/patch_state.json"))

    fun read(): PatchState? {
        if (!stateFile.baseFile.isFile) return null
        return try {
            stateFile.openRead().bufferedReader().use {
                PatchState.fromJson(JSONObject(it.readText()))
            }
        } catch (error: Exception) {
            Log.e(TAG, "Invalid patch state; using the base artifact", error)
            null
        }
    }

    fun write(state: PatchState) {
        stateFile.baseFile.parentFile?.mkdirs()
        var output: FileOutputStream? = null
        try {
            output = stateFile.startWrite()
            output.write(state.toJson().toString(2).toByteArray(Charsets.UTF_8))
            stateFile.finishWrite(output)
        } catch (error: Exception) {
            output?.let(stateFile::failWrite)
            throw error
        }
    }

    companion object {
        private const val TAG = "OtaPatchStateStore"
    }
}
