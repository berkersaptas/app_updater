# Production installer contract

Status: Android server and device sides are implemented and device-verified. The connected CLI
registers immutable releases and publishes managed-signing binary diffs; `OtaUpdateClient` performs
patch-check, download, verification, staging, next-launch activation, and event reporting. iOS code
push is intentionally out of scope — see `docs/ios_runtime_decision.md`.

This contract keeps the project aligned with Shorebird's updater model: the runtime checks for a
release-bound patch, downloads a patch artifact, validates it, stages it, activates it for the next
launch, and records success or failure.

The POC shell `ContentProvider` remains a device-test surface only. Production integrations should
use this contract instead.

## Implementation notes (`backend/`)

The implemented backend follows this contract with one routing difference: instead of an `app_id`
field inside the request body, the app is a path segment (`/v1/apps/:appSlug/...`), since a single
backend instance is multi-tenant across the company's 30-40 apps and REST-style scoping keeps
routing/auth simpler per app. The request/response JSON shapes below are otherwise unchanged. See
`backend/README.md` for the full endpoint list and a `curl` walkthrough against a real device-verified
`binary_diff` patch.

## Patch check request

A device-side updater should send a request shaped like:

```json
{
  "app_id": "uuid",
  "channel": "stable",
  "release_version": "1.0.0+1",
  "current_patch_number": 1,
  "platform": "android",
  "arch": "arm64-v8a",
  "ota_protocol_version": 2,
  "engine_revision": "83675ed27633283e7fc296c8bca22e841224c096",
  "dart_version": "3.12.2",
  "build_mode": "release",
  "base_sha256": "64-hex",
  "build_fingerprint": "64-hex"
}
```

For iOS, `arch` may be replaced or supplemented by the iOS artifact capability vocabulary once the
interpreter/linker format is defined.

## Patch check response

```json
{
  "patch_available": true,
  "patch": {
    "number": 2,
    "artifact_kind": "binary_diff",
    "hash": "sha256",
    "download_url": "https://cdn.example/patches/2",
    "manifest": {
      "schema_version": 2,
      "ota_protocol_version": 2,
      "release": "1.0.0+1",
      "patch_number": 2,
      "artifact_kind": "binary_diff",
      "engine_revision": "40-hex",
      "dart_version": "3.x.x",
      "abi": "arm64-v8a",
      "build_mode": "release",
      "base_sha256": "64-hex",
      "build_fingerprint": "64-hex",
      "sha256": "64-hex",
      "artifact_size": 34608,
      "signature_key_id": "release-key",
      "signature_algorithm": "rsa_pkcs1_sha256",
      "signature": "base64url"
    }
  }
}
```

`build_fingerprint` is SHA-256 over protocol version, installed market release, engine revision,
Dart version, ABI, build mode, and the exact packaged base `libapp.so` SHA-256. The Android client
hashes the installed library (including split-APK lookup) rather than trusting build-time claims.
The backend validates the fingerprint and only selects a manifest whose complete identity matches.
An older client that does not send capability fields receives
`{"patch_available":false,"client_upgrade_required":true}`; it never receives a best-effort patch.

If the device's current patch was disabled or its signing key was revoked and no newer eligible
patch exists, the backend returns a rollback directive instead of offering that patch again:

```json
{
  "patch_available": false,
  "rollback_patch_number": 2
}
```

The client marks the matching local patch `disabled`. The current process keeps running, and the
packaged store artifact is selected on the next cold launch. Backend unavailability never causes a
rollback; an explicit authenticated disable/revoke action is required.

`artifact_kind` is part of the signed manifest payload. Android implements both artifact kinds,
but Play/production ingestion accepts only Shorebird-style `binary_diff`; `full_aot_library` is a
double-opt-in local POC path. See `google_play_compliance.md`. iOS uses the separate
`interpreted_dart_patch` schema because it must not load Android-style AOT shared libraries.

## Install sequence

1. Check for a patch on a background thread at startup.
2. Backend-select only an exact protocol/release/engine/Dart/ABI/build-mode/base-SHA/fingerprint
   match; repeat those checks independently on-device before boot.
3. Download the artifact into a staging directory and enforce `artifact_size`.
4. Verify manifest schema, trusted key, revocation list, and signature.
5. Resolve/apply the artifact according to `artifact_kind`.
6. Verify `sha256` against the final loadable artifact. For `binary_diff`, this necessarily occurs
   after reconstruction because the signed hash belongs to the reconstructed `libapp.so`, not the
   downloaded diff blob.
7. Atomically write patch state as `pending`.
8. Select and re-verify the patch on the next launch.

The Android implementation verifies signatures before activation and again before boot. Boot-time
verification remains the conservative fail-closed default.

## Bad patch handling

If a patch crashes, fails to launch, or fails to report boot success:

- mark the patch number bad locally;
- refuse to launch that patch number again;
- fall back to the last-known-good patch if still verifiable;
- otherwise fall back to the release artifact;
- emit a failure event on the next patch check.

Compatibility, hash, signature, and artifact-resolution failures should fail the attempted install or
boot, but should not automatically burn the patch number as bad. A patch number becomes locally bad
only after the runtime has actually attempted a patched launch and the launch did not complete
successfully.

## Patch events

Device events should be queued locally and sent on the next successful patch check.

```json
{
  "app_id": "uuid",
  "platform": "android",
  "arch": "arm64-v8a",
  "type": "PatchInstallSuccess",
  "release_version": "1.0.0+1",
  "patch_number": 2
}
```

Supported event types:

- `PatchInstallStarted`
- `PatchInstallSuccess`
- `PatchInstallFailure`
- `PatchLaunchSuccess`
- `PatchLaunchFailure`
- `PatchMarkedBad`

## Storage contract

Adapters should use these logical directories under app-private storage:

- `ota/staging`: incomplete downloads and artifact application outputs
- `ota/patches/<patch_number>`: installed patch artifacts
- `ota/quarantine`: failed artifacts and failure metadata
- `ota/events`: queued patch events
- `ota/patch_state.json`: active/pending state
- `ota/last_known_good.json`: last successful patch metadata
- `ota/bad_patches.json`: locally rejected patch numbers

## Production requirements

- No shell provider or adb-only path in production.
- No native code, asset, or Flutter engine changes through patch flow.
- Patch selection must never block first frame longer than the agreed launch budget.
- Download/apply work must be resumable or safely discardable.
- All state writes must be atomic.
- The updater must tolerate backend/CDN unavailability and boot the app normally.
