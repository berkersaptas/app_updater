#!/usr/bin/env bash
set -euo pipefail

# Builds and signs a patch for ANY Flutter project (unlike scripts/build_patch.sh, which only
# works against this repo's own sample_app for internal testing). This is what a real company
# app's CI (or a developer's machine) runs to produce a patch_manifest.json + artifact ready to
# upload to the backend, using the private key scripts/app_updater_init.sh (or the web portal's
# create-app page) handed out.

usage() {
  cat >&2 <<'EOF'
Usage: scripts/build_patch_for_project.sh \
  --project-dir <path> --entrypoint <path-relative-to-project> --patch-number <n> \
  --key-id <key-id> --private-key <path-to-pem> \
  [--algorithm rsa_pkcs1_sha256|ed25519] [--artifact-kind binary_diff|full_aot_library] \
  [--base-apk <path>] [--allow-full-aot-library] \
  [--target-platform android-arm64|android-arm|android-x64] \
  [--output-dir <path>]

binary_diff is the production-safe default. --base-apk must be the archived release APK currently
in users' hands, built for the same single ABI. It is used to derive the base libapp.so and prove
that no manifest, DEX, native library, resource, or asset changed outside Dart's libapp.so.

full_aot_library requires --allow-full-aot-library and is only for local POC/testing backends that
explicitly enable ALLOW_FULL_AOT_LIBRARY=true. Play/production backends reject it by default.
EOF
  exit 2
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_dir=""
entrypoint=""
patch_number=""
key_id=""
private_key=""
algorithm="rsa_pkcs1_sha256"
artifact_kind="binary_diff"
base_apk=""
allow_full_aot_library=false
target_platform="android-arm64"
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) project_dir="$2"; shift 2 ;;
    --entrypoint) entrypoint="$2"; shift 2 ;;
    --patch-number) patch_number="$2"; shift 2 ;;
    --key-id) key_id="$2"; shift 2 ;;
    --private-key) private_key="$2"; shift 2 ;;
    --algorithm) algorithm="$2"; shift 2 ;;
    --artifact-kind) artifact_kind="$2"; shift 2 ;;
    --base-apk) base_apk="$2"; shift 2 ;;
    --allow-full-aot-library) allow_full_aot_library=true; shift ;;
    --target-platform) target_platform="$2"; shift 2 ;;
    --output-dir) output_dir="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$project_dir" && -n "$entrypoint" && -n "$patch_number" && -n "$key_id" && -n "$private_key" ]] || usage
[[ "$patch_number" =~ ^[0-9]+$ ]] || { echo "Invalid patch number" >&2; exit 2; }
[[ "$algorithm" =~ ^(ed25519|rsa_pkcs1_sha256)$ ]] || { echo "Invalid --algorithm" >&2; exit 2; }
[[ "$artifact_kind" =~ ^(full_aot_library|binary_diff)$ ]] || { echo "Invalid --artifact-kind" >&2; exit 2; }
[[ -d "$project_dir" ]] || { echo "Project directory does not exist: $project_dir" >&2; exit 1; }
[[ -f "$project_dir/$entrypoint" ]] || { echo "Entrypoint not found: $project_dir/$entrypoint" >&2; exit 1; }
[[ -f "$private_key" ]] || { echo "Private key not found: $private_key" >&2; exit 1; }
if [[ "$artifact_kind" == binary_diff ]]; then
  [[ -f "$base_apk" ]] || { echo "--base-apk is required for binary_diff Dart-only verification" >&2; exit 1; }
elif ! $allow_full_aot_library; then
  echo "full_aot_library is blocked by default; use binary_diff or explicitly pass --allow-full-aot-library for POC use" >&2
  exit 1
fi
case "$target_platform" in
  android-arm64) abi="arm64-v8a" ;;
  android-arm) abi="armeabi-v7a" ;;
  android-x64) abi="x86_64" ;;
  *) echo "Unsupported --target-platform: $target_platform" >&2; exit 2 ;;
esac

output_dir="${output_dir:-$project_dir/build/app_updater_patch}"
mkdir -p "$output_dir"

step() { echo; echo "==> $*"; }

step "Building the release APK"
(cd "$project_dir" && flutter build apk --release --target "$entrypoint" --target-platform "$target_platform")
apk="$project_dir/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$apk" ]] || { echo "Expected APK not found: $apk" >&2; exit 1; }

