# Architecture and remaining work

Status: living project map.

This document summarizes what the project currently does, what it intentionally does not do yet,
and the remaining work required to move from the Android proof-of-concept toward a
Shorebird-aligned production architecture.

## Executive summary

The project is building a generic Flutter OTA runtime architecture, not a one-off patch path for the
sample app.

Current state:

- `ota_core` defines the platform-neutral patch contract.
- `ota_runtime_android` is a reusable, independently-publishable native Android runtime module,
  supporting both `full_aot_library` and `binary_diff` artifact kinds, both device-proven.
- `app_updater` is a Flutter/Dart package wrapping `ota_runtime_android` — the actual
  integration point for Flutter apps, `pubspec.yaml`-installed like any other package, not a native
  library apps wire in by hand. `sample_app` consumes `app_updater`, not
  `ota_runtime_android` directly.
- `backend/` is a real Postgres-backed HTTP service implementing
  `docs/production_installer_contract.md`, and `app_updater`/`ota_runtime_android`'s
  `OtaUpdateClient` calls it over a real network round trip, device-verified.
- `app_updater_cli` provides the connected `login → init → release android → patch android` lifecycle.
  Release AABs are immutable backend-managed bases, patch numbering/signing is server-managed, and
  this exact flow is verified through activation on Android 16/arm64.
- Patch lifecycle, signature verification, compatibility checks, rollback, quarantine, and
  bad-patch rejection are implemented on Android.
- `ota_runtime_ios` is intentionally only a contract skeleton.
- No Flutter engine fork exists, and Phase 2D's feasibility spike concluded none is needed for
  Android — see `engine_notes/phase_2_engine_feasibility.md`. Whether iOS needs one is still an open
  question (`docs/ios_runtime_decision.md`).

The current Android runnable artifacts are `full_aot_library` (whole `libapp.so` replacement) and
`binary_diff` (bsdiff-based, base artifact read from the installed APK), both proven on a real
device. Neither required an engine or embedding fork.

## Repository architecture

```text
ota_core/
  Platform-neutral manifest, signing payload, lifecycle, platform capabilities, and fixtures.

ota_runtime_android/
  Reusable Android runtime adapter. Reads patch state, verifies compatibility/signature/hash,
  rejects bad patches, resolves artifacts (full_aot_library or binary_diff), and passes a patched
  AOT library path to Flutter.

ota_runtime_ios/
  iOS contract skeleton. Models interpreted Dart patch artifacts and linked-code metadata, but does
  not execute patches.

app_updater/
  Flutter plugin package wrapping ota_runtime_android behind a Dart API (pubspec.yaml dependency,
  FlutterOtaActivity, AppUpdater.autoUpdate/checkForUpdate/markBootSuccess/status). What Flutter
  apps should actually depend on. See app_updater/README.md.

sample_app/
  Consumer app used to prove the app_updater integration path and acceptance flow.

backend/
  Postgres-backed HTTP service implementing the production installer contract: app/key registration,
  signed patch ingestion, patch-check, artifact download, patch events. Called by
  ota_runtime_android's OtaUpdateClient; device-verified. See backend/README.md.

scripts/
  Build, extract, manifest, signing, installation, and acceptance helpers.

docs/
  Phase plans, Shorebird alignment notes, key management, production installer contract, and runtime
  decisions.

engine_notes/
  Notes about Flutter engine loading, Android artifact behavior, and the Phase 2D engine
  feasibility spike.
```

## Runtime flow today

The current Android flow is:

1. Build a base release APK.
2. Build a patch APK from another Dart entrypoint.
3. Extract `libapp.so` from the patch APK.
4. Generate `patch_manifest.json` with:
   - release version;
   - patch number;
   - artifact kind;
   - Flutter engine revision;
   - Dart SDK version;
   - ABI;
   - build mode;
   - artifact SHA-256;
   - signature key id;
   - signature algorithm;
   - signature.
