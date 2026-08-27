#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <output-file> <schema-version> <protocol-version> <release> <patch-number> <artifact-kind> <engine> <dart> <abi> <build-mode> <base-sha256> <build-fingerprint> <sha256> <key-id> <algorithm>" >&2
  exit 2
}

[[ $# -eq 15 ]] || usage
output_file="$1"
schema_version="$2"
ota_protocol_version="$3"
release="$4"
patch_number="$5"
artifact_kind="$6"
engine_revision="$7"
dart_version="$8"
abi="$9"
build_mode="${10}"
base_sha256="${11}"
build_fingerprint="${12}"
sha256="${13}"
signature_key_id="${14}"
signature_algorithm="${15}"

[[ "$schema_version" == 2 ]] || { echo "Unsupported schema version" >&2; exit 2; }
[[ "$ota_protocol_version" == 2 ]] || { echo "Unsupported OTA protocol version" >&2; exit 2; }
[[ "$patch_number" =~ ^[0-9]+$ ]] || { echo "Invalid patch number" >&2; exit 2; }
[[ "$artifact_kind" =~ ^(full_aot_library|binary_diff)$ ]] || {
  echo "Invalid artifact kind" >&2
  exit 2
}
[[ "$engine_revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid engine revision" >&2; exit 2; }
[[ "$base_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid base SHA-256" >&2; exit 2; }
[[ "$build_fingerprint" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid build fingerprint" >&2; exit 2; }
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid sha256" >&2; exit 2; }
[[ "$signature_key_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid signature key id" >&2; exit 2; }
[[ "$signature_algorithm" =~ ^(ed25519|rsa_pkcs1_sha256)$ ]] || {
  echo "Invalid signature algorithm" >&2
  exit 2
}

printf 'schema_version=%s\nota_protocol_version=%s\nrelease=%s\npatch_number=%s\nartifact_kind=%s\nengine_revision=%s\ndart_version=%s\nabi=%s\nbuild_mode=%s\nbase_sha256=%s\nbuild_fingerprint=%s\nsha256=%s\nsignature_key_id=%s\nsignature_algorithm=%s\n' \
  "$schema_version" "$ota_protocol_version" "$release" "$patch_number" "$artifact_kind" "$engine_revision" \
  "$dart_version" "$abi" "$build_mode" "$base_sha256" "$build_fingerprint" "$sha256" "$signature_key_id" \
  "$signature_algorithm" > "$output_file"
