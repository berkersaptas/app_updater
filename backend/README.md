# OTA backend

Implements `docs/production_installer_contract.md` for real: a Postgres-backed HTTP service that
registers apps, accepts signed patch uploads, serves patch-check requests, serves artifact
downloads, and accepts patch events. This is what replaces manual `adb shell content write` once a
real network update-client exists on the device side (that client wiring is a separate, later
phase — this backend does not change `ota_runtime_android` at all).

Stack: Node + Express, Postgres, local-disk artifact storage. The recommended developer path is:

```bash
app_updater login --backend-url https://updates.example.com
app_updater init --app-slug my-app-android
app_updater release android
app_updater patch android
```

The `/v1/cli` API stores immutable release bases and uses an encrypted managed signer, so the
developer does not copy API keys or private keys. Two lower-level management paths remain:

This connected path is device-verified on Android 16/arm64: a registered 15.4 MB AAB base produced
a 34,608-byte patch, staged on the `Hello v1` launch, and activated as `Hello v2`/`active` on the
next cold launch.

- **The developer self-service portal** (`/`, session-authenticated, email+password accounts,
  per-app ownership/membership) — the normal path for a developer to create their own app and share
  it with teammates without going through ops. See "Developer self-service portal" below.
- **Per-operator API keys** (`/admin/*`, see "Admin auth and audit log" below) — for cross-app
  ops-level access; a single static root key only for bootstrapping operators.

A legacy, narrower credential sits between the two: an **app-scoped publish key**
(`app_publish_keys` table), self-issued by any app member from the portal (`/apps/<slug>`,
"Publish keys") and used with `X-Api-Key` exactly like an operator key — except `adminAuth`
(`src/middleware/adminAuth.js`) resolves it to `req.scopedAppId` instead of an operator name, and
every `/admin/*` router except `patches.js` rejects it outright (`requireUnscopedOperator`
middleware). `patches.js`'s own handlers check `req.scopedAppId` against the `:appSlug` in the URL,
so a publish key can upload/list/enable/disable patches for its one app and nothing else — not
other apps, and not app-creation/operator-management endpoints. This is what the legacy
`app_updater publish` command authenticates with, so a company app's CI or a developer's laptop only ever
holds a credential that can hurt that one app if leaked.

Both drive the same underlying tables and the same patch validation logic
(`backend/src/patchIngest.js`); neither depends on the other. See `engine_notes/` and
`docs/architecture_and_remaining_work.md` for why these choices.

## Run it

```bash
docker compose up --build
```

This starts `postgres` and `backend`, published on host port `8081` by default (container port stays
`8080`; override with `BACKEND_HOST_PORT` if `8081` is already taken on your machine — port
conflicts are silent and confusing to debug, so check `lsof -i :8081` first if requests seem to go
nowhere). The backend applies numbered migrations before starting, including against an existing
Postgres volume. Compose's `ADMIN_API_KEY`, `SESSION_SECRET`, and `SIGNING_MASTER_KEY` defaults are
development-only. Production must provide strong values; `SIGNING_MASTER_KEY` must be exactly 32
UTF-8 bytes and backed up because it encrypts the managed app signers.

To reach this backend from a real Android device over USB instead of an emulator, forward the
device's `localhost:8080` (what `OtaUpdateConfig.baseUrl` in `MainActivity.kt` uses) to the host's
published port:

```bash
adb reverse tcp:8080 tcp:8081
```

By default the backend rejects `full_aot_library` uploads and accepts only Shorebird-style
`binary_diff` patches. This is the safe Play/production posture. Local POC tests that deliberately
exercise whole-`.so` replacement may opt in with `ALLOW_FULL_AOT_LIBRARY=true`; do not enable it on
a Google Play/production backend. See `docs/google_play_compliance.md`.

For running the backend outside Docker against a local Postgres, copy `.env.example` to `.env` and
adjust `DATABASE_URL`.

## Developer self-service portal

Open `http://localhost:8081/` in a browser (or `curl` the same routes). No admin/operator key
needed for any of this — it's meant for individual developers to use directly:

1. **Register** at `/auth/register` (email + password). Anyone can create an account; this only grants
   *an account*, not access to any particular app.
2. **Create an app** from the dashboard (`/`) or with `app_updater init --create`. You become its
   `owner`. The server generates an RSA-3072 signer, publishes only its public key in the app
   configuration, and stores the private key encrypted with `SIGNING_MASTER_KEY`. No secret is
   shown to or copied by the developer. CLI creation also discovers and uploads the Flutter
   launcher logo when available.
