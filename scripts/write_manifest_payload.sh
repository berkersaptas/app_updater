#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <output-file> <schema-version> <release> <patch-number> <artifact-kind> <engine> <dart> <abi> <build-mode> <sha256> <key-id> <algorithm>" >&2
  exit 2
}

[[ $# -eq 12 ]] || usage
output_file="$1"
schema_version="$2"
release="$3"
patch_number="$4"
artifact_kind="$5"
engine_revision="$6"
dart_version="$7"
abi="$8"
build_mode="$9"
sha256="${10}"
signature_key_id="${11}"
signature_algorithm="${12}"

[[ "$schema_version" == 1 ]] || { echo "Unsupported schema version" >&2; exit 2; }
[[ "$patch_number" =~ ^[0-9]+$ ]] || { echo "Invalid patch number" >&2; exit 2; }
[[ "$artifact_kind" =~ ^(full_aot_library|binary_diff)$ ]] || {
  echo "Invalid artifact kind" >&2
  exit 2
}
[[ "$engine_revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid engine revision" >&2; exit 2; }
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid sha256" >&2; exit 2; }
[[ "$signature_key_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid signature key id" >&2; exit 2; }
[[ "$signature_algorithm" =~ ^(ed25519|rsa_pkcs1_sha256)$ ]] || {
  echo "Invalid signature algorithm" >&2
  exit 2
}

printf 'schema_version=%s\nrelease=%s\npatch_number=%s\nartifact_kind=%s\nengine_revision=%s\ndart_version=%s\nabi=%s\nbuild_mode=%s\nsha256=%s\nsignature_key_id=%s\nsignature_algorithm=%s\n' \
  "$schema_version" "$release" "$patch_number" "$artifact_kind" "$engine_revision" \
  "$dart_version" "$abi" "$build_mode" "$sha256" "$signature_key_id" \
  "$signature_algorithm" > "$output_file"
