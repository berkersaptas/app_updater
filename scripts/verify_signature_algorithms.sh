#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

payload_for() {
  local output="$1"
  local key_id="$2"
  local algorithm="$3"
  "$repo_dir/scripts/write_manifest_payload.sh" "$output" 2 2 "1.0.0+1" 1 \
    full_aot_library 83675ed27633283e7fc296c8bca22e841224c096 3.12.2 \
    arm64-v8a release aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    46612b3568f1b3220765c4138063d6940fdb87bc5dd5197555bd3c188e0be766 \
    ec59d1df4b8a03d38eaf99f01a599eb7e2572f4c4f6f694a409e6da2304a9cb7 \
    "$key_id" "$algorithm"
}

verify_ed25519() {
  local private_key="$work_dir/ed25519_private.pem"
  local public_key="$work_dir/ed25519_public.pem"
  local payload="$work_dir/ed25519_payload.txt"
  local signature="$work_dir/ed25519_signature.bin"

  openssl genpkey -algorithm ED25519 -out "$private_key" >/dev/null 2>&1
  openssl pkey -in "$private_key" -pubout -out "$public_key"
  payload_for "$payload" dev-ed25519-v1 ed25519
  openssl pkeyutl -sign -rawin -inkey "$private_key" -in "$payload" > "$signature"
  openssl pkeyutl -verify -rawin -pubin -inkey "$public_key" -in "$payload" \
    -sigfile "$signature" >/dev/null
}

verify_rsa_pkcs1_sha256() {
  local private_key="$work_dir/rsa_private.pem"
  local public_key="$work_dir/rsa_public.pem"
  local payload="$work_dir/rsa_payload.txt"
  local signature="$work_dir/rsa_signature.bin"

  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key" >/dev/null 2>&1
  openssl pkey -in "$private_key" -pubout -out "$public_key"
  payload_for "$payload" dev-rsa-v1 rsa_pkcs1_sha256
  openssl dgst -sha256 -sign "$private_key" -binary "$payload" > "$signature"
  openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$payload" >/dev/null
}

verify_ed25519
verify_rsa_pkcs1_sha256

echo "OTA signature algorithms are valid"
