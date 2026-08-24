#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
base_dir="$work_dir/base"
dart_dir="$work_dir/dart"
native_dir="$work_dir/native"
mkdir -p "$base_dir/lib/arm64-v8a" "$base_dir/assets/flutter_assets" "$base_dir/META-INF" \
  "$base_dir/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a"

printf 'base dart\n' > "$base_dir/lib/arm64-v8a/libapp.so"
printf 'flutter engine\n' > "$base_dir/lib/arm64-v8a/libflutter.so"
printf 'dex\n' > "$base_dir/classes.dex"
printf 'asset\n' > "$base_dir/assets/flutter_assets/example.txt"
printf 'old signature\n' > "$base_dir/META-INF/CERT.RSA"
printf 'base dart symbols\n' > \
  "$base_dir/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libapp.so.sym"

cp -R "$base_dir" "$dart_dir"
printf 'patched dart\n' > "$dart_dir/lib/arm64-v8a/libapp.so"
printf 'new signature\n' > "$dart_dir/META-INF/CERT.RSA"
printf 'patched dart symbols\n' > \
  "$dart_dir/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libapp.so.sym"

cp -R "$dart_dir" "$native_dir"
printf 'changed dex\n' > "$native_dir/classes.dex"

(cd "$base_dir" && zip -qr "$work_dir/base.apk" .)
(cd "$dart_dir" && zip -qr "$work_dir/dart.apk" .)
(cd "$native_dir" && zip -qr "$work_dir/native.apk" .)

"$repo_dir/scripts/verify_dart_only_patch.sh" \
  "$work_dir/base.apk" "$work_dir/dart.apk" arm64-v8a > /dev/null

if "$repo_dir/scripts/verify_dart_only_patch.sh" \
  "$work_dir/base.apk" "$work_dir/native.apk" arm64-v8a > /dev/null 2>&1; then
  echo "FAIL: native DEX change was accepted as a Dart-only patch" >&2
  exit 1
fi

echo "Dart-only guard accepts libapp/symbol/signature changes and rejects native changes"
