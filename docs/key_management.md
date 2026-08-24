# OTA signing key management

The recommended connected workflow uses a server-managed RSA-3072 signer per app. App creation
generates the key on the backend; only the public key is written to `app_updater.yaml`, while
the private PEM is encrypted with AES-256-GCM under the exactly 32-byte `SIGNING_MASTER_KEY`.
Developers never receive or copy the private key. The backend signs only after validating the
release, ABI, Flutter/Dart compatibility, manifest, and artifact size.

The runtime signing contract still has three separate concepts:

- `signatureActiveKeyId`: the key id used by the patch build/signing job.
- `signatureTrustedKeys`: the public keyring embedded in the APK, encoded as
  `key_id:base64url_der,key_id:base64url_der`.
- `signatureRevokedKeyIds`: key ids that must be rejected even if their public key is still present
  in the trusted keyring.

The private signing key must never ship in the APK or app repository. Local scripts under `keys/`
and the old `app_updater publish` command are legacy/POC paths. The current encrypted database custody
is suitable for controlled pilots; production deployment should replace the environment master key
and decrypt-in-process signer with KMS/HSM-backed envelope encryption or remote signing.

## Shorebird signing alignment

Shorebird's public patch-signing docs describe RSA PEM keys and command-based signing for KMS/HSM
systems. This project now supports both the compact Ed25519 POC path and the Shorebird-aligned
`rsa_pkcs1_sha256` verification path on Android.

Signer modes:

- managed RSA-3072: current connected default, verified as `SHA256withRSA`;
- `ed25519-local`: legacy POC mode with a local ignored private key;
- `rsa-pem-local`: legacy/local RSA PEM mode;
- `sign-command`: command reads payload from stdin and returns a base64 signature.
- `kms-command`: wrapper around GCP KMS, AWS KMS, Azure Key Vault, Vault Transit, or equivalent.

The runtime verifier knows which signature algorithm a release embeds through the signed
`signature_algorithm` manifest field. Android currently accepts `ed25519` and
`rsa_pkcs1_sha256`.

**Real device finding (2026-08-17):** `ed25519` verification failed on a real Android 10 (API 29)
device — `Signature.getInstance("Ed25519")` throws `NoSuchAlgorithmException` on that OS version
(Ed25519 JCA/Conscrypt support is newer-Android only); `PatchSignatureVerifier`'s catch-all turns
that into an ordinary "signature could not be verified" rejection, indistinguishable from an actual
bad signature in the logs. `rsa_pkcs1_sha256` verified correctly on the same device. Given this
project's actual goal (self-hosting across 30-40 company apps with an unknown, likely mixed, device
fleet), **prefer `rsa_pkcs1_sha256` as the default production signing algorithm** until the minimum
Android version with reliable `ed25519` JCA support is characterized. See
`docs/architecture_and_remaining_work.md`'s "Client wiring, device-verified" section for the full
device trace.

## Patch verification order

The Android runtime checks every patch before activation and before every patched boot:

1. Manifest schema must be supported.
2. `signature_key_id` must not be revoked.
3. `signature_key_id` must exist in the APK-embedded trusted keyring.
4. Signature must verify over the canonical payload using the release's configured algorithm.
5. Artifact SHA-256 must match.
6. Release, engine revision, Dart SDK, ABI, and build mode must match the installed app.

Any failure selects the APK-packaged base `libapp.so`.

## Rotation model

The overlap procedure below remains the required model, but a managed-signer rotation endpoint and
multi-active-key UI are not implemented yet. Until they are, key rotation requires an operator-led
new app-key/signer registration and a normal Play release containing the overlap keyring.

Use overlapping releases:

1. Current app trusts key `A`; patches are signed by `A`.
2. Ship an app release that trusts both `A` and `B`, while the active signer remains `A`.
3. Switch the patch signing job to `B` after enough users have the app release that trusts `B`.
4. Ship a later app release that trusts only `B`.

For the POC scripts:

```bash
OTA_SIGNATURE_ACTIVE_KEY_ID=release-2026-q3 ./scripts/generate_dev_signing_key.sh
./scripts/print_signature_keyring.sh release-2026-q3
```

In production, set these values in CI before building the APK:

```bash
export OTA_SIGNATURE_ACTIVE_KEY_ID=release-2026-q3
export OTA_SIGNATURE_TRUSTED_KEYS='release-2026-q2:<public-key>,release-2026-q3:<public-key>'
export OTA_SIGNATURE_REVOKED_KEY_IDS=''
./scripts/generate_compatibility_metadata.sh
```

Then sign patches with the matching private key:

```bash
export OTA_SIGNING_KEY_PATH=/secure/path/release-2026-q3_private.pem
./scripts/build_patched.sh
```

For local RSA signing:

```bash
export OTA_SIGNATURE_ALGORITHM=rsa_pkcs1_sha256
export OTA_SIGNATURE_ACTIVE_KEY_ID=release-rsa-2026-q3
./scripts/build_patched.sh
```

Or sign patches with a command-based signer. The command reads the canonical payload from stdin and
prints a base64/base64url signature to stdout:

```bash
export OTA_PUBLIC_KEY_CMD='./kms-public-key.sh'
export OTA_SIGN_CMD='./kms-sign.sh'
./scripts/build_patched.sh
```

`OTA_PUBLIC_KEY_CMD` is the key-publication counterpart to `OTA_SIGN_CMD`. When set, it must print
the base64url-encoded DER public key to stdout, and
`scripts/generate_compatibility_metadata.sh` uses it instead of reading a public key file:

```bash
export OTA_PUBLIC_KEY_CMD='./kms-public-key.sh'
export OTA_SIGNATURE_ACTIVE_KEY_ID=release-2026-q3
./scripts/generate_compatibility_metadata.sh
```

`scripts/verify_sign_command.sh` exercises this whole command-based boundary end to end with a fake
KMS signer for both `ed25519` and `rsa_pkcs1_sha256`.

## Revocation model

Revocation is for emergency rejection of a known compromised signing key. The next APK release
should embed the compromised key id in `signatureRevokedKeyIds`:

```bash
export OTA_SIGNATURE_ACTIVE_KEY_ID=release-2026-q4
export OTA_SIGNATURE_TRUSTED_KEYS='release-2026-q3:<public-key>,release-2026-q4:<public-key>'
export OTA_SIGNATURE_REVOKED_KEY_IDS='release-2026-q3'
./scripts/generate_compatibility_metadata.sh
```

The runtime checks revocation before trust, so a revoked key id is rejected even if its public key
remains in the trusted keyring for rollout overlap.

## Production custody requirements

- Generate signing keys outside developer laptops.
- Restrict signing permission to the release pipeline.
- Log every signing request with release, patch number, artifact hash, key id, and operator/build id.
- Keep public key ids stable and human-readable.
- Store private keys in HSM/KMS where extraction is impossible or tightly audited.
- Maintain a documented emergency APK release path for key revocation.
- Prefer command-based signing in CI so private keys are not materialized on disk.
