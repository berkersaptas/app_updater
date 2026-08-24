#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <dart-entrypoint> <artifact-name> <patch-number>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
entrypoint="$1"
artifact_name="$2"
patch_number="$3"
[[ "$artifact_name" =~ ^[a-z0-9_-]+$ ]] || { echo "Invalid artifact name" >&2; exit 2; }
[[ "$patch_number" =~ ^[0-9]+$ ]] || { echo "Invalid patch number" >&2; exit 2; }

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/sample_app"
artifact_dir="$repo_dir/patch_artifacts/$artifact_name"
target_platform="${TARGET_PLATFORM:-android-arm64}"

case "$target_platform" in
  android-arm64) abi="arm64-v8a" ;;
  android-arm) abi="armeabi-v7a" ;;
  android-x64) abi="x86_64" ;;
  *) echo "Unsupported TARGET_PLATFORM: $target_platform" >&2; exit 2 ;;
esac

[[ -f "$app_dir/$entrypoint" ]] || { echo "Entrypoint not found: $entrypoint" >&2; exit 1; }
mkdir -p "$artifact_dir"
"$repo_dir/scripts/generate_dev_signing_key.sh"
"$repo_dir/scripts/generate_compatibility_metadata.sh"
cd "$app_dir"
flutter clean
flutter build apk --release --target "$entrypoint" --target-platform "$target_platform"
cp build/app/outputs/flutter-apk/app-release.apk "$artifact_dir/$artifact_name.apk"
"$repo_dir/scripts/extract_artifacts.sh" "$artifact_dir/$artifact_name.apk" "$abi" "$artifact_dir"

engine_revision="$(sed -n 's/^engineRevision=//p' android/ota.properties)"
dart_version="$(sed -n 's/^dartVersion=//p' android/ota.properties)"
build_mode="$(sed -n 's/^buildMode=//p' android/ota.properties)"
signature_key_id="$(sed -n 's/^signatureActiveKeyId=//p' android/ota.properties)"
signature_algorithm="${OTA_SIGNATURE_ALGORITHM:-ed25519}"
artifact_kind="${OTA_ARTIFACT_KIND:-full_aot_library}"
signing_key_path="${OTA_SIGNING_KEY_PATH:-$repo_dir/keys/${signature_key_id}_private.pem}"
release="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
hash="$(awk '{print $1}' "$artifact_dir/libapp.so.sha256")"
[[ "$artifact_kind" =~ ^(full_aot_library|binary_diff)$ ]] || {
  echo "Invalid OTA_ARTIFACT_KIND: $artifact_kind" >&2
  exit 2
}
if [[ "$artifact_kind" == binary_diff ]]; then
  base_artifact="$repo_dir/patch_artifacts/base/libapp.so"
  [[ -f "$base_artifact" ]] || {
    echo "Missing base artifact for binary_diff: $base_artifact" >&2
    echo "Run scripts/build_base.sh first" >&2
    exit 1
  }
  "$repo_dir/scripts/generate_binary_diff.sh" "$base_artifact" "$artifact_dir/libapp.so" \
    "$artifact_dir/libapp.so.diff"
fi
uploaded_artifact="$artifact_dir/libapp.so"
[[ "$artifact_kind" == binary_diff ]] && uploaded_artifact="$artifact_dir/libapp.so.diff"
artifact_size="$(wc -c < "$uploaded_artifact" | tr -d ' ')"
[[ "$signature_algorithm" =~ ^(ed25519|rsa_pkcs1_sha256)$ ]] || {
  echo "Invalid OTA_SIGNATURE_ALGORITHM: $signature_algorithm" >&2
  exit 2
}
payload="$artifact_dir/patch_payload.txt"
"$repo_dir/scripts/write_manifest_payload.sh" "$payload" 1 "$release" "$patch_number" \
  "$artifact_kind" "$engine_revision" "$dart_version" "$abi" "$build_mode" "$hash" \
  "$signature_key_id" "$signature_algorithm"
if [[ -n "${OTA_SIGN_CMD:-}" ]]; then
  signature="$(
    sh -c "$OTA_SIGN_CMD" < "$payload" |
      tr '+/' '-_' |
      tr -d '=\n'
  )"
else
  [[ -f "$signing_key_path" ]] || {
    echo "Missing OTA signing private key: $signing_key_path" >&2
    exit 1
  }
  case "$signature_algorithm" in
    ed25519)
      signature="$(
        openssl pkeyutl -sign -rawin -inkey "$signing_key_path" -in "$payload" |
          openssl base64 -A |
          tr '+/' '-_' |
          tr -d '='
      )"
      ;;
    rsa_pkcs1_sha256)
      signature="$(
        openssl dgst -sha256 -sign "$signing_key_path" -binary "$payload" |
          openssl base64 -A |
          tr '+/' '-_' |
          tr -d '='
      )"
      ;;
  esac
fi
[[ "$signature" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "Signing command produced an invalid base64url signature" >&2
  exit 1
}
rm -f "$payload"
printf '{\n  "schema_version": 1,\n  "release": "%s",\n  "patch_number": %s,\n  "artifact_kind": "%s",\n  "engine_revision": "%s",\n  "dart_version": "%s",\n  "abi": "%s",\n  "build_mode": "%s",\n  "sha256": "%s",\n  "artifact_size": %s,\n  "signature_key_id": "%s",\n  "signature_algorithm": "%s",\n  "signature": "%s"\n}\n' \
  "$release" "$patch_number" "$artifact_kind" "$engine_revision" "$dart_version" "$abi" \
  "$build_mode" "$hash" "$artifact_size" "$signature_key_id" "$signature_algorithm" "$signature" \
  > "$artifact_dir/patch_manifest.json"
echo "manifest: $artifact_dir/patch_manifest.json"
