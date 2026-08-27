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

Production Android patch artifacts are diffs applied against exact release artifacts. The local
proof path can use a full replacement `libapp.so`; production uses an artifact abstraction that
represents release-bound diffs without changing the shared lifecycle/signing contract.

## iOS adapter

iOS must not use the Android AOT replacement path. A platform-safe iOS adapter should model an
interpreted Dart patch payload plus linker metadata, with unchanged code continuing to run from the
signed store binary where possible.

Candidate capability classes:

- interpreted Dart patch payload
- linker metadata and minimum linked-code threshold
- store-compliant config/data/asset updates as a separate capability
- full app update handoff for unsupported changes

iOS can reuse the core manifest, signature, keyring, revocation, and lifecycle contract, but the
artifact type and runtime hook are platform-specific.
