#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="$repo_dir/ota_core/ios_interpreted_patch.schema.json"
fixture="$repo_dir/ota_core/fixtures/ios_interpreted_patch.json"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

python3 "$repo_dir/scripts/validate_json_schema.py" "$schema" "$fixture"

out_of_range="$work_dir/out_of_range_link_percentage.json"
python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    patch = json.load(f)
patch["linked_code_metadata"]["minimum_link_percentage"] = 150
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(patch, f)
' "$fixture" "$out_of_range"

if python3 "$repo_dir/scripts/validate_json_schema.py" "$schema" "$out_of_range" >/dev/null 2>&1; then
  echo "Expected out-of-range minimum_link_percentage to fail validation" >&2
  exit 1
fi

echo "iOS interpreted patch fixture is valid and rejects invalid metadata"