5. Install the patch artifact into app-private storage through the debug/test installer provider.
6. On next app launch, `ota_runtime_android` reads `ota/patch_state.json`.
7. The runtime rejects the patch unless all checks pass:
   - schema version;
   - trusted key id;
   - revoked key id list;
   - manifest signature;
   - release compatibility;
   - Flutter engine revision compatibility;
   - Dart SDK compatibility;
   - ABI compatibility;
   - build mode compatibility;
   - artifact resolver support;
   - artifact SHA-256.
8. If valid, the runtime marks the patch as `pending_boot` and returns:

   ```text
   --aot-shared-library-name=<app-private-path>/libapp.so
   ```

9. If the app reports success, the patch becomes `active`.
10. If the patch boot does not report success, the patch is failed, quarantined, and its patch
    number is written to `ota/bad_patches.json`.
11. A patch number in `bad_patches.json` is never booted again locally.

## Core contract

`ota_core` is the shared contract that Android, iOS, build scripts, and a future production updater
should all obey.

Current signed payload fields:

```text
schema_version
release
patch_number
artifact_kind
engine_revision
dart_version
abi
build_mode
sha256
signature_key_id
signature_algorithm
```

Current artifact kinds:

- `full_aot_library`: current Android POC path; loads a complete `libapp.so`.
- `binary_diff`: implemented, device-proven Android production direction; the backend accepts this
  artifact kind by default.
- `interpreted_dart_patch`: iOS contract direction in `ios_interpreted_patch.schema.json`.

Current signature algorithms:

- `ed25519`: default POC/dev path.
- `rsa_pkcs1_sha256`: Shorebird-aligned RSA/KMS-compatible path.

## Android runtime modules

Important classes:

- `FlutterOtaRuntime`: public entrypoint used by the Android embedding integration.
- `PatchLoader`: boot-time decision maker.
- `PatchStateStore`: atomic state file reader/writer for `ota/patch_state.json`.
- `OtaLifecycleStore`: last-known-good metadata, quarantine, and cleanup.
- `BadPatchStore`: local `ota/bad_patches.json` persistence.
- `PatchSignatureVerifier`: Ed25519 and RSA PKCS#1 SHA-256 verification.
- `PatchArtifactResolver`: artifact abstraction boundary.
- `FullAotLibraryArtifactResolver`: runnable local POC resolver; backend-disabled by default.
- `BinaryDiffArtifactResolver`: implemented Shorebird-style Android production resolver.
- `OtaInstallProvider`: debug/test-only shell ingress for acceptance testing.

## Lifecycle model

Patch states:

- `none`: no patch.
- `pending`: installed and ready for a future launch.
- `pending_boot`: selected for this boot, waiting for app success report.
- `active`: successfully launched and confirmed.
- `failed`: rejected or failed.
- `disabled`: explicitly disabled.

Bad patch rule:

- Static verification failures such as hash mismatch, signature mismatch, release mismatch, engine
  mismatch, ABI mismatch, or missing artifact do not automatically burn a patch number.
- A patch number becomes bad only after the runtime actually attempts patched boot and the app does
  not report boot success.

This distinction matters because “not compatible with this device/release” and “this patch crashes”
are different failure classes.

## Signing, custody, rotation, and revocation

Current implementation:

- Manifest signatures cover the canonical payload fields listed above.
- Runtime checks key revocation before trust.
- Trusted keys are embedded into the APK through `ota.properties`.
- `scripts/build_patch.sh` supports local PEM signing.
- `scripts/build_patch.sh` also supports `OTA_SIGN_CMD`, where a command reads canonical payload
  from stdin and returns a base64/base64url signature.
- `scripts/verify_signature_algorithms.sh` verifies local Ed25519 and RSA PKCS#1 SHA-256 signing
  behavior.

Production intent:

- Private keys must not live in the app repository or APK.
- CI should sign via HSM/KMS or an equivalent controlled signer boundary.
- App releases should rotate keys with overlap:
  1. release trusts key `A`;
  2. release trusts `A` and `B`;
  3. signer moves to `B`;
  4. later release drops `A`;
  5. compromised keys are placed in `signatureRevokedKeyIds`.

Remaining signing work:

