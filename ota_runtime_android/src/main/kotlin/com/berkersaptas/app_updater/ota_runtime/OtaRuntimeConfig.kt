package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.content.pm.PackageManager

/**
 * Per-app compatibility fingerprint, trusted keyring, and backend location, read at runtime from
 * `<meta-data>` on the consuming app's own `<application>` tag rather than baked into this module's
 * `BuildConfig` at its own build time. This is what lets a single published `ota_runtime_android`
 * artifact serve many different apps. When consumed through `app_updater`, these `<meta-data>`
 * entries are generated automatically at build time from a single
 * `<flutter-project-root>/app_updater.yaml` file — nothing to hand-edit per platform. See
 * `docs/generic_runtime_integration.md` and `app_updater/README.md`.
 */
internal data class OtaRuntimeConfig(
    val engineRevision: String,
    val dartVersion: String,
    val buildMode: String,
    val signatureTrustedKeys: Map<String, String>,
    val signatureRevokedKeyIds: Set<String>,
    val appSlug: String,
    val backendUrl: String,
) {
    companion object {
        fun from(context: Context): OtaRuntimeConfig {
            val metaData = context.packageManager.getApplicationInfo(
                context.packageName,
                PackageManager.GET_META_DATA,
            ).metaData

            fun required(key: String): String =
                requireNotNull(metaData?.getString(key)) {
                    "Missing required <meta-data android:name=\"$key\"> on the app's " +
                        "<application> tag. See docs/generic_runtime_integration.md."
                }

            return OtaRuntimeConfig(
                engineRevision = required(OtaManifestContract.META_DATA_ENGINE_REVISION),
                dartVersion = required(OtaManifestContract.META_DATA_DART_VERSION),
                buildMode = required(OtaManifestContract.META_DATA_BUILD_MODE),
                signatureTrustedKeys = parseKeyring(
                    metaData?.getString(OtaManifestContract.META_DATA_SIGNATURE_TRUSTED_KEYS),
                ),
                signatureRevokedKeyIds = metaData
                    ?.getString(OtaManifestContract.META_DATA_SIGNATURE_REVOKED_KEY_IDS)
                    ?.split(',')
                    ?.map(String::trim)
                    ?.filter(String::isNotEmpty)
                    ?.toSet()
                    ?: emptySet(),
                appSlug = required(OtaManifestContract.META_DATA_APP_SLUG),
                backendUrl = required(OtaManifestContract.META_DATA_BACKEND_URL),
            )
        }

        private fun parseKeyring(raw: String?): Map<String, String> =
            raw.orEmpty()
                .split(',')
                .mapNotNull { entry ->
                    val separator = entry.indexOf(':')
                    if (separator <= 0 || separator == entry.lastIndex) return@mapNotNull null
                    entry.substring(0, separator) to entry.substring(separator + 1)
                }
                .toMap()
    }
}
