# Phase 1 plan and acceptance run

1. Build the arm64 base APK and extract/hash its packaged `libapp.so`.
2. Install the base APK and verify `Hello v1`.
3. Build the same shell with the patched Dart entrypoint and extract/hash its `libapp.so`.
4. Confirm base and patched hashes differ.
5. Copy only patched `libapp.so` plus the signed manifest into app-private storage.
6. Verify the manifest signature before activation and again before every patched boot.
7. Fully restart the process and verify `Hello v2` and state `active`.
8. Repeat with a tampered signature, wrong hash, and missing artifact; verify safe rejection.
9. Repeat with a Dart entrypoint that never signals success (or stop the process before its first
   frame); verify rollback on the following launch.

Build outputs and hashes are deliberately ignored by Git and are produced in
`patch_artifacts/base` and `patch_artifacts/patched`.

The native runtime is separated from the sample app in `ota_runtime_android`. The sample app only
demonstrates integration through `FlutterOtaRuntime`.

`scripts/run_device_acceptance.sh` automates this matrix, including tampered manifest signatures,
trusted-key verification, compatibility mismatches, missing/hash-invalid artifacts, and a
deterministic no-boot-success artifact.

The complete matrix passed on an arm64-v8a Android 16 device. The suite leaves the application on
`Hello v2`, state `active`, with last-known-good metadata and bounded quarantine retention.