- Add `OTA_SIGN_CMD` fixture tests that simulate a KMS command boundary.
- Add public-key publication tooling for command/KMS mode.
- Add CI coverage for both Ed25519 and RSA manifests.

## iOS architecture position

iOS must not copy Android's `libapp.so` replacement model.

Current iOS state:

- `ota_runtime_ios` is a contract skeleton only.
- `OtaPatchArtifact` models an interpreted Dart patch artifact.
- `OtaLinkedCodeMetadata` models linked/interpreted function counts and minimum link percentage.
- `OtaRuntimeIOS.launchPatch` intentionally returns unavailable.
- `ota_core/ios_interpreted_patch.schema.json` defines the JSON contract for interpreted Dart patch
  metadata.

What is missing:

- interpreter payload format;
- linker metadata generation;
- modified runtime/engine support;
- runtime execution;
- performance threshold enforcement;
- App Store policy review documentation.

## Flutter engine / Dart VM status

No Flutter fork, Dart VM fork, or modified engine has been implemented yet.

This is intentional. The current project first proves the OTA shell around patching:

- manifest contract;
- signing;
- compatibility binding;
- lifecycle;
- rollback;
- bad-patch rejection;
- Android boot-time artifact selection.

Real Shorebird-style Dart code patching still requires deeper engine/runtime work.

Open engine questions:

- Is a Flutter engine fork required, or can a smaller embedding/runtime integration satisfy the
  Android production path?
- Which engine/Dart VM loading points must change for `binary_diff`?
- What is the minimum viable Android binary-diff apply pipeline?
- How are patch artifacts generated from release artifacts?
- How should base release artifacts be stored or reconstructed for patch apply?
- How does the iOS interpreted Dart path integrate with runtime/linker support?
- Which parts can be reused from public Shorebird concepts, and which parts require independent
  implementation?

## What is proven

The Android acceptance suite has proven:

- clean base APK boots;
- compatible patch activates and shows patched UI;
- invalid signature is rejected before activation;
- SHA-256 mismatch is rejected;
- Flutter engine mismatch is rejected;
- Dart SDK mismatch is rejected;
- base release mismatch is rejected;
- ABI mismatch is rejected;
- build-mode mismatch is rejected;
- missing artifact is rejected;
- unconfirmed patched boot rolls back;
- bad patch number is refused on a later attempt;
- compatible patch can be restored and left active.

Manually on a real device (not yet folded into the scripted acceptance suite), `binary_diff` has
additionally proven:

- a real `binary_diff` patch, built from this project's own `sample_app` two-entrypoint build,
  reconstructs and activates correctly (`Hello v2`), reading its base artifact from the installed
  APK's own packaged `libapp.so`;
- reconstruction is cached — a repeat launch of an already-active `binary_diff` patch does not
  re-invoke bspatch;
- a corrupted diff blob is rejected cleanly (no crash), and the app falls back to the base APK
  (`Hello v1`);
- a real diff was 7,128 bytes against a 2,884,496-byte full artifact (99.75% smaller).

Manually against a real Docker Compose stack (Postgres + `backend/`), the backend has proven:

- app registration, trusted-key registration, and signed patch upload, using the exact manifest and
  `binary_diff` artifact produced and device-verified above;
- schema validation, signature verification (against the real registered key, using the same
  canonical payload format the device verifies), and rejection of a tampered signature before
  storage;
- patch-check finds the uploaded patch; the downloaded artifact bytes match the uploaded ones
  exactly; a posted event is persisted in Postgres; disabling a patch removes it from patch-check
  results;
- 401 without the admin API key, 404 for an unknown app.

On a real Android device talking to the real Dockerized backend over the network (via `adb
reverse`), the full client-to-backend loop has proven:

- `OtaUpdateClient` finds and installs a real RSA-signed `binary_diff` patch without activating it
  the same launch; the following launch boots it normally (`PatchLoader` treats a
  network-installed patch identically to a locally-installed one); a further launch correctly
  reports no update available once current;
- `rsa_pkcs1_sha256` verifies correctly on-device end to end through this path; `ed25519`
  verification fails on at least one real device (Android 10/API 29) due to platform JCA support,
  not a bug in this project — see the Phase 2B section below;
