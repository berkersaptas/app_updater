package com.berkersaptas.app_updater.ota_runtime

object OtaManifestContract {
    const val CORE_SPEC = "ota_core/manifest.schema.json"
    const val CORE_SIGNING_PAYLOAD = "ota_core/signing_payload_v1.txt"
    const val SCHEMA_VERSION = 1
    const val ARTIFACT_NAME = "libapp.so"
    const val ARTIFACT_DIFF_NAME = "libapp.so.diff"
    const val ARTIFACT_RECONSTRUCTED_NAME = "libapp.reconstructed.so"
    const val ARTIFACT_KIND_FULL_AOT_LIBRARY = "full_aot_library"
    const val ARTIFACT_KIND_BINARY_DIFF = "binary_diff"
    const val SIGNATURE_ALGORITHM_ED25519 = "ed25519"
    const val SIGNATURE_ALGORITHM_RSA_PKCS1_SHA256 = "rsa_pkcs1_sha256"
    const val INSTALLER_AUTHORITY_SUFFIX = ".ota-installer"
    const val METHOD_ACTIVATE = "activate"
    const val METHOD_LIFECYCLE_STATUS = "lifecycleStatus"
    const val METHOD_RESET = "reset"
    const val STATE_PATH = "state"

    // <meta-data> keys a per-app compatibility fingerprint/keyring/config is supplied through, so
    // a single published ota_runtime_android artifact can serve many different apps. When
    // consumed through app_updater, these are generated automatically at build time from
    // <flutter-project-root>/app_updater.yaml — nothing to hand-edit. See OtaRuntimeConfig,
    // docs/generic_runtime_integration.md, and app_updater/README.md.
    const val META_DATA_ENGINE_REVISION = "com.berkersaptas.app_updater.ota_runtime.ENGINE_REVISION"
    const val META_DATA_DART_VERSION = "com.berkersaptas.app_updater.ota_runtime.DART_VERSION"
    const val META_DATA_BUILD_MODE = "com.berkersaptas.app_updater.ota_runtime.BUILD_MODE"
    const val META_DATA_SIGNATURE_TRUSTED_KEYS = "com.berkersaptas.app_updater.ota_runtime.SIGNATURE_TRUSTED_KEYS"
    const val META_DATA_SIGNATURE_REVOKED_KEY_IDS = "com.berkersaptas.app_updater.ota_runtime.SIGNATURE_REVOKED_KEY_IDS"
    const val META_DATA_APP_SLUG = "com.berkersaptas.app_updater.ota_runtime.APP_SLUG"
    const val META_DATA_BACKEND_URL = "com.berkersaptas.app_updater.ota_runtime.BACKEND_URL"
}
