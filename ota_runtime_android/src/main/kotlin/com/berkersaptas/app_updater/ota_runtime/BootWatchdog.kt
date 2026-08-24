package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Guards against a patched boot that hangs instead of crashing. The existing `pending_boot`
 * re-detection in [PatchLoader] only runs on the *next* process start — if the current process
 * never crashes (main thread deadlocked/spinning, never renders a first frame, never calls
 * [FlutterOtaRuntime.markBootSuccess]) that detection never gets a chance to run. This watchdog
 * runs on a background thread independent of the main looper, so it still fires even if the main
 * thread is stuck, and proactively marks the stuck patch failed/bad-listed on disk so that
 * whichever restart eventually happens (user reopens the app, or the system reaps a long ANR)
 * boots clean immediately instead of re-attempting the same hung patch.
 *
 * Deliberately does not kill the process itself — see `docs/rollback_model.md`.
 */
internal object BootWatchdog {
    private const val TAG = "BootWatchdog"
    const val DEFAULT_TIMEOUT_MILLIS = 20_000L

    private val executor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "ota-boot-watchdog").apply { isDaemon = true }
        }

    @Volatile
    private var pending: ScheduledFuture<*>? = null

    fun arm(
        context: Context,
        patchNumber: Int,
        timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
        executorOverride: ScheduledExecutorService = executor,
    ) {
        pending?.cancel(false)
        val appContext = context.applicationContext
        pending = executorOverride.schedule(
            { onTimeout(appContext, patchNumber, timeoutMillis) },
            timeoutMillis,
            TimeUnit.MILLISECONDS,
        )
    }

    fun disarm() {
        pending?.cancel(false)
        pending = null
    }

    private fun onTimeout(context: Context, patchNumber: Int, timeoutMillis: Long) {
        try {
            val stateStore = PatchStateStore(context)
            val patch = stateStore.read() ?: return
            if (patch.patchNumber != patchNumber || patch.state != PatchState.STATUS_PENDING_BOOT) {
                return
            }
            Log.e(TAG, "Patch $patchNumber did not confirm boot within ${timeoutMillis}ms; failing it")
            PatchLoader(context, stateStore).failStuckBoot(
                patch,
                "Boot confirmation timed out after ${timeoutMillis}ms (possible hang)",
            )
        } catch (error: Exception) {
            Log.e(TAG, "Boot watchdog failed while handling a timeout for patch $patchNumber", error)
        }
    }
}