- install/success/failure events reach Postgres correctly, including a real failure event from the
  `ed25519` finding above.
- the connected CLI/managed-signer path itself: a 15.4 MB registered AAB produced a 34,608-byte
  visible `Hello v2` diff; launch 1 stayed on `Hello v1` while staging, launch 2 verified RSA and
  activated patch 2, and runtime state was persisted as `active` on Android 16/API 36;
- stale restored test state signed by another key is rejected without booting it; the update client
  can then download the valid release-bound patch and recover on the next launch.

Additional local checks have proven:

- script syntax validity;
- canonical manifest fixture generation;
- Ed25519 signature behavior;
- RSA PKCS#1 SHA-256 signature behavior;
- `OTA_SIGN_CMD`/`OTA_PUBLIC_KEY_CMD` command-based signing/publication boundary, for both
  algorithms, against a fake KMS command;
- `ota_core/manifest.schema.json` JSON Schema validation of the manifest fixture, including
  rejection of invalid manifests;
- `ota_core/ios_interpreted_patch.schema.json` JSON Schema validation of an iOS patch fixture,
  including rejection of invalid linked-code metadata;
- `binary_diff` round-trip correctness: a build-time-generated bsdiff patch applied through the same
  `io.sigpipe.jbsdiff.Patch.patch()` API `BinaryDiffArtifactResolver` uses on-device reproduces the
  patched artifact exactly (`scripts/verify_binary_diff.sh`);
- Android Kotlin compilation, including `ota_runtime_android` with the new `jbsdiff` dependency and
  `:app`'s consumption of it;
- Flutter analyzer and widget test pass.

## What is not proven yet

- The iOS interpreter/linker runtime patch path (a modified engine may still be required there;
  unlike Android, this has not been ruled out — see `docs/ios_runtime_decision.md`).
- iOS patch execution.
- Install resume support (a download interrupted mid-transfer is not resumed, just retried whole on
  the next check).
- AAR/Maven packaging.
- Instrumentation tests for atomic state corruption.
- Multi-device Android API/OEM matrix.
- CI-backed KMS/HSM signer integration.
- CDN, admin UI, staged rollout percentages, or multi-user auth on the backend (single static API
  key today).

## Remaining work by phase

### Phase 2A: signing and fixture hardening

- Done: `scripts/verify_sign_command.sh` adds `OTA_SIGN_CMD` fixture tests with a fake KMS signer
  command, covering both `ed25519` and `rsa_pkcs1_sha256`.
- Done: `OTA_PUBLIC_KEY_CMD` is wired into `scripts/generate_compatibility_metadata.sh` as the
  public-key command/publication workflow, alongside the existing file-based path.
- Done: `scripts/validate_json_schema.py` plus `scripts/verify_manifest_schema_fixture.sh` add
  manifest validation tests outside shell parsing.
- Done: `scripts/verify_ios_patch_fixture.sh` adds an iOS interpreted patch schema fixture and
  validation.

### Phase 2B: production installer contract

Backend implemented (2026-08-17). See `backend/README.md` for the full endpoint list and a `curl`
walkthrough verified against a real, device-proven `binary_diff` patch from this project's own
`sample_app`.

- Done: a real Node + Express + Postgres backend (`backend/`) implements
  `docs/production_installer_contract.md` — app registration, trusted-key registration/revocation,
  signed patch upload (schema validation, signature verification, hash verification), patch-check,
  artifact download, and patch event ingestion.
- Done: Docker Compose (`docker-compose.yml`) brings up Postgres + the backend together; the schema
  (`backend/migrations/001_init.sql`) applies automatically on first boot.
- Done: manually verified end to end with `curl` — register app, register key, upload the real
  `binary_diff` patch this session's Phase 2E work produced and device-verified, patch-check finds
  it, downloaded bytes match exactly, event lands in Postgres, disabling the patch removes it from
  patch-check results. Negative paths verified too: missing admin key (401), unknown app (404), and
  a tampered signature (rejected before storage).
