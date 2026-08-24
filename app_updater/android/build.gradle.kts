import java.util.Properties
import org.yaml.snakeyaml.Yaml

group = "com.berkersaptas.app_updater"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
        // Reads <flutter-project-root>/app_updater.yaml at the consuming app's own build time
        // (see loadOtaAppConfig() below) — the one piece of config an integrating app writes,
        // instead of hand-editing AndroidManifest.xml/build.gradle.kts. See app_updater/README.md.
        classpath("org.yaml:snakeyaml:2.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

/**
 * Reads `<flutter-project-root>/app_updater.yaml` and this Flutter checkout's own toolchain
 * (`flutter --version --machine`) to produce every value `OtaRuntimeConfig` needs at runtime —
 * automatically, at the *consuming app's* build time, so nothing needs hand-editing in the app's
 * own `android/` (or, once it exists, `ios/`) directory. `rootProject.projectDir` is the consuming
 * app's own `android/` directory regardless of where this plugin physically lives on disk (source
 * path dependency, pub cache, git checkout, ...), so `.parentFile` is reliably the Flutter project
 * root.
 */
fun Project.loadOtaAppConfig(): Map<String, String> {
    val flutterProjectRoot = rootProject.projectDir.parentFile
    val configFile = flutterProjectRoot.resolve("app_updater.yaml")
    require(configFile.isFile) {
        "Missing $configFile. Create it at your Flutter project root — see app_updater/README.md."
    }

    @Suppress("UNCHECKED_CAST")
    val data = configFile.inputStream().use { Yaml().load(it) as Map<String, Any?> }
    val appSlug = data["app_slug"] as? String
        ?: error("app_updater.yaml: app_slug is required")
    val backendUrl = data["backend_url"] as? String
        ?: error("app_updater.yaml: backend_url is required")
    @Suppress("UNCHECKED_CAST")
    val trustedKeys = (data["trusted_keys"] as? List<Map<String, Any?>>).orEmpty().joinToString(",") { entry ->
        val keyId = entry["key_id"] as? String ?: error("app_updater.yaml: trusted_keys entry missing key_id")
        val publicKey = entry["public_key"] as? String
            ?: error("app_updater.yaml: trusted_keys entry missing public_key")
        "$keyId:$publicKey"
    }
    @Suppress("UNCHECKED_CAST")
    val revokedKeyIds = (data["revoked_key_ids"] as? List<String>).orEmpty().joinToString(",")

    val flutterSdkPath = run {
        val properties = Properties()
        rootProject.file("local.properties").inputStream().use { properties.load(it) }
        properties.getProperty("flutter.sdk")
            ?: error("flutter.sdk not set in ${rootProject.file("local.properties")}")
    }
    val versionOutput = providers.exec {
        commandLine("$flutterSdkPath/bin/flutter", "--version", "--machine")
    }.standardOutput.asText.get()
    val engineRevision = Regex("\"engineRevision\":\\s*\"([0-9a-f]{40})\"").find(versionOutput)?.groupValues?.get(1)
        ?: error("Could not determine Flutter engine revision from `flutter --version --machine`")
    val dartVersion = Regex("\"dartSdkVersion\":\\s*\"([^\"]+)\"").find(versionOutput)?.groupValues?.get(1)
        ?: error("Could not determine Dart SDK version from `flutter --version --machine`")

    return mapOf(
        "otaAppSlug" to appSlug,
        "otaBackendUrl" to backendUrl,
        "otaSignatureTrustedKeys" to trustedKeys,
        "otaSignatureRevokedKeyIds" to revokedKeyIds,
        "otaEngineRevision" to engineRevision,
        "otaDartVersion" to dartVersion,
        // ota_core/manifest.schema.json only allows "release" today; see docs/next_steps.md.
        "otaBuildMode" to "release",
    )
}

android {
    namespace = "com.berkersaptas.app_updater"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            // The Flutter package is distributed as a git path dependency. Pub keeps the whole
            // repository checkout, so compile the canonical runtime sources directly instead of
            // requiring a separately published native dependency.
            java.srcDirs(
                "src/main/kotlin",
                projectDir.resolve("../../ota_runtime_android/src/main/kotlin"),
            )
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
        manifestPlaceholders.putAll(loadOtaAppConfig())
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("io.sigpipe:jbsdiff:1.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