3. **Invite teammates** from the app's page (`/apps/<slug>`) — owners can invite any already-
   registered user by email as `owner` or `member`; only owners can invite/remove people, and an
   app always keeps at least one owner. Members can upload/enable/disable patches but not manage
   membership.
4. **Build releases and patches** with `app_updater release android` and `app_updater patch android`.
   Patches can still be toggled from the app page. The old manual upload remains available for
   legacy externally signed apps.

App logos are independent profile assets, not release/patch metadata. Owners can replace or remove
them from the app page or upload one with `app_updater init --icon path/to/logo.png`. Images are
validated, stripped of source metadata, center-cropped, and stored as 64 px and 256 px WebP
variants. Existing apps need no migration work in the client: they render a letter fallback until
a logo is uploaded.

`scripts/verify_portal.sh` exercises this end to end against a real Docker backend: two accounts,
self-service app creation with a returned key/yaml, an uninvited user denied access, an invited
member granted access but blocked from inviting others, removal revoking access again, and the
last-owner-cannot-be-removed guard.

## Admin auth and audit log

`ADMIN_API_KEY` is a **root bootstrap key** — it exists only to mint the first real operators and
should not be handed out for day-to-day use. Every other admin/ingestion call requires a
per-operator API key:

```bash
API=http://localhost:8081
ROOT=dev-admin-key

# Root creates an operator. The plaintext api_key is returned exactly once — only its SHA-256 hash
# is stored (operators.api_key_hash); there is no way to recover it later, only to revoke and
# recreate.
curl -s -X POST "$API/admin/operators" -H "X-Api-Key: $ROOT" -H "Content-Type: application/json" \
  -d '{"name":"alice"}'
# => {"id":"...","name":"alice","revoked":false,"created_at":"...","api_key":"<give this to alice>"}

# Alice now uses her own key for ordinary admin calls (register apps/keys/patches, enable/disable
# patches) — same routes and payloads as before, just a different key per person.
curl -s -X POST "$API/admin/apps" -H "X-Api-Key: <alice's api_key>" -H "Content-Type: application/json" \
  -d '{"slug":"my-app-android","platform":"android","package_name":"com.example.my_app"}'

# Root revokes an operator (soft delete — kept for audit, matches the key revocation model in
# docs/key_management.md).
curl -s -X DELETE "$API/admin/operators/<alice's id>" -H "X-Api-Key: $ROOT"

# Any authenticated operator can list operators (no secrets in the response) and read the audit log.
curl -s "$API/admin/operators" -H "X-Api-Key: $ROOT"
curl -s "$API/admin/actions?limit=50" -H "X-Api-Key: $ROOT"
```

Every request under `/admin/*` — successful, denied, or from an unrecognized key — is recorded in
`admin_actions` (operator name, method, path, status code, timestamp) regardless of outcome, so a
denied or revoked-key attempt is visible too, not just successful actions. There's also a browser
view of this at `/admin-log` in the portal, gated behind a portal user's `is_root` flag.

```bash
# Only the root ADMIN_API_KEY can grant/revoke a portal user's is_root flag — not even a regular
# operator key can (403). This itself lands in admin_actions like any other /admin/* call, unlike
# a raw SQL update would.
curl -s -X POST "$API/admin/portal-users/someone@example.com/promote" -H "X-Api-Key: $ROOT"
curl -s -X DELETE "$API/admin/portal-users/someone@example.com/promote" -H "X-Api-Key: $ROOT"
curl -s "$API/admin/portal-users" -H "X-Api-Key: $ROOT"
```

`scripts/verify_admin_auth.sh` exercises this end to end against a real Docker backend: an unknown
key is rejected, a non-root operator cannot mint other operators, a freshly minted operator's key
works for ordinary admin actions, revoking it blocks further use, and the audit log captures all of
it.

## Data model

The full signed manifest is stored as `jsonb` in `patches.manifest`, with a few Postgres *generated
columns* (`release`, `patch_number`, `artifact_kind`, `abi`, `build_mode`) extracted from it for
indexed queries. This keeps both Android's `ota_core/manifest.schema.json` and iOS's (differently
shaped) `ota_core/ios_interpreted_patch.schema.json` representable in the same table without a
migration when iOS patch ingestion is added later.

`manifest.sha256` is always the hash of the *final loadable artifact*, matching what
`PatchLoader.kt` checks after resolution regardless of artifact kind — for `full_aot_library` that's
the uploaded file itself (checked on ingest); for `binary_diff` it's the reconstructed target, which
only the device can verify after applying the diff (same reasoning as
`scripts/install_patch_artifact.sh`), so ingest does not re-check it for that kind.

