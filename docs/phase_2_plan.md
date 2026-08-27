# Phase 2 plan

Phase 2 moves the project from Android proof-of-concept toward a production-shaped, cross-platform
OTA architecture.

## Goals

- Preserve the shared `ota_core` contract across platforms.
- Keep the architecture production-oriented: release/patch/updater lifecycle, Dart-code-only patches,
  bad-patch quarantine, and platform-specific patch execution.
- Apply the platform-safe iOS direction: interpreted Dart patch payload plus linker metadata, not
  Android-style AOT binary replacement.
- Replace shell-only patch ingress with a production installer/update-client contract.
- Replace local PEM signing with production key custody.
- Prepare `ota_runtime_android` for packaging and integration into real apps.
- Expand verification beyond one Android device.

## Workstreams

### 1. OTA architecture and iOS feasibility

Use [ota_architecture_principles.md](ota_architecture_principles.md) and
[ios_runtime_decision.md](ios_runtime_decision.md) as the governing documents.

**Final decision (2026-08-18): iOS Dart code-push is out of scope for this project.** See
`ios_runtime_decision.md`'s "Final decision" section for the full reasoning. `ota_runtime_ios`
remains in the repo as an inert contract skeleton but is not on the active roadmap. Android is the
only OTA platform.

Current progress:

- Android manifest payload includes signed `artifact_kind`.
- Android's `binary_diff` resolver is implemented (bsdiff-based, via `io.sigpipe:jbsdiff`) and
  device-verified through both scripted acceptance and the connected managed-signing CLI/backend
  flow. `full_aot_library` remains a local POC path and is disabled by default in production.
- iOS has a contract skeleton and `ota_core/ios_interpreted_patch.schema.json` for interpreted Dart
  patch metadata.

### 2. Production installer contract

Replace the POC shell `ContentProvider` as the conceptual install surface.

Define:

- download/staging directory contract
- manifest verification timing
- artifact hash verification timing
- activation transaction
- status/error reporting
- retry/backoff behavior
- cleanup policy

Android may keep the shell provider for acceptance tests, but production integration should use a
separate update client API.

### 3. Signing custody

Keep the keyring/revocation model, but move from local-only Ed25519 signing toward a production
signer.

Define:

- HSM/KMS or CI signing boundary
- signing request payload
- audit fields
- key rotation process
- emergency revocation process
- offline verification tooling

Current progress:

- The canonical payload signs `signature_algorithm` and `artifact_kind`.
- `scripts/build_patch.sh` supports `OTA_SIGN_CMD` as a command-based signing boundary, and
  `scripts/generate_compatibility_metadata.sh` supports the matching `OTA_PUBLIC_KEY_CMD`
  publication boundary.
- Android runtime verification accepts both `ed25519` and `rsa_pkcs1_sha256`.
- `scripts/verify_sign_command.sh` exercises the `OTA_SIGN_CMD`/`OTA_PUBLIC_KEY_CMD` boundary with a
  fake KMS signer for both algorithms.

### 4. Android runtime packaging

Turn `ota_runtime_android` into a distributable module.

Tasks:

- define public API stability rules
- package as AAR or Maven-local artifact
- document required Gradle properties
- keep POC installer disabled by default
- add consumer integration sample
- revisit AGP built-in Kotlin once pinned Flutter Gradle plugin supports it cleanly

### 5. Verification expansion

Add tests and target coverage:

- Android instrumentation tests for corrupt state and atomic writes
- manifest fixture tests independent of device runtime
- Android API/OEM matrix
- linker/SELinux failure documentation
- lifecycle and quarantine retention tests
- production installer contract tests
- bad-patch list persistence tests

## Proposed Sequence

1. Write `docs/ios_runtime_decision.md`.
2. Keep `ota_runtime_ios` as a skeleton and define its artifact contract.
3. Refine `docs/production_installer_contract.md` into implementation tasks.
4. Add manifest fixture validation beyond shell scripts.
5. Split the Android shell provider into an explicit debug/test surface.
6. Package `ota_runtime_android` as a local AAR and consume it from `sample_app`.
7. Add Android instrumentation tests.

## Non-Goals

Phase 2 still does not need a full backend, admin UI, CDN rollout system, or real production HSM
integration. It should define those contracts clearly enough that Phase 3 can implement them.

## Exit Criteria

Phase 2 is complete when:

- iOS support direction is decided and documented;
- Android and iOS docs explicitly state their platform-specific differences;
- production installer and signer contracts are documented;
- Android runtime is package-shaped rather than only source-included;
- test coverage includes contract-level checks outside the single device acceptance script;
- Android acceptance still passes with the package-shaped runtime.
