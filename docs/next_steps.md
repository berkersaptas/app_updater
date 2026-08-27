# Next steps after device proof

Phase 1 is complete. See [phase_1_completion.md](phase_1_completion.md). Phase 2 planning lives in
[phase_2_plan.md](phase_2_plan.md).

The current architecture and remaining work are summarized in
[architecture_and_remaining_work.md](architecture_and_remaining_work.md).

The project should remain Shorebird-aligned. See [shorebird_alignment.md](shorebird_alignment.md)
and [ios_runtime_decision.md](ios_runtime_decision.md).
The production updater flow is drafted in
[production_installer_contract.md](production_installer_contract.md).

## Recommended next step

Phases 2A, 2B, 2C, 2D, and 2E are all done (2026-08-17) — see
`architecture_and_remaining_work.md`'s per-phase sections and "What is proven" for the full detail
and device-verification evidence.

**iOS Dart code-push is out of scope (final decision, 2026-08-18)** — see
`ios_runtime_decision.md`'s "Final decision" section. Replicating Shorebird's iOS mechanism means
writing a Dart bytecode interpreter and linker from scratch (Shorebird's own Dart SDK fork containing
it is private, not something to build on); Shorebird itself rates this "Hard" and built it with
Flutter's own creator on a funded team over years. Not a proportionate investment for a ~30-40-app
internal tool. Android is the only OTA platform going forward; iOS apps ship through the normal App
Store/TestFlight cycle. Phase 2F and `ota_runtime_ios` are retired from the active roadmap.

**Flutter apps integrate via `app_updater` (a real Flutter plugin package) with a single
platform-agnostic config file, not `ota_runtime_android` directly and not per-platform manifest
editing** — see `app_updater/README.md`. `sample_app` was migrated to this and device-verified
end to end: `pubspec.yaml` dependency, one `app_updater.yaml` at the project root (app slug,
backend URL, trusted keys), `class MainActivity : FlutterOtaActivity()`,
`AppUpdater.instance.autoUpdate()` with no arguments in `main()`. `sample_app`'s own
`AndroidManifest.xml`/`build.gradle.kts` carry zero OTA-specific config — `app_updater`'s own
Gradle build reads the YAML plus the project's Flutter toolchain at build time and generates
everything.

**`app_updater`/`ota_runtime_android` distribution across machines is done:**
`app_updater` is consumed as a `git:` path dependency. Pub retains the complete repository
checkout, and the plugin compiles the canonical sibling `ota_runtime_android` sources directly.
The repository is public and the plugin compiles the sibling `ota_runtime_android` sources from the
same Pub checkout. Installation therefore has no secondary dependency-service setup. This layout
was verified with a real `flutter build appbundle --release`.

**One-command patch publish (`app_updater_cli`) is done** (2026-08-19): the portal's "upload
artifact + manifest" flow (and even `scripts/build_patch_for_project.sh` + a hand-written `curl`)
assumed a developer would understand and produce those two files themselves — in practice, for a
real company developer, that was never going to happen. `app_updater_cli/` is a small Dart CLI
(`dart pub global activate --source git ... --git-path app_updater_cli`, installed once per machine)
providing `app_updater publish`: run from inside the app's own repo, it builds the release APK,
extracts (and diffs, for `binary_diff`) `libapp.so`, signs the manifest, and uploads it — patch
number and signing key auto-detected from `app_updater.yaml` and the backend when there's only
one sensible choice. The current implementation performs archive inspection, Dart-only comparison,
manifest generation, and binary-diff orchestration through Dart and the JDK, so it runs natively on
Windows, macOS, and Linux after global activation. This is the
closest analog to Shorebird's own `shorebird patch` UX. See `app_updater_cli/README.md`. Verified end
to end against a live Docker backend: registered a fresh app + RSA key via the admin API, ran
`app_updater publish` from a copy of `sample_app` outside this repo (pointed at the plugin via an
absolute `path:` dependency to simulate an external project), and confirmed the backend accepted
the upload (`201`) with the manifest's `sha256`/`signature`/`artifact_size` all validating.