## Full walkthrough (curl)

This mirrors what was manually verified against a real Phase 2E `binary_diff` patch produced and
device-verified in this project's own `sample_app` build. Uses the root key directly for brevity;
in real day-to-day use, mint a per-operator key first (see "Admin auth and audit log" above) and use
that instead — the root key works on every admin route too, but it's meant only for bootstrapping.

```bash
API=http://localhost:8081
KEY=dev-admin-key

# 1. Register an app.
curl -s -X POST "$API/admin/apps" -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"slug":"sample-app-android","platform":"android","package_name":"com.berkersaptas.app_updater_sample"}'

# 2. Register its trusted signing key (base64url-encoded DER, same encoding
#    scripts/print_signature_keyring.sh already produces).
PUBKEY="$(openssl base64 -A -in ../keys/dev-ed25519-v1_public.der | tr '+/' '-_' | tr -d '=')"
curl -s -X POST "$API/admin/apps/sample-app-android/keys" -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
  -d "{\"key_id\":\"dev-ed25519-v1\",\"public_key_der_base64url\":\"$PUBKEY\",\"algorithm\":\"ed25519\"}"

# 3. Upload a real signed patch (manifest + artifact). Server verifies schema, signature, and
#    (for full_aot_library) the artifact hash before accepting it.
curl -s -X POST "$API/admin/apps/sample-app-android/patches" -H "X-Api-Key: $KEY" \
  -F "manifest=@../patch_artifacts/patched/patch_manifest.json;type=application/json" \
  -F "artifact=@../patch_artifacts/patched/libapp.so.diff;type=application/octet-stream"

# 4. A device checks for a patch.
curl -s -X POST "$API/v1/apps/sample-app-android/patch-check" -H "Content-Type: application/json" \
  -d '{"channel":"stable","release_version":"1.0.0+1","current_patch_number":0,"platform":"android","arch":"arm64-v8a","ota_protocol_version":2,"engine_revision":"<40-hex>","dart_version":"<version>","build_mode":"release","base_sha256":"<64-hex>","build_fingerprint":"<64-hex>"}'

# 5. Download the artifact the patch-check response pointed at.
curl -s "$API/v1/apps/sample-app-android/patches/1/artifact" -o downloaded.diff

# 6. Device reports success.
curl -s -X POST "$API/v1/apps/sample-app-android/events" -H "Content-Type: application/json" \
  -d '{"platform":"android","arch":"arm64-v8a","type":"PatchInstallSuccess","release_version":"1.0.0+1","patch_number":1}'

# 7. Kill switch: disable the patch, confirm patch-check stops offering it.
curl -s -X PATCH "$API/admin/apps/sample-app-android/patches/1" -H "X-Api-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"enabled":false}'
curl -s -X POST "$API/v1/apps/sample-app-android/patch-check" -H "Content-Type: application/json" \
  -d '{"channel":"stable","release_version":"1.0.0+1","current_patch_number":1,"platform":"android","arch":"arm64-v8a","ota_protocol_version":2,"engine_revision":"<40-hex>","dart_version":"<version>","build_mode":"release","base_sha256":"<64-hex>","build_fingerprint":"<64-hex>"}'
```

## Client wiring

`ota_runtime_android`'s `OtaUpdateClient` (see `ota_runtime_android/src/main/kotlin/com/app_updater/ota_runtime/OtaUpdateClient.kt`)
implements the device side of this contract against this backend: `patch-check` at startup on a
background thread, artifact download, signature/schema verification (reusing
`PatchSignatureVerifier`/`PatchInstaller`), staging as `pending` for the next launch, and best-effort
event posting. It never touches the artifact selected for the *current* boot — only prepares one for
the next. `app_updater` starts it from Dart through
`AppUpdater.instance.autoUpdate()`; `adb reverse` is only needed for a local backend/device test.

## What this still does not do

- Per-operator keys have exactly one privilege level (they can all touch every app/patch/key) — no
  per-app or read-only roles yet. Fine for a small internal team; revisit if that changes.
- Does not implement channels beyond a single `stable` default, or staged rollout percentages.
- Local-disk artifacts, the environment-held signing master key, and compose Postgres still need
  durable storage/backups, monitoring, and KMS/HSM integration for fleet production.
- Managed signer rotation and self-service overlap-key rollout are not implemented yet.
- Does not implement iOS patch ingestion — the schema-flexible `manifest jsonb` column is ready for
  it, but no route validates against `ota_core/ios_interpreted_patch.schema.json` yet.
