#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_dir="$repo_dir/keys"
signature_algorithm="${OTA_SIGNATURE_ALGORITHM:-ed25519}"
case "$signature_algorithm" in
  ed25519) default_key_id="dev-ed25519-v1" ;;
  rsa_pkcs1_sha256) default_key_id="dev-rsa-v1" ;;
  *) echo "Invalid OTA_SIGNATURE_ALGORITHM: $signature_algorithm" >&2; exit 2 ;;
esac
key_id="${OTA_SIGNATURE_ACTIVE_KEY_ID:-$default_key_id}"
[[ "$key_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid OTA key id: $key_id" >&2
  exit 2
}
private_key="$key_dir/${key_id}_private.pem"
public_key="$key_dir/${key_id}_public.der"

mkdir -p "$key_dir"
if [[ ! -f "$private_key" ]]; then
  case "$signature_algorithm" in
    ed25519)
      openssl genpkey -algorithm ED25519 -out "$private_key"
      ;;
    rsa_pkcs1_sha256)
      openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key"
      ;;
  esac
  chmod 600 "$private_key"
  echo "Generated dev OTA signing key '$key_id' ($signature_algorithm): $private_key"
fi

openssl pkey -in "$private_key" -pubout -outform DER -out "$public_key"
echo "OTA dev signing key is ready: $key_id ($signature_algorithm)"