**App-scoped publish keys are done** (2026-08-20): the first cut of `app_updater publish` above still
needed an operator API key, which a real developer wouldn't have (operator keys are cross-app and
ops-issued) — this was flagged immediately when walking through the first-time setup flow. Added
`app_publish_keys` (migration `005_publish_keys.sql`): any app member can self-issue one from the
portal (`/apps/<slug>`, "Publish keys" — shown once, like the signing key), scoped to that single
app only. `src/middleware/adminAuth.js` resolves it to `req.scopedAppId` instead of an operator
name; `requireUnscopedOperator` rejects it on every `/admin/*` router except `patches.js`, whose
handlers check `req.scopedAppId` against the `:appSlug` in the URL. A real ordering bug was caught
and fixed here, not just a test artifact: `patchesRouter` must be mounted in `index.js` *before*
the `requireUnscopedOperator`-guarded routers, otherwise their guard middleware (registered earlier
in the Express chain) rejects a scoped key on `/admin/apps/<slug>/patches` before the request ever
reaches `patchesRouter`'s own route matching, since Express runs middleware in registration order
regardless of which router ultimately handles the path. `GETTING_STARTED.md`, `app_updater_cli/README.md`,
and `backend/README.md` updated to describe publish keys as the credential `app_updater publish` uses
(not an operator key). Verified end to end against a live Docker backend: registered via the portal,
generated a publish key, ran `app_updater publish` with it successfully; confirmed the same key gets
403 on app-creation and on a *different* app's patches endpoint, and 401 once revoked; regression
ran clean on `scripts/verify_admin_auth.sh` and `scripts/verify_portal.sh`.

**`app_updater init` and bundled publish-key generation are done** (2026-08-20): even with `app_updater
publish` and scoped publish keys, the first-time setup still meant hand-editing four files
(`pubspec.yaml`, `app_updater.yaml`, `android/build.gradle.kts`, `MainActivity.kt`) and a
separate trip to the app's page just to generate a publish key — flagged as still "uğraştırıcı"
(still a hassle) when walking through it fresh. Two changes:

1. The original `app_updater_cli` gained an `init` command (`bin/app_updater.dart` restructured onto
   `package:args/command_runner.dart`, `_InitCommand`/`_PublishCommand`): given
   `--yaml-file <saved app_updater.yaml>`, it text-edits `pubspec.yaml` (inserts the
   `app_updater` git dependency after the `dependencies:` line), writes the yaml into the
   project root, originally text-edited `android/build.gradle.kts` (that obsolete external
   repository step has since been removed), and text-edits `MainActivity.kt` (swaps
   `: FlutterActivity()` for
   `: FlutterOtaActivity()` and fixes the import). These original steps were checked by running
   `init` twice in a row
   against a simulated fresh `flutter create` project (stripped-down `MainActivity.kt`/
   `build.gradle.kts`, no existing dependency) and confirming the second run changed nothing and
   reported each step already done. Deliberately does *not* touch `lib/main.dart` (the one
   remaining manual step, printed at the end) since that means editing the app's own `main()`
   logic, which isn't safe to pattern-match blindly.
2. Creating an app in the portal (`routes/portal/apps.js`) now also generates a publish key at the
   same time as the signing key, so the one page shown after app creation has the yaml, the private
   key, the publish key, *and* the exact `app_updater init`/`app_updater publish` commands to copy-paste —
   no second trip to the app's page needed just to get started. The per-app "Publish keys" section
   on the app's page is unchanged (still there for generating additional/replacement keys, e.g. for
   a second machine or a revoked key).

Verified end to end against a live Docker backend, simulating the full first-time path: registered
via the portal, created an app (confirmed the response page renders yaml + private key + publish
key + ready-to-run commands), scrubbed a copy of `sample_app` back to a bare `flutter create`-like
state (default `MainActivity.kt`/`build.gradle.kts`, no `app_updater` dependency), ran
`app_updater init --yaml-file ...` against it and confirmed all four edits landed correctly and a second
`init` run was a no-op, then ran `app_updater publish` with the generated publish key and confirmed a
real `201` upload with a validating signature. Regression ran clean on
`scripts/verify_admin_auth.sh` and `scripts/verify_portal.sh` (both routers touched by the publish
key work).

