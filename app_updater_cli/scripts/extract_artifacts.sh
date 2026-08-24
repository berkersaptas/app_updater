#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <apk-or-aab> <arm64-v8a|armeabi-v7a|x86_64> <output-dir>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
apk="$1"
abi="$2"
output_dir="$3"

case "$abi" in
  arm64-v8a|armeabi-v7a|x86_64) ;;
  *) usage ;;
esac

[[ -f "$apk" ]] || { echo "APK not found: $apk" >&2; exit 1; }
entry="lib/$abi/libapp.so"
unzip -Z1 "$apk" | grep -Fx "$entry" > /dev/null || entry="base/lib/$abi/libapp.so"
unzip -Z1 "$apk" | grep -Fx "$entry" > /dev/null || {
  echo "$entry is not present in $apk" >&2
  echo "Available native libraries:" >&2
  unzip -Z1 "$apk" | grep -E '^(base/)?lib/' >&2 || true
  exit 1
}

mkdir -p "$output_dir"
unzip -p "$apk" "$entry" > "$output_dir/libapp.so"
hash="$(shasum -a 256 "$output_dir/libapp.so" | awk '{print $1}')"
printf '%s  %s\n' "$hash" "libapp.so" > "$output_dir/libapp.so.sha256"
echo "$entry -> $output_dir/libapp.so"
echo "sha256: $hash"
