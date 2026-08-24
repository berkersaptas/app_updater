# Platform capability model

The core contract does not assume that every platform can load the same artifact type. Each adapter
must declare the capabilities it actually supports.

## Android adapter

Current implementation:

- artifact: Flutter release AOT `libapp.so`
- storage: app-private `filesDir/ota/patches/<patch_number>/libapp.so`
- load hook: Flutter engine argument `--aot-shared-library-name=<absolute path>`
- compatibility fields: release, engine revision, Dart SDK version, ABI, build mode
- status: device-proven for pinned Flutter 3.44.6 on arm64-v8a Android 16

Android remains subject to OEM linker, SELinux, and store policy constraints.

Shorebird alignment note: Shorebird Android patch artifacts are diffs applied against release
artifacts. This POC currently uses a full replacement `libapp.so` as the proof adapter. Phase 2
should introduce an artifact abstraction that can represent Shorebird-style diffs without changing
the shared lifecycle/signing contract.

## iOS adapter

iOS must not use the Android AOT replacement path. A Shorebird-aligned iOS adapter should model an
interpreted Dart patch payload plus linker metadata, with unchanged code continuing to run from the
signed store binary where possible.

Candidate capability classes:

- Shorebird-style interpreted Dart patch payload
- linker metadata and minimum linked-code threshold
- store-compliant config/data/asset updates as a separate capability
- full app update handoff for unsupported changes

iOS can reuse the core manifest, signature, keyring, revocation, and lifecycle contract, but the
artifact type and runtime hook are platform-specific.