**Not done yet, deliberately out of scope for this pass:** a CI/CD template (e.g. GitHub Actions)
that runs `app_updater publish` automatically on push/tag, with the private key as a CI secret. This
was one of the options discussed when redesigning the publish UX (2026-08-19) — the developer
chose to start with the manually-run global CLI first (`app_updater publish`) rather than full
automation. Revisit if/when a company app team wants push-to-deploy instead of a manual command.

**Google Play/Dart-only production guardrails are done (2026-08-21):** `app_updater publish` now
defaults to `binary_diff` and requires the exact archived single-ABI base APK. Before signing or
uploading it compares the base and patch APK and permits only Dart's `libapp.so` (plus expected APK
signature metadata) to differ; manifest, DEX, native/plugin libraries, resources, engine, or asset
changes fail with a store-release instruction. The backend independently rejects
`full_aot_library` by default so portal/direct API uploads cannot bypass the CLI policy. Whole-`.so`
replacement survives only as a double opt-in local POC path (`--allow-full-aot-library` plus
`ALLOW_FULL_AOT_LIBRARY=true`). See `docs/google_play_compliance.md` for the Shorebird-aligned Dart
VM policy rationale and publisher responsibility boundary.

**Connected release lifecycle and managed signing are done (2026-08-21):** the recommended path is
now `app_updater login`, `app_updater init`, `app_updater release android`, and `app_updater patch android`.
Developers no longer copy API keys, signing keys, YAML, or base APKs. Each Play AAB is stored as an
immutable version/ABI base; later patches automatically download it and are rejected if the
Flutter/Dart toolchain or non-Dart contents differ. The backend assigns patch numbers and signs
validated manifests using an AES-256-GCM-encrypted per-app RSA key. Migration 006 adds CLI sessions,
managed signers, releases, and release artifacts; the backend now runs tracked migrations on every
startup so existing Postgres volumes upgrade without reset. Portal-created apps use the same
managed model. A real temporary Flutter-project run completed login → init → 15.4 MB AAB release →
binary diff → managed signature → publish. The git dependency compiles the canonical sibling
runtime sources directly from the public repository checkout. The same connected
release was then installed on a Xiaomi 2211133G (Android 16/API 36, arm64-v8a): launch 1 displayed
`Hello v1` and staged managed-signing patch 2; launch 2 logged `Verified binary_diff patch 2`,
displayed `Hello v2`, and persisted state `active`; steady state returned
`OtaNoUpdateAvailable`. The visible patch was a 34,608-byte diff. This run exposed and fixed one
real AAB guard issue: Dart changes also alter
`BUNDLE-METADATA/com.android.tools.build.debugsymbols/<abi>/libapp.so.sym`; that Dart-generated,
non-executable metadata is now allowed while DEX/native/resource/asset changes remain rejected.

**What's left to actually put this in front of 30-40 apps:**

Deploy/hosting is deliberately deferred for now (explicit user call, 2026-08-17) in favor of more
development first.

Deferred until deploy is back in scope: HTTPS/reverse proxy, durable object storage/CDN, managed
Postgres/backups, and moving the signing master key from an environment secret to KMS/HSM custody.

**Done since the last update:** `scripts/run_binary_diff_acceptance.sh` now covers `binary_diff`
and the `app_updater` network update-client end to end and repeatably — RSA-signed patch
staged/activated/steady-state, a storage-corrupted patch staged then correctly rejected on
reconstruction with fallback to base, and Postgres event verification. It resets the backend
(`docker compose down -v && up`) and reinstalls the app each run for a clean slate; run it the same
way as `scripts/run_device_acceptance.sh`, with a device connected.

