# Google Play production boundary

Status: implemented guardrails; policy interpretation must still be owned by the publisher.

## Rationale

Google Play's Device and Network Abuse policy generally prohibits an app from updating itself or
downloading executable code outside Google Play. The same policy contains an exception for code
that runs in a virtual machine or interpreter providing indirect access to Android APIs.

Shorebird publicly relies on that exception: patched Dart code runs through the Dart VM. Its
Android release artifacts contain architecture-specific `libapp.so` files, while patch artifacts
are binary diffs against those release artifacts. This project follows the same narrow Android
model: only Dart's AOT `libapp.so` may differ, the device downloads a diff, reconstructs the
release-bound Dart artifact locally, and the Flutter engine's Dart VM runs it.

Authoritative/current references:

- Google Play Device and Network Abuse policy:
  https://support.google.com/googleplay/android-developer/answer/16559646
- Android dynamic code loading security guidance:
  https://developer.android.com/privacy-and-security/risks/dynamic-code-loading
- Shorebird Store Compliance FAQ:
  https://docs.shorebird.dev/code-push/faq/#store-compliance
- Shorebird Code Push artifact model:
  https://docs.shorebird.dev/code-push/

This is a technical and policy rationale, not a Google certification or guarantee. The Play
publisher remains responsible for each app and every patch.

## Enforced production rules

1. The recommended `app_updater release android` command builds and registers the exact Play AAB as an
   immutable release/ABI base before that same AAB is uploaded to Play.
2. `app_updater patch android` downloads that registered base automatically; developers do not select
   or archive a local base APK.
3. Before uploading, the CLI compares the base and patch AAB contents. Only the target
   `base/lib/<abi>/libapp.so` and its
   `BUNDLE-METADATA/com.android.tools.build.debugsymbols/<abi>/libapp.so.sym` may change. The symbol
   file is generated from Dart's AOT library and is metadata, not executable device content.
4. Any manifest, DEX, Android resource, Flutter asset, Flutter engine, plugin, or other native
   library difference stops the publish and requires a new Play Store release.
5. The backend rejects `full_aot_library` uploads by default, including direct portal/API uploads
   that bypass the CLI.
6. The legacy `app_updater publish` command still requires the exact archived single-ABI APK through
   `--base-apk`; it is not the recommended connected workflow.
7. `full_aot_library` requires two deliberate local-POC opt-ins: the CLI flag
   `--allow-full-aot-library` and backend environment variable `ALLOW_FULL_AOT_LIBRARY=true`.
8. Backend and runtime exact-build checks (`base_sha256` plus protocol/release/engine/Dart/ABI/
   build-mode fingerprint), signature, and target artifact hash remain mandatory and fail closed.

## Release artifact custody

The backend stores the exact AAB, AAB SHA-256, base `libapp.so` SHA-256, build fingerprint, source
commit, Flutter engine revision, Dart version, and ABI registered by `app_updater release android`.
Release artifacts are immutable: do not rebuild a base
later from a tag and assume it is byte-identical. Production storage must be durable and backed up.
Legacy `app_updater publish` users remain responsible for equivalent immutable APK custody.

## Device verification

The connected workflow was verified on an arm64-v8a Xiaomi 2211133G running Android 16/API 36:
the base APK launched as `Hello v1`, a 34,608-byte managed-signing binary diff was downloaded and
staged, and the next cold launch verified patch 2 and displayed `Hello v2` with runtime state
`active`. A further check returned `OtaNoUpdateAvailable`.

## Product-use boundary

Use OTA patches for Dart-only bug fixes and changes consistent with the app purpose and store
listing. Native code, permissions, assets, Flutter/engine upgrades, material purpose changes, and
features that would make the store listing misleading require a normal reviewed store release.
