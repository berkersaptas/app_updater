plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

group = "com.app_updater"
version = "0.1.5"

repositories {
    google()
    mavenCentral()
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "com.berkersaptas.app_updater.ota_runtime"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release")
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }
}

dependencies {
    // Pure-JVM bsdiff/bspatch for binary_diff artifact reconstruction (no NDK/native code).
    // See engine_notes/phase_2_engine_feasibility.md for the evaluation.
    implementation("io.sigpipe:jbsdiff:1.0")

    // JVM unit tests (Robolectric) — no emulator/device needed for Context/filesDir/AtomicFile.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.13")
    testImplementation("androidx.test:core:1.6.1")
}

// Publishes a real AAR + POM to a local flat-file Maven repository under <repo-root>/maven-repo/
// so other apps' Gradle builds can resolve `com.app_updater:ota_runtime_android:<version>` from a
// `maven { url = uri("<path-or-url-to>/maven-repo") }` repository, instead of source-including
// this module. Run `./gradlew publish` from within ota_runtime_android/ (it is a standalone Gradle
// build, not a subproject of sample_app/android — see ota_runtime_android/README.md).
afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                artifactId = "ota_runtime_android"
            }
        }
        repositories {
            maven {
                name = "localRepo"
                url = uri(projectDir.resolve("../maven-repo"))
            }
        }
    }
}
