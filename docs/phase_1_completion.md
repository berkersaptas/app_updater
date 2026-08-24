# Phase 1 completion

Status: complete.

Phase 1 answered the narrow technical question: can a Flutter Android release shell select a
verified Dart AOT artifact from app-private storage, reject unsafe or incompatible patches, and
fall back to the APK-packaged base artifact?

The answer for the pinned Android proof environment is yes.

## Scope

Phase 1 covered Android only:

- Flutter release AOT artifact selection for `libapp.so`
- app-private patch storage
- signed patch manifest verification
- exact compatibility checks
- safe fallback to the APK-packaged base artifact
- boot-success confirmation and rollback
- last-known-good metadata and bounded quarantine
- reusable Android runtime module extraction
- platform-neutral `ota_core` contract extraction

Phase 1 did not cover production rollout, backend delivery, CDN, admin tooling, iOS runtime
implementation, App Store/Play policy approval, or broad Android OEM/API certification.

## Evidence

The full acceptance suite passed on an arm64-v8a Android 16 device:

```text
PASS: all Android OTA phase-1 acceptance scenarios succeeded
```

The suite validated:

- clean base APK launch: `Hello v1`
- compatible signed patch activation: `Hello v2`
- tampered manifest/signature rejection
- SHA-256 mismatch rejection
- Flutter engine revision mismatch rejection
- Dart SDK mismatch rejection
- base release mismatch rejection
- ABI mismatch rejection
- build-mode mismatch rejection
- missing artifact fallback
- unconfirmed patched boot rollback
- final restore to `Hello v2` / `active`
- last-known-good metadata
- quarantine retention capped at five entries

Additional checks passed:

- `flutter analyze`
- `flutter test`
- `bash -n scripts/*.sh`
- `:ota_runtime_android:compileReleaseKotlin`
- `:app:compileReleaseKotlin`
- `./scripts/verify_ota_core_fixture.sh`

## Deliverables

- `ota_core`: platform-neutral manifest, signing payload, lifecycle, and capability contract.
- `ota_runtime_android`: reusable Android runtime module.
- `sample_app`: thin Flutter/Android consumer demonstrating integration.
- `scripts`: build, patch extraction, signing, installation, fixture, and device acceptance tooling.
- `docs`: rollback, key management, generic integration, phase plan, and findings.

## Done Criteria

Phase 1 is complete because:

- a signed compatible patch can be selected from app-private storage;
- unsafe or incompatible patches do not reach Dart AOT execution;
- the app falls back to the APK-packaged base artifact;
- a patch that does not report boot success is rolled back;
- the proof is automated by a repeatable device acceptance script;
- the runtime is no longer sample-app-specific;
- the shared contract is separated from the Android adapter for future iOS work.

## Residual Risks

- The Android AOT override depends on a pinned Flutter embedding behavior.
- Other Android API/OEM linker and SELinux combinations are untested.
- The POC installer provider is for shell/device testing only.
- Local PEM signing is not production custody.
- The current Flutter/AGP toolchain still requires legacy Kotlin/DSL Gradle flags.
- Store policy review remains separate from technical feasibility.
- iOS may not support Dart AOT code patching under App Store rules.

## Phase 2 Gate

Phase 2 may begin once this document is accepted as the Phase 1 closure record.

Phase 2 should not assume that Android's artifact loading mechanism applies to iOS. It should reuse
`ota_core` where possible and define platform adapters based on each platform's real capability
matrix.
