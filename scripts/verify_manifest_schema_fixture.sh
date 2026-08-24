#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_dir/ota_core/manifest.schema.json"
fixture="$repo_dir/ota_core/fixtures/android_arm64_patch_manifest.json"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

python3 "$repo_dir/scripts/validate_json_schema.py" "$schema" "$fixture"

mutate() {
  local out="$1"
  shift
  python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)
for op in sys.argv[3:]:
    key, _, value = op.partition("=")
    if value == "__DELETE__":
        manifest.pop(key, None)
    else:
        manifest[key] = value
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(manifest, f)
' "$fixture" "$out" "$@"
}

expect_invalid() {
  local name="$1"
  local instance="$2"
  if python3 "$repo_dir/scripts/validate_json_schema.py" "$schema" "$instance" >/dev/null 2>&1; then
    echo "Expected invalid manifest fixture to fail validation: $name" >&2
    exit 1
  fi
}

missing_signature="$work_dir/missing_signature.json"
mutate "$missing_signature" "signature=__DELETE__"
expect_invalid "missing signature" "$missing_signature"

bad_algorithm="$work_dir/bad_algorithm.json"
mutate "$bad_algorithm" "signature_algorithm=rot13"
expect_invalid "invalid signature_algorithm" "$bad_algorithm"

bad_sha256="$work_dir/bad_sha256.json"
mutate "$bad_sha256" "sha256=not-a-hash"
expect_invalid "malformed sha256" "$bad_sha256"

missing_artifact_size="$work_dir/missing_artifact_size.json"
mutate "$missing_artifact_size" "artifact_size=__DELETE__"
expect_invalid "missing artifact_size" "$missing_artifact_size"

echo "OTA manifest schema fixture is valid and rejects invalid manifests"