- Done: signature verification on ingest reuses the exact canonical-payload format
  `scripts/write_manifest_payload.sh` defines and Node's built-in `crypto.verify` — no new crypto
  dependency, same algorithm behavior as `PatchSignatureVerifier.kt`.
- Done: `OtaUpdateClient` (`ota_runtime_android/.../OtaUpdateClient.kt`) implements the device side —
  patch-check, download, signature/schema verification, staging — and is device-verified against
  this backend over a real network round trip (2026-08-17). See "Client wiring, device-verified"
  below.
- Kept as-is (not replaced): the debug/test shell `ContentProvider` (`OtaInstallProvider.kt`) still
  exists for device acceptance testing; the shared verification logic was refactored into
  `PatchInstaller` so both ingress paths (shell provider and network client) enforce identical
  checks.
- Done: `scripts/run_binary_diff_acceptance.sh` (2026-08-17) scripts this entire flow repeatably —
  RSA-signed `binary_diff` patch staged/activated/steady-state through `app_updater`, plus a
  storage-corrupted patch staged then correctly rejected on reconstruction with fallback to base,
  plus Postgres event verification. Resets the backend and reinstalls the app each run.
- Not done: install resume support.

### Client wiring, device-verified (2026-08-17)

`OtaUpdateClient` was exercised end to end on a real Android device against the real Dockerized
backend (via `adb reverse`), with a real RSA-signed `binary_diff` patch built from this project's
own `sample_app`:

- Launch 1: `OtaUpdateClient` found and installed patch 2 as `pending` (called only *after*
  `markBootSuccess`, not from `onCreate` — see the race-condition note below); the boot itself
  correctly stayed on the previously active artifact (`Hello v1`/base).
- Launch 2: `PatchLoader` picked up the staged patch normally, exactly as it would for a
  locally-installed patch — `Verified binary_diff patch 2; attempting patched boot` then `Patch 2 is
  active`; UI showed `Hello v2`.
- Steady state: a third launch correctly reported `no update available` once the device was already
  on the newest patch.
- All events (`PatchInstallStarted`/`PatchInstallSuccess`/`PatchInstallFailure`) landed in Postgres
  as expected, including a real failure event from the finding below.

**Real finding: `ed25519` verification is unavailable on Android 10 (API 29).** The first device
tried for this test (a different, older device than Phase 2E's) rejected an otherwise-valid
`ed25519`-signed patch with "signature could not be verified" — not a bug in this session's code,
but `KeyFactory.getInstance("Ed25519")`/`Signature.getInstance("Ed25519")` throwing
`NoSuchAlgorithmException` on that OS version (Ed25519 JCA/Conscrypt support is a newer-Android
feature), silently caught by `PatchSignatureVerifier`'s catch-all and treated as a normal
verification failure. Switching to an `rsa_pkcs1_sha256`-signed patch (`SHA256withRSA`, supported on
all API levels this project targets) resolved it immediately — this is exactly the situation
`docs/key_management.md`'s dual-algorithm support exists for. This is worth remembering when
deciding a default signing algorithm for a real 30-40-app fleet with a real Android version spread:
`rsa_pkcs1_sha256` is the safer default; `ed25519` should be treated as opt-in for known-modern
devices, not the default, until this is characterized further (which Android version actually added
Ed25519 JCA support was not pinned down precisely here).

**Real bug found and fixed: a state-mutation race.** The first wiring attempt called
`OtaUpdateClient.checkForUpdate` from `MainActivity.onCreate`, racing
`FlutterOtaRuntime.engineArgsForThisBoot()`/`markBootSuccess()`, which synchronously read/write the
same `ota/patch_state.json` earlier in the same boot on the main thread. Moved the call to run only
after `markBootSuccess()` returns; documented the ordering requirement directly on
`OtaUpdateClient`'s class doc comment so future integrators do not reintroduce it.

This entire flow was later re-run, unchanged in outcome, through the `app_updater` Flutter
plugin path (Phase 2C) instead of calling `OtaUpdateClient` from native code directly — see that
section for the device proof through `AppUpdater.instance.autoUpdate(...)`.

- Not done: staged rollout percentages, release channels beyond a single `stable` default, CDN, and
  admin UI.

### Phase 2C: Android runtime packaging

Done (2026-08-17), with two real findings fixed along the way — the second prompted by explicit
user feedback that this had to be consumable as a Flutter package, not a raw native library.

- Done: `ota_runtime_android` is now a standalone Gradle build (its own `settings.gradle.kts`,
  `gradlew` — not a subproject of `sample_app/android`) that publishes a real AAR + POM to a local
  flat-file Maven repository (`cd ota_runtime_android && ./gradlew publish` → `maven-repo/`), with
  its `io.sigpipe:jbsdiff` dependency correctly declared transitively.
- **Real finding #1, fixed:** the module was baking one specific app's compatibility fingerprint and
  trusted keyring into its own `BuildConfig` at the module's own build time (reading
  `rootProject.file("ota.properties")` directly). Fixed via `OtaRuntimeConfig`, which reads
  `<meta-data>` on the *consuming* app's own `<application>` tag at runtime instead (the standard
  pattern used by e.g. Firebase/Maps SDKs). The exact same bug also existed for the debug
  `ContentProvider`'s enabled flag (`otaRuntimeInstallerEnabled` Gradle property baked in at publish
  time); fixed by hardcoding it disabled in the library's own manifest and having consuming apps
  re-enable it via Android manifest merging (`tools:replace="android:enabled"`) instead.
