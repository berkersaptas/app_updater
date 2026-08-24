# Shorebird alignment check

This project follows Shorebird's architecture direction, not a generic dynamic-code-loader design.
The goal is to stay close to Shorebird's release/patch/updater model while keeping this repository
as an independent proof and learning scaffold.

Sources checked:

- Shorebird Code Push overview: https://docs.shorebird.dev/code-push/
- Shorebird system architecture: https://docs.shorebird.dev/code-push/system-architecture/
- Shorebird patch creation docs: https://docs.shorebird.dev/code-push/patch/
- Shorebird patch signing docs: https://docs.shorebird.dev/code-push/guides/patch-signing/

## Shorebird principles to preserve

- A release is the store-distributed application version.
- A patch targets a specific release and patch number.
- Patches change Dart code, not native platform code or Flutter engine version.
- The updater runs at startup and a downloaded patch is visible on the next launch.
- Bad patches are locally marked as bad and must not cause crash loops.
- Patch signing is optional in Shorebird but production-grade systems should support it.
- Android and iOS share the high-level concept of "replace Dart code", but not the same
  implementation mechanism.

## Android check

Aligned:

- `ota_core` has release, patch number, manifest, signature, and lifecycle contracts.
- `ota_runtime_android` checks for a patch at boot and selects patched Dart AOT on next launch.
- The acceptance suite proves rollback, bad-patch quarantine, and base fallback.
- Native code, asset changes, and Flutter engine changes are outside patch scope.
- The current manifest includes exact Flutter engine and Dart version compatibility.

Different from Shorebird:

- Shorebird Android patch artifacts are diffs against release artifacts. This project now supports
  both: `full_aot_library` (full replacement, device-proven) and `binary_diff` (bsdiff-based,
  implemented and device-verified through the connected release/patch/backend flow).
- Shorebird embeds a modified Flutter engine/updater; this POC uses the pinned embedding's
  `--aot-shared-library-name` path.
- Shorebird signing docs describe RSA/PEM and KMS command signing; this project uses per-app
  RSA-3072 managed signers encrypted at rest by the backend. KMS/HSM custody remains deployment
  work.
- Patch install/success/failure events are reported to and persisted by the backend.

Phase 2 Android direction:

- Keep the current full-`libapp.so` path as the local proof adapter.
- Done: `PatchArtifactResolver` applies release-bound diffs with `BinaryDiffArtifactResolver`.
- Done: network/update-client behavior is separate from runtime selection.
- Done: bad-patch quarantine prevents crash loops and falls back safely.

## iOS check

Do not port the Android implementation mechanism to iOS.

Shorebird's iOS architecture replaces Dart code at the conceptual level, but avoids normal machine
code replacement. Its public architecture docs describe a modified Dart output format interpreted on
device, plus compiler/linker changes that let most unchanged code continue running from the signed
store binary.

Phase 2 iOS direction:

- Reuse `ota_core` for release/patch/signature/lifecycle semantics.
- Model iOS patch artifacts as interpreter/linker artifacts, not `.dylib`, framework, or executable
  AOT replacement artifacts.
- Require an iOS adapter feasibility gate before code implementation.
- Track a minimum linked-code percentage concept like Shorebird's iOS patch workflow.
- Keep App Store policy constraints explicit in the decision record.
