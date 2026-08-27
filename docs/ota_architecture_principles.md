# OTA architecture principles

This project uses a release/patch/updater lifecycle rather than a generic dynamic-code-loader
design. The architecture is intentionally self-contained and optimized for release-bound,
Dart-code-only updates.

## Shared principles

- A release is the store-distributed application version.
- A patch targets one exact release and receives a monotonically increasing patch number.
- Patches change Dart code, not native platform code, assets, or the Flutter engine version.
- The updater checks at startup; a downloaded patch becomes visible on the next cold launch.
- Bad patches are quarantined locally and must not create crash loops.
- Production patches are signed and verified against an app-specific trusted keyring.
- Android and iOS may share lifecycle semantics while requiring different execution mechanisms.

## Android implementation

- `ota_core` defines release, patch number, manifest, signature, and lifecycle contracts.
- `ota_runtime_android` checks for updates and selects patched Dart AOT code on the next launch.
- The acceptance suite covers rollback, quarantine, and packaged-base fallback.
- Compatibility metadata binds every patch to the exact Flutter engine, Dart version, ABI, build
  mode, protocol version, and packaged base artifact.
- Production uses release-bound `binary_diff` artifacts; `full_aot_library` remains a local proof
  adapter and is disabled by default.
- `BinaryDiffArtifactResolver` reconstructs the target library from the installed market base.
- Network update behavior remains separate from runtime artifact selection.
- Managed RSA-3072 app signers are encrypted at rest by the backend; KMS/HSM custody is a deployment
  option.
- Patch install, launch, success, and failure events are persisted by the backend.

## iOS boundary

The Android AOT-library replacement mechanism must not be ported to iOS. Any future iOS design
would require an interpreted Dart payload and linker metadata while unchanged code continues to run
from the signed store binary.

Current direction:

- Reuse `ota_core` release, patch, signature, and lifecycle semantics.
- Model artifacts as interpreter/linker data rather than `.dylib`, framework, or executable AOT
  replacements.
- Keep App Store policy constraints explicit.
- Require an independent feasibility and performance gate before implementation.

The current project scope is Android-only; the iOS module remains an inert contract skeleton.
