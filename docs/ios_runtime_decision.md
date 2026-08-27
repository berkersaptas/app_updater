# iOS runtime decision

Decision status: **final (2026-08-18) — iOS Dart code-push is out of scope for this project.**

## Final decision (2026-08-18)

iOS ships through the normal App Store/TestFlight release cycle. This project does not implement
Dart code patching on iOS. Android remains the only platform with OTA code-push, and is
production-shaped and device-verified end to end (see `architecture_and_remaining_work.md`).

### Why

This project is self-hosted infrastructure for managing ~30-40 company Flutter apps (see project
memory `project_purpose_and_motivation.md`), not a platform product. Research into a
production-grade iOS mechanism showed that implementing it is not a proportionate investment for
that goal:

- Apple's App Store policy forbids downloading and executing new *compiled* machine code at runtime;
  it permits *interpreted* code. There is no shortcut around that constraint; any iOS Dart-patching
  approach has to solve the same problem.
- A viable solution requires a custom Dart bytecode interpreter plus a per-function linker (decides
  which unchanged functions keep running as compiled code from the signed binary, vs. which
  changed functions run interpreted), integrated into a forked Dart SDK and Flutter engine. Typically
  98%+ of code still runs compiled; only changed functions are interpreted.
- The Flutter *framework* fork is public, but the Dart SDK fork containing the actual interpreter and
  linker is private. There is no public implementation to build on — it would have to be written from
  scratch: a new language runtime (bytecode interpretation, calling conventions, exception handling,
  async/isolate semantics, GC interop, native/FFI bridging) integrated with Flutter Engine internals.
- This is a multi-year runtime and compiler engineering effort with a much larger risk profile than
  the rest of this project.
- Everything built in this project so far (Android AOT-swap runtime, binary diffing, signing,
  backend, resumable downloads) is "combine existing, well-understood pieces" engineering — days to
  weeks of work each. A correctness-critical language interpreter is a different category of risk and
  effort entirely, and a bug in it (memory corruption, GC/interop mismatch) is far more dangerous than
  a bug in a file-replacement pipeline.

### What this means going forward

- `ota_runtime_ios/` and `ota_core/ios_interpreted_patch.schema.json` are left in place as historical
  contract-skeleton artifacts (harmless, already-verified fixtures) but are **not** on any active
  roadmap. No further iOS runtime work is planned.
- `app_updater`'s iOS platform folder, if/when it exists, should simply not wire up any update
  client — iOS consumers of `app_updater` ship normally through Xcode/App Store tooling.
- If iOS asset/config-only remote updates (not Dart code patches) are ever wanted, that is a
  separate, much simpler capability and would be scoped fresh, not layered onto this decision.

---

## Original analysis (superseded by the decision above, kept for context)

Decision: iOS would require an interpreted patch architecture. It must not reuse the
Android `libapp.so` replacement model.

## Context

An iOS mechanism must differ from Android because of Apple policy and technical restrictions. The
required design uses an interpreted Dart output format and linker logic that lets unchanged code
continue to execute from the signed app binary.

That means this project's iOS adapter should preserve the same high-level release/patch/lifecycle
contract as Android, while using a different artifact class.

## Accepted iOS capability model

The iOS adapter may share:

- `ota_core` manifest schema
- release version and patch number semantics
- signing and trusted-key/revocation checks
- local lifecycle states
- bad-patch quarantine semantics
- update check and activation timing

The iOS adapter must not assume:

- executable Dart AOT replacement from app-private storage
- dynamic framework replacement
- loading unsigned native code
- Android ABI vocabulary
- Android Flutter engine argument hooks

## Target iOS artifact model

Phase 2 should model iOS artifacts as:

- patch metadata targeting a store-distributed release;
- an interpreted Dart patch payload;
- linker metadata describing which code can run from the original signed binary;
- a minimum linked-code percentage threshold;
- hash/signature metadata using `ota_core`.

The first contract artifact for this is `ota_core/ios_interpreted_patch.schema.json`. It keeps iOS
inside the same platform-neutral OTA family without importing Android's AOT shared-library loading
mechanism.

This preserves the required iOS execution boundary without pretending the Android proof already
solves iOS.

## Required open questions

- What exact interpreter artifact format will the adapter consume?
- Is the interpreter implemented in a modified Flutter engine, a native library, or an embedded
  runtime layer?
- How is linked-code percentage computed and enforced?
- What fallback path is used if the interpreter payload is valid but too slow or unsupported?
- What App Store policy review constraints must be documented before any production use?

## Phase 2 action

Create an `ota_runtime_ios` skeleton only as a contract adapter. It should not attempt to execute
patches until the interpreter/linker artifact format is defined.

The skeleton should contain:

- README with platform-safe constraints
- manifest/status model mapped from `ota_core`
- placeholder patch artifact type
- iOS interpreted patch JSON schema
- explicit "not implemented" runtime loader
- fixture verification shared with Android

## Rejected alternatives

- Reusing Android's `libapp.so` private-storage replacement model on iOS.
- Replacing app-private `.dylib` or framework code at runtime.
- Treating iOS as asset/config-only while still calling it Dart code patching.

Asset/config-only updates may exist as a separate product capability, but they are not the
interpreted Dart code patching path.
