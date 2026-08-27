# Phase 2D: engine feasibility spike

Status: decision document. Produced for `docs/architecture_and_remaining_work.md` workstream 2D,
ahead of implementing `binary_diff` (workstream 2E).

## Question

Does moving the Android production artifact from `full_aot_library` (whole `libapp.so` replacement)
to `binary_diff` require forking the Flutter engine or Android embedding?

## Answer: no engine fork is required

`engine_notes/findings.md` (#8) already answered this for `full_aot_library` on the pinned Flutter
`3.44.6` embedding: `FlutterLoader.ensureInitializationComplete` accepts an `--aot-shared-library-name=`
override before VM start, provided the path canonicalizes to a `.so` under `filesDir`. No source
patch to the engine or embedding was needed to prove that path.

`binary_diff` does not change loading at all. Looking at how the two resolvers plug into the same
interface (`ota_runtime_android/src/main/kotlin/com/app_updater/ota_runtime/PatchArtifactResolver.kt`):
both `FullAotLibraryArtifactResolver` and the `BinaryDiffArtifactResolver` stub return the same
`PatchArtifact(loadableAotLibrary: File, kind)`. `binary_diff` only changes **how the bytes of that
file are produced** (reconstruct from a base artifact + a diff, instead of a plain copy) — it does
not change *how the resulting file is loaded*. The already-proven `FlutterLoader` override path is
reused unmodified.

So the engine/embedding touch points for `binary_diff` are the same as for `full_aot_library`:
none. The work is entirely in the artifact-production pipeline (build-time) and the
artifact-reconstruction pipeline (device-time), both of which are ordinary Kotlin/shell code.

## Minimum viable Android binary-diff design

### Base artifact lookup

The diff base does not need separate distribution: it is the base release's own packaged
`libapp.so`, already installed with the APK. Two cases depending on AGP's
`android:extractNativeLibs` / `useLegacyPackaging`:

- If native libs are extracted at install time, `ApplicationInfo.nativeLibraryDir/libapp.so` is a
  real file on disk and can be read directly.
- If native libs are **not** extracted (modern AGP default, libs stay compressed inside the APK and
  are mapped via the linker at load time), there is no extracted file to diff against. The base
  artifact must instead be read as a zip entry from `context.applicationInfo.sourceDir` (the APK
  path) — the same `lib/<abi>/libapp.so` entry `scripts/extract_artifacts.sh` already reads at
  build time, just read on-device instead.

`sample_app/android` sets neither `extractNativeLibs` in its manifest nor
`packaging.jniLibs.useLegacyPackaging` in its Gradle config, so it inherits AGP 8.x's default of
**not** extracting native libraries (uncompressed, mapped straight from the APK). That means the
zip-entry read path is the one to implement first; the extracted-file path only matters for apps
that explicitly opt into legacy packaging. This should still be confirmed empirically (e.g.
inspecting `ApplicationInfo.nativeLibraryDir` on a built debug/release APK) before Phase 2E, since
it is a device/AGP-version-sensitive default, not a hard guarantee.

### Diff format

Use a bsdiff/bspatch-style algorithm — the standard choice for binary patching of similar binaries
across versions and widely used for compact release-to-release binary patching.
Two different implementations are needed for two different constraints:

- **Diff generation** happens once, at build time, in `scripts/build_patch.sh`, on a developer/CI
  machine. Any implementation works here (a native `bsdiff` CLI, or a Dart/Python tool) since it
  never runs on-device and has no dependency-footprint constraint.
- **Diff application** happens on-device, in `BinaryDiffArtifactResolver`. Given
  `engine_notes/findings.md` (#7) already established Kotlin is sufficient and this module currently
  has zero external dependencies (`ota_runtime_android/build.gradle.kts` has no `dependencies {}`
  block), on-device apply should stay pure-JVM — no NDK/native library. A pure-Java bsdiff/bspatch
  implementation (e.g. `io.sigpipe:jbsdiff`, a Maven-published pure-Java port of the bsdiff/bspatch
  format) is a candidate; it must be evaluated for size, license, and behavior before adoption. This
  is the one open dependency decision in this design and should be confirmed explicitly before
  Phase 2E starts, since it is the first external dependency this module would carry.

### Build-time pipeline (extends `scripts/build_patch.sh`)

1. Build/extract the base release `libapp.so` (already done by `build_base.sh` /
   `extract_artifacts.sh`).
2. Build/extract the patch release `libapp.so` from the alternate entrypoint (already done).
3. Compute `diff(base.so, patch.so)` with the chosen build-time diff tool.
4. Hash the **reconstructed target artifact** (i.e. `patch.so`, not the diff blob) into
   `sha256`, matching the existing manifest contract — this is the field the runtime already
   verifies after any apply.
5. Sign and write `patch_manifest.json` with `artifact_kind: binary_diff`, same as today except the
   staged artifact is the diff blob rather than a full `.so`.

### Device-time pipeline (`BinaryDiffArtifactResolver`)

1. Resolve the base artifact per the lookup rule above.
2. Read the staged diff blob (`ota/patches/<patch_number>/libapp.so.diff`, per
   `docs/production_installer_contract.md`'s storage contract, which already reserves
   `ota/staging` for "artifact application outputs").
3. Apply the diff to produce a reconstructed `.so`, written atomically into
   `ota/patches/<patch_number>/libapp.so` inside `ota/staging` first, then moved into place —
   consistent with the existing atomic-write requirement.
4. Verify the reconstructed file's SHA-256 against the signed manifest `sha256` before returning
   `PatchArtifact`. A mismatch here is an apply-time integrity failure, not a boot failure — it
   should follow the same rule already documented for hash/compatibility failures (fail the
   attempted install, do **not** automatically burn the patch number).
5. Perform the apply once, at install/staging time, not on every boot — `production_installer_contract.md`
   requires patch selection to never block first frame longer than the launch budget, and a
   bsdiff-style apply is much more expensive than the current PatchArtifactResolver work, which
   today is just a path/hash check.
6. Return the reconstructed file as `loadableAotLibrary`, identical to what
   `FullAotLibraryArtifactResolver` already returns. Nothing downstream changes.

### What this design reuses vs. adds

Reused unmodified:

- `PatchArtifactResolver` interface and its consumer in `PatchLoader`.
- The proven `FlutterLoader` AOT override mechanism.
- The signed manifest contract, compatibility checks, lifecycle, quarantine, and bad-patch rules.

New:

- Base-artifact lookup logic (APK-relative, two cases depending on native-lib packaging).
- A diff/patch codec on both the build and device sides.
- An apply-at-install-time step and its atomic-write/verify sequence.
- One new external dependency decision for the device-side patch codec.

## Open questions before Phase 2E implementation

Status: all four resolved, including real-device verification (2026-08-17, arm64-v8a Android
device, same device/toolchain as the Phase 1 proof in `engine_notes/findings.md`).

1. **Resolved, device-verified.** `BinaryDiffArtifactResolver` reads the base artifact from the
   installed APK's `lib/<abi>/libapp.so` zip entry via `context.applicationInfo.sourceDir`. Built a
   real base APK and a real patched APK from this project's own `sample_app`
   (`scripts/build_base.sh`, `scripts/build_patch.sh`), installed the base APK, staged a real
   `binary_diff` patch, force-stopped, and relaunched. Logcat: `Verified binary_diff patch 1;
   attempting patched boot` then `Patch 1 is active`; the UI showed `Hello v2`. Confirms the
   zip-entry lookup works against a real installed APK on this device's AGP packaging mode.
2. **Resolved.** `io.sigpipe:jbsdiff:1.0` (+ its `commons-compress` dependency) was added to
   `ota_runtime_android/build.gradle.kts`. Pure JVM, BSD 2-Clause licensed, no native/NDK code. The
   module compiles cleanly with it, and the device run above proves it also works inside the actual
   Android runtime (not just on a dev machine).
3. **Resolved.** Reconstructed artifacts are cached at `ota/patches/<n>/libapp.reconstructed.so` and
   cleaned up by the existing `OtaLifecycleStore.cleanup()` policy. Device-verified: a second launch
   of an already-active `binary_diff` patch reused the cached reconstructed file (no re-apply log
   line), and a failed/quarantined patch's directory was cleaned so a later re-install correctly
   re-ran reconstruction from scratch rather than reusing stale cache. `storedPatchCount()` had a
   latent bug (it only recognized the `full_aot_library` filename) that was fixed as part of this
   work so `binary_diff` patches count correctly too.
4. **Resolved.** Real numbers from this project's own `sample_app` release build: base and patched
   `libapp.so` were both 2,884,496 bytes; the generated diff was 7,128 bytes (99.75% smaller than
   shipping the full artifact). On-device apply was fast enough not to be visually perceptible
   against the existing POC's boot flow; no formal timing instrumentation was added.

A corrupted-diff negative case was also run on-device (not one of the original open questions, but
worth recording): a bit-flipped diff blob caused `io.sigpipe.jbsdiff.Patch.patch()` to throw
(`Integer overflow: 64-bit offsets not supported`), which `BinaryDiffArtifactResolver`'s
`runCatching` turned into a `Result.failure`, which `PatchLoader` turned into a clean `fail()` —
logged as `Patch 1 disabled: Integer overflow: 64-bit offsets not supported.`, no crash, and the app
booted the base APK's `Hello v1` normally. This is the same fail-safe behavior already proven for
`full_aot_library` in `engine_notes/findings.md`, now confirmed for `binary_diff` too.

## iOS sequencing

`docs/architecture_and_remaining_work.md` (Phase 2D) also asks whether iOS work should wait for
Android engine proof or proceed in parallel as contract-only. Since this spike concludes there is no
shared engine fork between the two platforms — Android's `binary_diff` reuses the existing
`FlutterLoader` override path unchanged, and iOS's `interpreted_dart_patch` direction is an entirely
separate interpreter/linker mechanism per `docs/ios_runtime_decision.md` — there is no technical
dependency forcing serialization. iOS contract work (Phase 2F) can proceed in parallel with Android
`binary_diff` implementation (Phase 2E); neither blocks the other.

## Conclusion

No Flutter engine or embedding fork is needed for `binary_diff`. The design above is now implemented
and device-verified: `BinaryDiffArtifactResolver` reconstructs and boots a real `binary_diff` patch
correctly, caches the result, safely rejects corruption, and falls back to the base artifact without
crashing. `scripts/run_device_acceptance.sh` does not yet cover `binary_diff` as part of its
automated matrix — that remains the one piece of this phase not yet done. Phase 2F (iOS contract
validation) can proceed independently in parallel.
