#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <base-apk> <patch-apk> <arm64-v8a|armeabi-v7a|x86_64>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
base_apk="$1"
patch_apk="$2"
abi="$3"

case "$abi" in
  arm64-v8a|armeabi-v7a|x86_64) ;;
  *) usage ;;
esac

[[ -f "$base_apk" ]] || { echo "Base APK not found: $base_apk" >&2; exit 1; }
[[ -f "$patch_apk" ]] || { echo "Patch APK not found: $patch_apk" >&2; exit 1; }

entry="lib/$abi/libapp.so"
unzip -Z1 "$base_apk" | grep -Fx "$entry" > /dev/null || entry="base/lib/$abi/libapp.so"
for apk in "$base_apk" "$patch_apk"; do
  unzip -Z1 "$apk" | grep -Fx "$entry" > /dev/null || {
    echo "$entry is not present in $apk" >&2
    echo "Use a base APK built for the same single target ABI as the patch." >&2
    exit 1
  }
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
base_dir="$work_dir/base"
patch_dir="$work_dir/patch"
mkdir -p "$base_dir" "$patch_dir"
unzip -qq "$base_apk" -d "$base_dir"
unzip -qq "$patch_apk" -d "$patch_dir"

# APK signing files are expected to differ after a rebuild. libapp.so is the one executable payload
# that a Dart-only patch is allowed to change; every manifest, DEX, resource, asset, Flutter engine,
# plugin/native library, and other packaging entry must remain byte-identical to the shipped APK.
for extracted_dir in "$base_dir" "$patch_dir"; do
  if [[ -d "$extracted_dir/META-INF" ]]; then
    find "$extracted_dir/META-INF" -type f \
      \( -name 'MANIFEST.MF' -o -name '*.SF' -o -name '*.RSA' -o -name '*.DSA' -o -name '*.EC' \) \
      -delete
  fi
done
rm -f "$base_dir/$entry" "$patch_dir/$entry"
# App Bundles also carry the symbol generated from Dart's libapp.so. It changes together with
# libapp.so and is BUNDLE-METADATA, not executable content installed on the device.
symbol_entry="BUNDLE-METADATA/com.android.tools.build.debugsymbols/$abi/libapp.so.sym"
rm -f "$base_dir/$symbol_entry" "$patch_dir/$symbol_entry"

differences="$work_dir/differences.txt"
if ! diff -qr "$base_dir" "$patch_dir" > "$differences"; then
  echo "Patch is not Dart-only. APK content outside $entry changed:" >&2
  sed -n '1,80p' "$differences" >&2
  echo "Publish these native/asset/resource changes through a new Play Store release." >&2
  exit 1
fi

echo "Dart-only APK guard passed: only $entry (and APK signatures) changed"
