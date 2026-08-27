package com.berkersaptas.app_updater.ota_runtime

import org.junit.Assert.assertEquals
import org.junit.Test

class InstalledBuildIdentityTest {
    @Test
    fun `fingerprint matches the shared shell and backend contract`() {
        assertEquals(
            "46612b3568f1b3220765c4138063d6940fdb87bc5dd5197555bd3c188e0be766",
            InstalledBuildIdentity.fingerprint(
                protocolVersion = 2,
                release = "1.0.0+1",
                engineRevision = "83675ed27633283e7fc296c8bca22e841224c096",
                dartVersion = "3.12.2",
                abi = "arm64-v8a",
                buildMode = "release",
                baseSha256 = "a".repeat(64),
            ),
        )
    }
}
