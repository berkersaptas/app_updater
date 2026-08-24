plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// No OTA compatibility/keyring wiring needed here: the app_updater plugin generates it
// automatically at build time from <flutter-project-root>/app_updater.yaml — see that file
// and app_updater/android/build.gradle.kts.

android {
    namespace = "com.berkersaptas.app_updater_sample"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.berkersaptas.app_updater_sample"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // POC only: use the debug key while retaining a non-debuggable release/AOT variant.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// No explicit `dependencies {}` needed here: the Flutter plugin loader wires the
// app_updater plugin dependency in automatically from pubspec.yaml, and that plugin depends
// on ota_runtime_android itself (see app_updater/android/build.gradle.kts).
