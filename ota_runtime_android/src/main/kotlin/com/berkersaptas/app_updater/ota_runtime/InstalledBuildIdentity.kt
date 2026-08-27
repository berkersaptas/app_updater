package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.zip.ZipFile

internal data class InstalledBuildIdentity(
    val baseSha256: String,
    val fingerprint: String,
) {
    companion object {
        fun resolve(
            context: Context,
            release: String,
            engineRevision: String,
            dartVersion: String,
            abi: String,
            buildMode: String,
        ): InstalledBuildIdentity? {
            val baseSha256 = baseArtifactSha256(context, abi) ?: return null
            return InstalledBuildIdentity(
                baseSha256 = baseSha256,
                fingerprint = fingerprint(
                    OtaManifestContract.OTA_PROTOCOL_VERSION,
                    release,
                    engineRevision,
                    dartVersion,
                    abi,
                    buildMode,
                    baseSha256,
                ),
            )
        }

        fun fingerprint(
            protocolVersion: Int,
            release: String,
            engineRevision: String,
            dartVersion: String,
            abi: String,
            buildMode: String,
            baseSha256: String,
        ): String {
            val payload = buildString {
                append("ota_protocol_version=").append(protocolVersion).append('\n')
                append("release=").append(release).append('\n')
                append("engine_revision=").append(engineRevision).append('\n')
                append("dart_version=").append(dartVersion).append('\n')
                append("abi=").append(abi).append('\n')
                append("build_mode=").append(buildMode).append('\n')
                append("base_sha256=").append(baseSha256).append('\n')
            }
            return sha256(payload.byteInputStream())
        }

        private fun baseArtifactSha256(context: Context, abi: String): String? {
            val applicationInfo = context.packageManager.getApplicationInfo(context.packageName, 0)
            val nativeLibrary = File(applicationInfo.nativeLibraryDir.orEmpty(), "libapp.so")
            if (nativeLibrary.isFile) return nativeLibrary.inputStream().use(::sha256)

            val apkPaths = buildList {
                applicationInfo.sourceDir?.let(::add)
                applicationInfo.splitSourceDirs?.let(::addAll)
            }
            val entryName = "lib/$abi/libapp.so"
            for (apkPath in apkPaths) {
                val hash = runCatching {
                    ZipFile(apkPath).use { zip ->
                        val entry = zip.getEntry(entryName) ?: return@use null
                        zip.getInputStream(entry).use(::sha256)
                    }
                }.getOrNull()
                if (hash != null) return hash
            }
            return null
        }

        private fun sha256(input: InputStream): String {
            val digest = MessageDigest.getInstance("SHA-256")
            input.use { stream ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = stream.read(buffer)
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