- **Real finding #2, a course correction:** the first cut of this phase published
  `ota_runtime_android` as a raw Android library and stopped there — a Flutter app developer would
  still need to hand-edit `MainActivity.kt`, `AndroidManifest.xml`, and `build.gradle.kts` three
  separate ways to use it. That is not how Flutter packages are consumed, and not how Shorebird ships
  (`shorebird_code_push` is a normal pub package with a Dart API). Added `app_updater/`, a real
  Flutter plugin: `pubspec.yaml`-installable, Dart-facing (`AppUpdater.autoUpdate`/
  `checkForUpdate`/`markBootSuccess`/`status`), with `FlutterOtaActivity` absorbing the one native
  touch point that cannot move to Dart (the patched-artifact-before-engine-start requirement). See
  `app_updater/README.md`.
- Done: `sample_app` was migrated to depend on `app_updater` via `pubspec.yaml` only — no
  Gradle project reference to `ota_runtime_android`, `MainActivity.kt` reduced to
  `class MainActivity : FlutterOtaActivity()`, boot-success/update-check moved to Dart
  (`lib/app.dart`). Verified end to end on a real device through this exact path: a real
  RSA-signed `binary_diff` patch served from the real Dockerized backend, found/downloaded/verified/
  installed via `AppUpdater.instance.autoUpdate(...)` alone, activated correctly on the next
  launch (`Hello v2`).
- **Real finding #3, a further course correction:** even after the plugin existed, integrating it
  still meant hand-writing 5 `<meta-data>` entries in the app's `AndroidManifest.xml` plus
  `manifestPlaceholders`-reading boilerplate in the app's `build.gradle.kts` — explicit user
  feedback was that adding this package to a Flutter project should need **no platform-specific
  config at all**, Android or iOS. Fixed by moving all app-supplied config into a single
  `<flutter-project-root>/app_updater.yaml` (app slug, backend URL, trusted keys), consumed
  entirely by `app_updater/android/build.gradle.kts` at the *consuming app's* build time: it
  reads the YAML, runs `flutter --version --machine` itself (via `providers.exec`, since
  `Project.exec` was removed in Gradle 9) to derive engine/Dart versions, and writes the result into
  `<meta-data>` inside its own manifest, which merges into the app's final manifest. `sample_app`'s
  own `AndroidManifest.xml` and `build.gradle.kts` now carry zero OTA-specific config; `main()`
  calls `AppUpdater.instance.autoUpdate()` with no arguments. Re-verified end to end on a real
  device through this exact zero-config path (RSA-signed `binary_diff` patch found, verified,
  installed, activated). `app_updater.yaml` is deliberately platform-agnostic so an eventual iOS
  build-phase script can consume the identical file — see `docs/next_steps.md`.
