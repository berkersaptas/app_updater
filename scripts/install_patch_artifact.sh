#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <libapp.so> [package] [patch-manifest]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 3 ]] || usage
artifact="$1"
package_name="${2:-com.berkersaptas.app_updater_sample}"
manifest="${3:-$(dirname "$artifact")/patch_manifest.json}"

[[ -f "$artifact" ]] || { echo "Artifact not found: $artifact" >&2; exit 1; }
[[ -f "$manifest" ]] || { echo "Patch manifest not found: $manifest" >&2; exit 1; }
[[ "$package_name" =~ ^[A-Za-z0-9._]+$ ]] || { echo "Invalid package name" >&2; exit 2; }

json_string() {
  sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" "$manifest" | head -1
}

release="$(json_string release)"
engine_revision="$(json_string engine_revision)"
dart_version="$(json_string dart_version)"
abi="$(json_string abi)"
build_mode="$(json_string build_mode)"
expected_hash="$(json_string sha256)"
signature_key_id="$(json_string signature_key_id)"
signature_algorithm="$(json_string signature_algorithm)"
signature="$(json_string signature)"
artifact_kind="$(json_string artifact_kind)"
patch_number="$(sed -n 's/.*"patch_number": \([0-9][0-9]*\).*/\1/p' "$manifest" | head -1)"

[[ "$patch_number" =~ ^[0-9]+$ ]] || { echo "Invalid manifest patch_number" >&2; exit 2; }
[[ "$engine_revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid engine revision" >&2; exit 2; }
[[ "$abi" =~ ^(arm64-v8a|armeabi-v7a|x86_64)$ ]] || { echo "Invalid ABI" >&2; exit 2; }
[[ "$build_mode" == release ]] || { echo "Only release patches are accepted" >&2; exit 2; }
[[ "$artifact_kind" =~ ^(full_aot_library|binary_diff)$ ]] || { echo "Invalid artifact kind" >&2; exit 2; }
[[ "$signature_key_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid signature key id" >&2; exit 2; }
[[ "$signature_algorithm" =~ ^(ed25519|rsa_pkcs1_sha256)$ ]] || { echo "Invalid signature algorithm" >&2; exit 2; }
[[ "$signature" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid signature" >&2; exit 2; }

if [[ "$artifact_kind" == full_aot_library ]]; then
  hash="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  [[ "$hash" == "$expected_hash" ]] || {
    echo "Artifact hash does not match patch manifest" >&2
    exit 1
  }
  artifact_file_name="libapp.so"
else
  # For binary_diff, manifest sha256 is the reconstructed target artifact's hash, not the diff
  # blob being staged here. The runtime verifies it after applying the diff on-device.
  hash="$expected_hash"
  artifact_file_name="libapp.so.diff"
fi
authority="$package_name.ota-installer"

adb shell content write \
  --uri "content://$authority/patches/$patch_number/$artifact_file_name" < "$artifact"
adb shell content call \
  --uri "content://$authority" \
  --method activate \
  --arg "$release~$patch_number~$artifact_kind~$hash~$engine_revision~$dart_version~$abi~$build_mode~$signature_key_id~$signature_algorithm~$signature"

echo "Installed patch $patch_number in app-private storage"
echo "sha256 (final artifact): $hash"
echo "Force-stop and restart the app so a new Dart VM can select it."