step "Extracting libapp.so"
"$repo_dir/scripts/extract_artifacts.sh" "$apk" "$abi" "$output_dir"

if [[ "$artifact_kind" == binary_diff ]]; then
  step "Verifying this is a Dart-only patch"
  "$repo_dir/scripts/verify_dart_only_patch.sh" "$base_apk" "$apk" "$abi"
  step "Extracting the shipped base libapp.so"
  mkdir -p "$output_dir/base"
  "$repo_dir/scripts/extract_artifacts.sh" "$base_apk" "$abi" "$output_dir/base"
  base_libapp_so="$output_dir/base/libapp.so"
fi

step "Reading compatibility metadata (engine/Dart version, release)"
version_output="$(cd "$project_dir" && flutter --version --machine)"
engine_revision="$(printf '%s\n' "$version_output" | sed -n 's/.*"engineRevision": "\([^"]*\)".*/\1/p')"
dart_version="$(printf '%s\n' "$version_output" | sed -n 's/.*"dartSdkVersion": "\([^"]*\)".*/\1/p')"
[[ "$engine_revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Could not determine Flutter engine revision" >&2; exit 1; }
[[ -n "$dart_version" ]] || { echo "Could not determine Dart SDK version" >&2; exit 1; }
release="$(sed -n 's/^version:[[:space:]]*//p' "$project_dir/pubspec.yaml" | head -1)"
[[ -n "$release" ]] || { echo "Could not read version from $project_dir/pubspec.yaml" >&2; exit 1; }
build_mode="release"

if [[ "$artifact_kind" == binary_diff ]]; then
  step "Computing a binary diff against the base artifact"
  "$repo_dir/scripts/generate_binary_diff.sh" "$base_libapp_so" "$output_dir/libapp.so" \
    "$output_dir/libapp.so.diff"
  uploaded_artifact="$output_dir/libapp.so.diff"
else
  uploaded_artifact="$output_dir/libapp.so"
fi
artifact_size="$(wc -c < "$uploaded_artifact" | tr -d ' ')"
# manifest.sha256 is always the hash of the final loadable artifact (libapp.so), not the diff
# blob, matching what the device verifies after resolving either artifact kind.
hash="$(awk '{print $1}' "$output_dir/libapp.so.sha256")"

step "Signing the manifest"
payload="$output_dir/patch_payload.txt"
"$repo_dir/scripts/write_manifest_payload.sh" "$payload" 1 "$release" "$patch_number" \
  "$artifact_kind" "$engine_revision" "$dart_version" "$abi" "$build_mode" "$hash" \
  "$key_id" "$algorithm"
case "$algorithm" in
  ed25519)
    signature="$(openssl pkeyutl -sign -rawin -inkey "$private_key" -in "$payload" |
      openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    ;;
  rsa_pkcs1_sha256)
    signature="$(openssl dgst -sha256 -sign "$private_key" -binary "$payload" |
      openssl base64 -A | tr '+/' '-_' | tr -d '=')"
    ;;
esac
rm -f "$payload"

printf '{\n  "schema_version": 1,\n  "release": "%s",\n  "patch_number": %s,\n  "artifact_kind": "%s",\n  "engine_revision": "%s",\n  "dart_version": "%s",\n  "abi": "%s",\n  "build_mode": "%s",\n  "sha256": "%s",\n  "artifact_size": %s,\n  "signature_key_id": "%s",\n  "signature_algorithm": "%s",\n  "signature": "%s"\n}\n' \
  "$release" "$patch_number" "$artifact_kind" "$engine_revision" "$dart_version" "$abi" \
  "$build_mode" "$hash" "$artifact_size" "$key_id" "$algorithm" "$signature" \
  > "$output_dir/patch_manifest.json"

echo
echo "manifest: $output_dir/patch_manifest.json"
echo "artifact: $uploaded_artifact"
echo
echo "Upload with the web portal (/apps/<slug>), or:"
echo "  curl -X POST \"\$BACKEND_URL/admin/apps/<slug>/patches\" -H \"X-Api-Key: <key>\" \\"
echo "    -F \"manifest=@$output_dir/patch_manifest.json;type=application/json\" \\"
echo "    -F \"artifact=@$uploaded_artifact;type=application/octet-stream\""
