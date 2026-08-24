package com.berkersaptas.app_updater.ota_runtime

import android.content.Context
import android.content.pm.PackageInfo
import android.os.Build

/**
 * `PackageInfo.longVersionCode` requires API 28; this module's `minSdk` is 23.
 * `PackageInfo.versionCode` (deprecated on API 28+, still the only field on 23-27) is the fallback.
 */
@Suppress("DEPRECATION")
private fun PackageInfo.versionCodeCompat(): Long =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) longVersionCode else versionCode.toLong()

internal fun installedRelease(context: Context): String {
    val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
    return "${packageInfo.versionName}+${packageInfo.versionCodeCompat()}"
}
