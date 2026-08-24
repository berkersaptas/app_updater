# Generic Android runtime integration

The OTA runtime is layered:

```text
ota_core            platform-neutral manifest, signing payload, lifecycle, capability contract
ota_runtime_android  Android runtime: patch state, verification, compatibility, lifecycle (native)
app_updater      Flutter/Dart package wrapping the above — what Flutter apps should depend on
```

`ota_runtime_android` owns:

- patch state and atomic persistence
- signed manifest verification
- Flutter/Dart/ABI/release compatibility checks
- lifecycle state transitions
- last-known-good and quarantine retention
- engine argument generation for `--aot-shared-library-name`

**Flutter apps should depend on `app_updater`, not `ota_runtime_android` directly.** A raw
native Android library requiring hand-edited `MainActivity.kt`/`AndroidManifest.xml`/
`build.gradle.kts` wiring is not how Flutter packages are normally consumed — Shorebird itself ships
as a pub package (`shorebird_code_push`) with a Dart API, not a native library app developers wire
in by hand. `app_updater/README.md` is the integration guide; this document describes the
underlying contract both layers are built on, for anyone building a second Dart wrapper (e.g. an iOS
one) or working on `ota_runtime_android` itself.

## What a Dart wrapper needs to provide, and why

1. **The compatibility fingerprint, trusted keyring, app slug, and backend URL**, supplied by the
   *app*, not baked into the runtime — `<meta-data>` on the app's own `<application>` tag
   (`com.berkersaptas.app_updater.ota_runtime.ENGINE_REVISION`, `DART_VERSION`, `BUILD_MODE`,
   `SIGNATURE_TRUSTED_KEYS`, `SIGNATURE_REVOKED_KEY_IDS`, `APP_SLUG`, `BACKEND_URL`). This is what
   lets one published `ota_runtime_android` artifact serve many different apps — see
   `docs/architecture_and_remaining_work.md`'s Phase 2C section for the finding that motivated this.
   A missing required key fails fast at runtime (`OtaRuntimeConfig.from`) rather than silently using
   wrong values.

   `app_updater` generates these `<meta-data>` entries automatically — the app never writes
   them. `app_updater/android/build.gradle.kts` reads a single
   `<flutter-project-root>/app_updater.yaml` (app slug, backend URL, trusted keys) plus the
   project's own Flutter toolchain (`flutter --version --machine`, run at build time) and populates
   its own manifest's placeholders, which merge into the app's final manifest. A raw Android
   library wrapper would instead read `manifestPlaceholders` from `android/ota.properties`
   (`scripts/generate_compatibility_metadata.sh`) in the *app's own* `build.gradle.kts` — that
   pattern still exists in `ota_runtime_android`'s contract for a hypothetical non-Flutter or
   non-`app_updater` native consumer, but no app should need to write it directly anymore.

2. **One native touch point that cannot move to Dart**: the patched AOT artifact must be selected
   *before* the Flutter engine (and therefore the Dart VM) exists —
   `FlutterOtaRuntime(context).engineArgsForThisBoot()` passed into `FlutterEngine`'s constructor
   inside `provideFlutterEngine()`. `app_updater` packages this as `FlutterOtaActivity`, a
   `FlutterActivity` subclass apps extend directly instead of writing this themselves.

3. **A boot-success signal** after Dart renders its first frame — `FlutterOtaRuntime.markBootSuccess()`
   — and, optionally, **a network update-client** (`OtaUpdateClient`, implementing
   `docs/production_installer_contract.md` against `backend/`) called only *after* boot success
   completes, never from `onCreate`/`provideFlutterEngine` (it reads/writes `ota/patch_state.json`
   on a background thread and would race the current boot's own synchronous state transitions
   otherwise — a real bug found and fixed during Phase 2B device verification). Both of these are
   ordinary post-engine-startup calls, so `app_updater` exposes them as plain Dart methods
   (`markBootSuccess()`, `checkForUpdate()`, and the `autoUpdate()` convenience that sequences them
   correctly) with no native code required from the app.

The debug/test-only `ContentProvider` (`OtaInstallProvider`) defaults to disabled in
`ota_runtime_android`'s own manifest (a published artifact must default safe for every consumer).
`sample_app` re-enables it explicitly via Android manifest merging
(`tools:replace="android:enabled"` — see `sample_app/android/app/src/main/AndroidManifest.xml`),
not a library build-time flag.

## Runtime boundary

`ota_runtime_android` does not know about `Hello v1`, `Hello v2`, package-specific UI, or the sample
application's Dart entrypoints. It only knows how to select and validate a compatible Flutter AOT
artifact from app-private storage.

## Current Gradle compatibility note

The pinned Flutter/AGP combination still requires `android.newDsl=false` and
`android.builtInKotlin=false` in Gradle projects touching this runtime (`sample_app/android`,
`ota_runtime_android`, `app_updater/android`). Removing those flags currently breaks the Flutter
Gradle plugin before app compilation. Treat this as a toolchain migration task rather than runtime
behavior.