- Done: public API is `FlutterOtaRuntime`, `OtaRuntimeStatus`, `OtaUpdateClient`/`OtaUpdateConfig`/
  `OtaUpdateResult`, `OtaManifestContract` on the native side, and `AppUpdater`/
  `OtaUpdateResult`/`OtaRuntimeStatus` on the Dart side.
- Done: integration documented in `app_updater/README.md` (the primary guide) and
  `docs/generic_runtime_integration.md` (the underlying contract).
- Superseded (2026-08-21): no runtime Maven/JitPack distribution is required by the git-installed
  Flutter plugin. It compiles the canonical sibling `ota_runtime_android` sources from Pub's full
  repository checkout and resolves only the public `jbsdiff` dependency from Maven Central.
- Done: `scripts/run_binary_diff_acceptance.sh` scripts the `app_updater`-path device
  verification that was manual here (see Phase 2E). `scripts/run_device_acceptance.sh` still
  targets the debug `ContentProvider` directly and is unchanged/unaffected by `app_updater`.
- Not done: an iOS equivalent of `app_updater` — blocked on `ota_runtime_ios` actually executing
  patches (Phase 2F), not a packaging question.

### Phase 2D: engine feasibility spike

Done. See `engine_notes/phase_2_engine_feasibility.md`.

- Engine feasibility report written.
- Flutter engine / Dart VM touch points mapped: none — `binary_diff` reuses the proven
  `FlutterLoader` AOT override path unchanged; only artifact production/reconstruction differs.
- Decision: no Flutter engine fork is required.
- Minimum viable Android `binary_diff` patch apply design defined (base artifact lookup, diff
  format, build-time and device-time pipelines).
- Decision: iOS contract work (Phase 2F) proceeds in parallel with Android `binary_diff`
  (Phase 2E); neither blocks the other.

### Phase 2E: Android binary-diff prototype

Device-verified (2026-08-17). See `engine_notes/phase_2_engine_feasibility.md` for full detail.

- Done: `BinaryDiffArtifactResolver` replaced with a real pipeline (base artifact read from the
  installed APK, `io.sigpipe:jbsdiff` bspatch apply, cached reconstruction, atomic write).
- Done: base artifact lookup defined, implemented, and device-verified (APK zip-entry read against a
  real installed APK).
- Done: `scripts/build_patch.sh` generates the diff artifact at build time via
  `scripts/generate_binary_diff.sh` (same jbsdiff library, CLI mode) when `OTA_ARTIFACT_KIND=binary_diff`.
- Done: `scripts/verify_binary_diff.sh` proves the build-time-generated diff round-trips correctly
  through the same on-device `Patch.patch()` API call `BinaryDiffArtifactResolver` uses.
- Done: hash validation after apply — reuses `PatchLoader`'s existing kind-agnostic SHA-256 check
  against the reconstructed artifact; no artifact-kind-specific verification code was needed.
- Done: apply-failure rollback and corruption handling verified on-device (a bit-flipped diff was
  rejected cleanly through the existing generic `fail()`/quarantine path, no crash, fell back to the
  base APK).
- Done: real-world size proof from this project's own `sample_app` build — a 2,884,496-byte
  `libapp.so` produced a 7,128-byte diff (99.75% smaller).
- Done: `scripts/run_binary_diff_acceptance.sh` scripts this repeatably (see Phase 2C).

### Phase 2F: iOS contract validation

- Add iOS interpreted patch fixture.
- Validate `linked_code_metadata`.
- Enforce minimum link percentage in the contract layer.
- Keep runtime launch unavailable until interpreter/runtime support exists.

## Current decision points

The Android product path is complete through connected CLI publishing and real-device activation.
iOS code push is intentionally retired from the roadmap. Remaining work is operational production
hardening rather than another runtime phase: HTTPS/reverse proxy, durable artifact storage/CDN,
managed Postgres and backups, monitoring/alerting, staged rollout controls, managed signer rotation,
and moving signing custody to KMS/HSM. `docs/next_steps.md` is the living source of truth.
