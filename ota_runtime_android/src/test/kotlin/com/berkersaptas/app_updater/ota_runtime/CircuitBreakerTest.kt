package com.berkersaptas.app_updater.ota_runtime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.junit.runner.RunWith

private const val SIX_HOURS_MILLIS = 6 * 60 * 60 * 1000L

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class CircuitBreakerTest {
    private val context = TestFixtures.context()
    private val lifecycle = OtaLifecycleStore(context)

    @Test
    fun `circuit stays closed below the failure threshold`() {
        lifecycle.recordFailure()
        lifecycle.recordFailure()
        assertFalse(lifecycle.circuitOpen())
    }

    @Test
    fun `three consecutive failures opens the circuit`() {
        repeat(3) { lifecycle.recordFailure() }
        assertTrue(lifecycle.circuitOpen())
    }

    @Test
    fun `a success resets the failure count`() {
        repeat(3) { lifecycle.recordFailure() }
        lifecycle.recordSuccess()
        assertFalse(lifecycle.circuitOpen())
    }

    @Test
    fun `the circuit half-opens again after the cooldown elapses`() {
        repeat(3) { lifecycle.recordFailure() }
        val now = System.currentTimeMillis()

        assertTrue(lifecycle.circuitOpen(now = now + 1_000))
        assertFalse(lifecycle.circuitOpen(now = now + SIX_HOURS_MILLIS + 1_000))
    }
}