`scripts/run_device_acceptance.sh` now defaults to `OTA_SIGNATURE_ALGORITHM=rsa_pkcs1_sha256`
(was `ed25519`, which a real Android 10/API 29 device cannot verify — platform JCA gap, see
`docs/key_management.md`). A real cross-script test-isolation bug was also found and fixed: since
`sample_app`'s `AppUpdater.instance.autoUpdate()` now runs unconditionally on every launch, if
`run_binary_diff_acceptance.sh`'s Docker backend and `adb reverse tcp:8080` were still live from an
earlier run, `run_device_acceptance.sh`'s own restarts would race against that live backend and
silently get overwritten by the other script's patch (symptom: `content read` showing
`artifact_kind: binary_diff` and a `sha256` matching the *other* script's manifest, not this one's
locally built one). Fixed with `adb reverse --remove tcp:8080` at the top of
`run_device_acceptance.sh`, severing the network path so `autoUpdate()` fails harmlessly instead of
pulling in another test's state. Verified by reproducing the failure, then confirming both scripts
pass cleanly back-to-back with fresh (non-`--skip-build`) builds, in the original failure-triggering
order (2026-08-17).

**Install resume support is done** (`ota_runtime_android` 0.1.3, 2026-08-18): `OtaUpdateClient.downloadTo`
now resumes an interrupted artifact download with an HTTP `Range` request against a leftover `.tmp`
staging file instead of restarting from byte zero; no backend change was needed since Express's
`res.sendFile` already serves `206 Partial Content` for `Range` requests. A real bug was found and
fixed along the way, not just a test artifact: `OtaLifecycleStore.cleanup()` runs on *every* boot (via
`markBootSuccess()`, before `checkForUpdate()` ever gets a chance to run) and deleted any patch
directory that wasn't the active patch or last-known-good — including a `.tmp` staged by an
interrupted download for a not-yet-active patch. That made resume unreachable in the exact scenario
it exists for (app killed mid-download, reopened later); fixed by exempting any directory containing
a `.tmp` file from that cleanup pass. Verified on-device by planting a truncated `.tmp` at the exact
staging path and confirming (via live-streamed logcat, not a post-hoc buffer dump — the device's own
log ring buffer was losing events under normal system-log noise) both the `Range` request firing from
the correct byte offset and the resumed artifact reconstructing/activating correctly.
`run_binary_diff_acceptance.sh` gained a dedicated resume scenario (patch 2) and its logcat capture
was hardened to stream live during `restart_app` plus a supplemental `adb logcat -d` backfill (a
redirected/killed `adb logcat` process can drop its last unflushed buffered chunk, which cost one
false-negative run before the backfill was added).

**Backend admin auth is done** (2026-08-18, `backend/migrations/002_operators.sql`): `ADMIN_API_KEY`
is now a **root bootstrap key only** — it exists solely to mint and revoke per-operator keys via
`POST`/`DELETE /admin/operators` (`GET /admin/operators` lists operators, no secrets in the
response). Every other admin/ingestion call (apps, keys, patch upload/enable/disable) requires a
per-operator key; a per-operator key cannot itself mint or revoke other operators (403). Every
request under `/admin/*` — successful, denied, or from an unrecognized key — is recorded in the new
`admin_actions` table (operator name, method, path, status code, timestamp;
`GET /admin/actions?limit=N` reads it back) regardless of outcome, so denied/revoked-key attempts are
auditable too, not just successful ones. Verified end to end with the new
`scripts/verify_admin_auth.sh` (Docker + curl, no device needed): unknown key rejected, non-root
operator blocked from minting operators, a freshly minted operator's key works for ordinary admin
actions, revoking it blocks further use, and the audit log captures all of it. See "Admin auth and
audit log" in `backend/README.md` for the full curl walkthrough.

**One-command app onboarding is done** (2026-08-18, `scripts/app_updater_init.sh`): a CLI, ops-facing
alternative for scripted/non-interactive provisioning (registers the app, generates a key, writes
`app_updater.yaml`). Superseded as the *primary* onboarding path by the web portal below, but
kept for CI/automation use since it needs no browser session.

