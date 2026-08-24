# Android OTA runtime module

This is the native Android layer of the OTA runtime. **Flutter apps should not depend on this
module directly** — depend on `../app_updater` instead, which wraps this as a normal Dart
package. This module exists as a standalone, independently publishable Android library so
`app_updater` (or any other native/Dart wrapper, e.g. a future one built directly rather than
through Flutter) has something real to depend on.

It is a standalone Gradle build (its own `settings.gradle.kts`, `gradlew`) — not a subproject of
`sample_app/android` — specifically so it can be built and published without any consuming app
present, the way an independently distributed library needs to be.

Public API:

- `FlutterOtaRuntime.engineArgsForThisBoot()`
- `FlutterOtaRuntime.markBootSuccess()`
- `FlutterOtaRuntime.status()`
- `OtaRuntimeStatus`
- `OtaUpdateClient.checkForUpdate(config, callback)` — network update-client; see
  `docs/generic_runtime_integration.md`
- `OtaUpdateConfig`, `OtaUpdateResult`
- `OtaManifestContract`

`status()`'s `circuitOpen` field reflects the cross-patch failure circuit breaker; `BootWatchdog`
guards against a patched boot that hangs instead of crashing. See "Hang protection" and "Circuit
breaker" in `../docs/rollback_model.md` for what these cover.

## Tests

JVM unit tests (Robolectric — no emulator/device needed) live under `src/test/kotlin/`. Run them
with:

```
./gradlew testDebugUnitTest
```

These cover invalid/corrupt on-disk state, the hash-mismatch and unfinished-boot fail-closed paths,
the atomic-write guarantee, the circuit breaker, and `BootWatchdog`. They complement, not replace,
the on-device acceptance scripts in `../scripts/` (`run_device_acceptance.sh`,
`run_binary_diff_acceptance.sh`), which are still the source of truth for real-device behavior.

## App-supplied configuration

This module does **not** bake any one app's compatibility fingerprint or trusted keyring into its
own build — that would make a single published artifact unusable by any app but the one it was
built for. Instead, each consuming app supplies its own values at runtime via `<meta-data>` on its
own `<application>` tag (the standard pattern used by e.g. Firebase/Maps SDKs):

```xml
<meta-data android:name="com.berkersaptas.app_updater.ota_runtime.ENGINE_REVISION" android:value="${otaEngineRevision}" />
<meta-data android:name="com.berkersaptas.app_updater.ota_runtime.DART_VERSION" android:value="${otaDartVersion}" />
<meta-data android:name="com.berkersaptas.app_updater.ota_runtime.BUILD_MODE" android:value="${otaBuildMode}" />
<meta-data android:name="com.berkersaptas.app_updater.ota_runtime.SIGNATURE_TRUSTED_KEYS" android:value="${otaSignatureTrustedKeys}" />
<meta-data android:name="com.berkersaptas.app_updater.ota_runtime.SIGNATURE_REVOKED_KEY_IDS" android:value="${otaSignatureRevokedKeyIds}" />
```

populated via `manifestPlaceholders` in the app's own `build.gradle.kts`, typically read from that
app's own `ota.properties` (see `scripts/generate_compatibility_metadata.sh`; `sample_app`'s
`app/build.gradle.kts` is the reference example). Missing required keys fail fast with a clear
error (`OtaRuntimeConfig.from`) rather than silently falling back to wrong values.

The same reasoning applies to the debug/test-only `ContentProvider` (`OtaInstallProvider`): it
defaults **hardcoded disabled** in this module's own manifest (a published artifact must default
safe for every consumer — a Gradle-property-driven placeholder would bake whichever app happened to
run `publish` last into the shared artifact, which is exactly the bug this session found and fixed).
A test/sample app re-enables it explicitly via Android manifest merging:

```xml
<!-- consuming app's AndroidManifest.xml, inside <application>, with xmlns:tools declared -->
<provider
    android:name="com.berkersaptas.app_updater.ota_runtime.OtaInstallProvider"
    android:enabled="true"
    tools:replace="android:enabled" />
```

Production integrations should leave it disabled and use `OtaUpdateClient` (via `app_updater`)
against a real backend instead.

## Publishing and consuming as a package

```bash
cd ota_runtime_android
./gradlew publish
```

publishes a real AAR + POM to a local flat-file Maven repository at `<repo-root>/maven-repo/`
(`com.app_updater:ota_runtime_android:0.1.0`), including its `io.sigpipe:jbsdiff` dependency. This was
verified two ways: `app_updater/android/build.gradle.kts` depends on it via these exact Maven
coordinates (not source-include), and `sample_app` — depending only on `app_updater` via
`pubspec.yaml` — built and ran correctly on a real device end to end.

Distributing `maven-repo/` to other apps' build machines (a self-hosted Maven/Nexus-style registry,
object storage, or similar) is not set up yet — this only proves the packaging mechanics work. Any
consumer (including `app_updater` and `sample_app` today) needs `maven-repo/`'s location added
to its own root Gradle `repositories {}` until real hosting exists — see `docs/next_steps.md`.

## Shorebird alignment

This module is aligned with Shorebird's Android direction at the lifecycle level:

- release-bound patches
- Dart-code-only patch scope
- boot-time patch selection
- bad-patch fallback
- last-known-good behavior
- signed patch support

Shorebird Android patch artifacts are diffs applied against release artifacts. This module supports
both `artifact_kind`s through the same `PatchArtifactResolver` abstraction, without changing the
app-facing runtime API:

- `full_aot_library`: a full replacement `libapp.so`, staged directly. Device-proven.
- `binary_diff`: a bsdiff-format diff (`io.sigpipe:jbsdiff`, pure JVM) applied on-device against the
  base APK's own packaged `libapp.so` to reconstruct the loadable artifact, cached per patch number.
  Device-proven, including over a real network round trip through `OtaUpdateClient` against
  `backend/`. See `engine_notes/phase_2_engine_feasibility.md`.

`ed25519` signature verification is not available on all devices (confirmed failing on a real
Android 10/API 29 device; `rsa_pkcs1_sha256` worked immediately on the same device). See
`docs/key_management.md`.
