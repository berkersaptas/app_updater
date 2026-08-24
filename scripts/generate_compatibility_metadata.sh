#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
metadata="$(flutter --version --machine)"
engine_revision="$(printf '%s\n' "$metadata" | sed -n 's/.*"engineRevision": "\([^"]*\)".*/\1/p')"
dart_version="$(printf '%s\n' "$metadata" | sed -n 's/.*"dartSdkVersion": "\([^"]*\)".*/\1/p')"
signature_algorithm="${OTA_SIGNATURE_ALGORITHM:-ed25519}"
case "$signature_algorithm" in
  ed25519) default_key_id="dev-ed25519-v1" ;;
  rsa_pkcs1_sha256) default_key_id="dev-rsa-v1" ;;
  *) echo "Invalid OTA_SIGNATURE_ALGORITHM: $signature_algorithm" >&2; exit 2 ;;
esac
signature_active_key_id="${OTA_SIGNATURE_ACTIVE_KEY_ID:-$default_key_id}"
public_key_der="${OTA_SIGNATURE_PUBLIC_KEY_PATH:-$repo_dir/keys/${signature_active_key_id}_public.der}"
signature_trusted_keys="${OTA_SIGNATURE_TRUSTED_KEYS:-}"
signature_revoked_key_ids="${OTA_SIGNATURE_REVOKED_KEY_IDS:-}"

[[ "$engine_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "Could not determine Flutter engine revision" >&2
  exit 1
}
[[ -n "$dart_version" ]] || { echo "Could not determine Dart SDK version" >&2; exit 1; }

if [[ -n "${OTA_PUBLIC_KEY_CMD:-}" ]]; then
  public_key_base64url="$(sh -c "$OTA_PUBLIC_KEY_CMD")"
else
  [[ -f "$public_key_der" ]] || {
    echo "Missing OTA public key: $public_key_der" >&2
    echo "Run scripts/generate_dev_signing_key.sh, set OTA_SIGNATURE_PUBLIC_KEY_PATH, or set OTA_PUBLIC_KEY_CMD" >&2
    exit 1
  }
  public_key_base64url="$(openssl base64 -A -in "$public_key_der" | tr '+/' '-_' | tr -d '=')"
fi
[[ "$public_key_base64url" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "OTA public key command/file produced invalid base64url output" >&2
  exit 1
}
if [[ -z "$signature_trusted_keys" ]]; then
  signature_trusted_keys="$signature_active_key_id:$public_key_base64url"
fi
[[ "$signature_active_key_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid OTA signature active key id" >&2
  exit 2
}
[[ "$signature_trusted_keys" =~ ^[A-Za-z0-9._:,-]+$ ]] || {
  echo "Invalid OTA trusted keyring encoding" >&2
  exit 2
}
if [[ -n "$signature_revoked_key_ids" && ! "$signature_revoked_key_ids" =~ ^[A-Za-z0-9._,-]+$ ]]; then
  echo "Invalid OTA revoked key id list" >&2
  exit 2
fi

properties_file="$repo_dir/sample_app/android/ota.properties"
properties_tmp="$properties_file.tmp"
printf 'engineRevision=%s\ndartVersion=%s\nbuildMode=release\nsignatureActiveKeyId=%s\nsignatureTrustedKeys=%s\nsignatureRevokedKeyIds=%s\n' \
  "$engine_revision" "$dart_version" "$signature_active_key_id" "$signature_trusted_keys" \
  "$signature_revoked_key_ids" > "$properties_tmp"
mv "$properties_tmp" "$properties_file"

echo "OTA compatibility: engine=$engine_revision dart=$dart_version mode=release active_key=$signature_active_key_id algorithm=$signature_algorithm"