**Self-service developer web portal is done** (2026-08-18, `backend/migrations/003_users.sql`):
the actual ask behind the onboarding-UX complaint — developers should be able to log into a website
themselves, create their own app, and share access with teammates, without an ops person or cloning
this infra repo. Session-authenticated (email/password, `express-session` + `connect-pg-simple` for
Postgres-backed sessions), plain server-rendered HTML (no separate frontend project/build step, per
this project's minimal-dependency style) at `/`, `/login`, `/register`, `/apps/<slug>`. Self-service
app creation generates the RSA-3072 signing key pair **server-side in memory** (`crypto.generateKeyPairSync`,
no shell-out) and returns the private key and a ready `app_updater.yaml` in the HTTP response
**exactly once** — never persisted server-side, matching the existing "server never stores private
keys" model. Per-app permissions via a new `app_members` table (`owner`/`member` roles, multiple
owners allowed): only owners can invite/remove members, and an app always keeps at least one owner.
Members can upload/enable/disable patches. Patch validation was refactored out of
`backend/src/routes/admin/patches.js` into shared `backend/src/patchIngest.js` so the portal and the
existing operator/API-key admin routes enforce identical rules from one code path — fully additive,
`/admin/*` (operator keys, root bootstrap key, `app_updater_init.sh`) is untouched and still works
exactly as before. Verified end to end with the new `scripts/verify_portal.sh` (two accounts,
self-service app creation with a real returned key+yaml, access denied before an invite, granted
after, a non-owner member blocked from inviting others, access revoked on removal, last-owner
protection) plus a manual portal patch-upload/enable-disable walkthrough with a real RSA-signed
manifest, and a regression pass of `scripts/verify_admin_auth.sh` and a direct `/admin` patch
upload confirming the shared `patchIngest` refactor didn't disturb the existing path. See
"Developer self-service portal" in `backend/README.md`.

**Portal admin-log view is done** (2026-08-18, `backend/migrations/004_root_users.sql`): the
operator/API-key audit trail (`admin_actions`) was `curl`-only before; a `users.is_root` flag now
gates a `/admin-log` page in the portal showing the same data with a nav link that only root users
see. Granting/revoking `is_root` goes through `POST`/`DELETE /admin/portal-users/:email/promote`
(root operator key only — a regular operator key gets 403) rather than raw SQL, so it needs no
database access and, since it's just another `/admin/*` call, automatically lands in `admin_actions`
too — a manual SQL update wouldn't have been auditable. Verified: a non-root user gets 403 both
before and after being promoted by a *non-root* operator (still 403 — only the true root key can
promote), promotion by the root key works and is itself recorded in the audit log, the promoted
user then gets 200 and sees real `/admin/*` actions, and demotion revokes access again.

**Artifact-size verification is done** (`ota_runtime_android` 0.1.4, 2026-08-18): manifests now
require `artifact_size` (byte size of the uploaded/downloaded artifact file itself — the `.diff` for
`binary_diff`, the full library for `full_aot_library`; *not* the reconstructed target, unlike
`sha256`). Not part of the signed payload (no `signature_payload_v1` version bump needed) — it's a
cheap early-fail sanity check, not a security boundary, since SHA-256 (already signed) fully governs
correctness regardless of size. Checked at both ingest points: `backend/src/patchIngest.js` rejects
an upload whose byte length doesn't match, and `OtaUpdateClient.downloadTo` rejects a downloaded file
whose size doesn't match, before the more expensive SHA-256/reconstruction step ever runs. The debug
`OtaInstallProvider` path derives the size from the already-staged file on disk rather than needing a
new caller-supplied field, so `scripts/install_patch_artifact.sh`/`run_device_acceptance.sh` needed
no changes. `scripts/build_patch.sh` computes and emits the field. Verified: manifest schema fixture
tests (missing `artifact_size` now correctly rejected), and a full device run of
`scripts/run_binary_diff_acceptance.sh` (build → sign → upload → backend-side size check → download
→ client-side size check → resume → corruption-rejection) passing end to end unchanged.

**Exact market-build compatibility is done** (2026-08-26): protocol v2 signs the exact base
`libapp.so` SHA-256 and a deterministic fingerprint over release, Flutter engine, Dart SDK, ABI,
build mode, and base hash. The connected CLI stores that identity with the immutable Play AAB;
the backend only distributes exact matches; Android recomputes the hash from the installed APK or
split APK and verifies it again before boot. Native/resource/plugin changes remain blocked by the
existing Dart-only archive guard. Legacy capability-less clients receive no patch and must update
through the store.

