#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/sample_app"
artifact_dir="$repo_dir/patch_artifacts/base"
target_platform="${TARGET_PLATFORM:-android-arm64}"

case "$target_platform" in
  android-arm64) abi="arm64-v8a" ;;
  android-arm) abi="armeabi-v7a" ;;
  android-x64) abi="x86_64" ;;
  *) echo "Unsupported TARGET_PLATFORM: $target_platform" >&2; exit 2 ;;
esac

mkdir -p "$artifact_dir"
"$repo_dir/scripts/generate_dev_signing_key.sh"
"$repo_dir/scripts/generate_compatibility_metadata.sh"
cd "$app_dir"
flutter clean
flutter build apk --release --target lib/main_base.dart --target-platform "$target_platform"
cp build/app/outputs/flutter-apk/app-release.apk "$artifact_dir/base.apk"
"$repo_dir/scripts/extract_artifacts.sh" "$artifact_dir/base.apk" "$abi" "$artifact_dir"
