#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_dir/ota_core/fixtures/android_arm64_patch_manifest.json"
expected_payload="$repo_dir/ota_core/fixtures/android_arm64_patch_payload.txt"
actual_payload="$(mktemp)"

json_string() {
  sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" "$manifest" | head -1
}

schema_version="$(sed -n 's/.*"schema_version": \([0-9][0-9]*\).*/\1/p' "$manifest" | head -1)"
release="$(json_string release)"
patch_number="$(sed -n 's/.*"patch_number": \([0-9][0-9]*\).*/\1/p' "$manifest" | head -1)"
artifact_kind="$(json_string artifact_kind)"
engine_revision="$(json_string engine_revision)"
dart_version="$(json_string dart_version)"
abi="$(json_string abi)"
build_mode="$(json_string build_mode)"
sha256="$(json_string sha256)"
signature_key_id="$(json_string signature_key_id)"
signature_algorithm="$(json_string signature_algorithm)"

"$repo_dir/scripts/write_manifest_payload.sh" "$actual_payload" "$schema_version" "$release" \
  "$patch_number" "$artifact_kind" "$engine_revision" "$dart_version" "$abi" "$build_mode" \
  "$sha256" "$signature_key_id" "$signature_algorithm"

if ! cmp -s "$expected_payload" "$actual_payload"; then
  echo "OTA core fixture payload does not match manifest-derived payload" >&2
  diff -u "$expected_payload" "$actual_payload" >&2 || true
  rm -f "$actual_payload"
  exit 1
fi

rm -f "$actual_payload"
echo "OTA core fixture payload is valid"