**A real getting-started guide and generic patch-build script are done** (2026-08-18): writing
[GETTING_STARTED.md](../GETTING_STARTED.md) (backend setup, the web portal, mobile integration, day-2
ops) surfaced that `scripts/build_patch.sh` only ever worked against this repo's own `sample_app` —
there was no way to actually build+sign a patch for a real external Flutter project. Added
`scripts/build_patch_for_project.sh`, a fully parameterized equivalent (`--project-dir`,
`--entrypoint`, `--key-id`, `--private-key`, etc., no assumptions about this repo's layout) that
reuses the same already-generic helpers (`extract_artifacts.sh`, `generate_binary_diff.sh`,
`write_manifest_payload.sh`). Verified against `sample_app` treated as an arbitrary external
project for both `full_aot_library` and `binary_diff`: both produced manifests that passed schema
validation and were accepted (`201`) by a real backend upload, confirming the signature,
`artifact_size`, and `sha256` were all computed correctly.

**Instrumentation tests, a bounded failure counter, and a boot watchdog are done** (2026-08-20):
`ota_runtime_android` had zero test infrastructure and no protection beyond `BadPatchStore`'s
permanent per-patch blacklist. Added:
- JVM unit tests (Robolectric, `./gradlew testDebugUnitTest` — no emulator needed) covering invalid/
  corrupt on-disk state (unknown `state` value rejected not coerced, corrupt JSON degrades to null),
  the hash-mismatch fail-closed path (and its intentional asymmetry — a hash mismatch does *not*
  blacklist the patch number, only a stuck `pending_boot` does), the unfinished-boot path, and the
  `AtomicFile` atomic-write guarantee (an aborted write never corrupts previously committed
  content). 19 tests, all green. See "Tests" in `ota_runtime_android/README.md`.
- A cross-patch circuit breaker in `OtaLifecycleStore` (`recordFailure`/`recordSuccess`/
  `circuitOpen`), distinct from `BadPatchStore`'s per-patch blacklist: trips after 3 consecutive
  `PatchLoader` failures (any reason), resets on the next successful boot or automatically after a
  6h cooldown. `OtaUpdateClient.runCheck()` refuses to even contact the backend while it's open —
  protects against a broken build pipeline crash-looping the app once per bad patch pushed.
  Observable via the new `status().circuitOpen` (plumbed through to Dart's `OtaRuntimeStatus` too).
- `BootWatchdog`, a background-thread timer (independent of the main looper) armed the moment a
  patched artifact is selected and disarmed on `markBootSuccess`. Catches a patch that hangs
  instead of crashing — the existing `pending_boot` re-detection only runs on the *next* process
  start, so a main-thread deadlock that never renders a first frame (and never crashes) went
  uncaught until a manual restart. On timeout (20s default) it proactively marks the patch
  `failed`/bad-listed on disk. **Deliberately does not kill the process** — considered and left as
  a possible fast-follow; flag this if it turns out 20s + no forced restart isn't enough in
  practice.
- `docs/rollback_model.md` updated (was stale — still said "no crash-loop counter... timeout").
- The runtime change was verified with `./gradlew testDebugUnitTest` (19/19 green) plus a full run of
  `scripts/run_device_acceptance.sh` against a real device. All 13 existing scenarios passed,
  confirming that the circuit-breaker/watchdog wiring does not break the established flow. The
  runtime is now compiled from the canonical sibling source in the public repository checkout.

**Deliberately still open from this pass:**
- Real Android API/OEM hardware matrix testing — this pass only verified against the one already-
  connected acceptance-test device (via `scripts/run_device_acceptance.sh`/
  `run_binary_diff_acceptance.sh`, which pass unchanged with the new wiring) plus already-known
  constraints (`rsa_pkcs1_sha256` required over `ed25519` on real API 29 hardware, see
  `docs/key_management.md`). No real multi-OEM device matrix exists — would need actual additional
  hardware to do properly.
- Process-kill-on-hang for `BootWatchdog` (see above) — deferred, not forgotten.
- Revisit AGP built-in Kotlin after the pinned Flutter Gradle plugin supports the new DSL cleanly.

Everything below this line is the fuller backlog; the items above are what to pick up next.

Rollout percentages, admin UI, and CDN remain outside Phase 2. iOS Dart patch execution is out of
scope entirely — see `docs/ios_runtime_decision.md`'s final decision.
