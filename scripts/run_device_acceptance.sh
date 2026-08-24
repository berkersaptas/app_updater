#!/usr/bin/env bash
set -euo pipefail

trap 'status=$?; echo "FAIL: acceptance command at line $LINENO exited with $status" >&2' ERR

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_name="${PACKAGE_NAME:-com.berkersaptas.app_updater_sample}"
authority="$package_name.ota-installer"
component="$package_name/.MainActivity"
# ed25519 signature verification is not available on all real devices (confirmed failing on
# Android 10/API 29 — a platform JCA gap, not a bug here; see docs/key_management.md). Default this
# suite to rsa_pkcs1_sha256 so it works across devices; sample_app/app_updater.yaml already
# trusts both dev keys. Override with OTA_SIGNATURE_ALGORITHM=ed25519 to test that path instead.
export OTA_SIGNATURE_ALGORITHM="${OTA_SIGNATURE_ALGORITHM:-rsa_pkcs1_sha256}"
export OTA_SIGNATURE_ACTIVE_KEY_ID="${OTA_SIGNATURE_ACTIVE_KEY_ID:-dev-rsa-v1}"
skip_build=false
[[ "${1:-}" == "--skip-build" ]] && skip_build=true
[[ $# -le 1 ]] || { echo "Usage: $0 [--skip-build]" >&2; exit 2; }

# This suite tests the offline/debug ContentProvider path only. sample_app's app_updater.yaml
# points OtaUpdateClient at http://localhost:8080 unconditionally (AppUpdater.autoUpdate() runs
# on every launch — see lib/app.dart), so if scripts/run_binary_diff_acceptance.sh's backend is
# still up and `adb reverse tcp:8080` still mapped from an earlier run, the network update-client
# races in on every restart here and reinstalls whatever patch that backend is serving — a real,
# confusing cross-contamination this session traced back to exactly that interaction (not an OEM
# storage/backup quirk, as it first appeared). Sever the mapping so network calls fail harmlessly
# (by design — see docs/production_installer_contract.md's "must tolerate backend/CDN
# unavailability") instead of pulling in patches from an unrelated test run.
adb reverse --remove tcp:8080 > /dev/null 2>&1 || true

[[ "$(adb get-state 2>/dev/null || true)" == "device" ]] || {
  echo "FAIL: no authorized Android device is connected" >&2
  exit 1
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

json_string() {
  sed -n "s/.*\"$2\": \"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

load_manifest() {
  local manifest="$1"
  release="$(json_string "$manifest" release)"
  engine_revision="$(json_string "$manifest" engine_revision)"
  dart_version="$(json_string "$manifest" dart_version)"
  abi="$(json_string "$manifest" abi)"
  build_mode="$(json_string "$manifest" build_mode)"
  expected_hash="$(json_string "$manifest" sha256)"
  signature_key_id="$(json_string "$manifest" signature_key_id)"
  signature_algorithm="$(json_string "$manifest" signature_algorithm)"
  artifact_kind="$(json_string "$manifest" artifact_kind)"
  signature="$(json_string "$manifest" signature)"
  patch_number="$(sed -n 's/.*"patch_number": \([0-9][0-9]*\).*/\1/p' "$manifest" | head -1)"
}

sign_fields() {
  local release_value="$1"
  local patch_number_value="$2"
  local hash_value="$3"
  local engine_value="$4"
  local dart_value="$5"
  local abi_value="$6"
  local build_mode_value="$7"
  local payload
  local signing_key="$repo_dir/keys/${signature_key_id}_private.pem"
  [[ -f "$signing_key" ]] || fail "Missing signing key for acceptance: $signing_key"
  payload="$(mktemp)"
  "$repo_dir/scripts/write_manifest_payload.sh" "$payload" 1 "$release_value" \
    "$patch_number_value" "$artifact_kind" "$engine_value" "$dart_value" "$abi_value" \
    "$build_mode_value" "$hash_value" "$signature_key_id" "$signature_algorithm"
  case "$signature_algorithm" in
    ed25519)
      openssl pkeyutl -sign -rawin -inkey "$signing_key" -in "$payload"
      ;;
    rsa_pkcs1_sha256)
      openssl dgst -sha256 -sign "$signing_key" -binary "$payload"
      ;;
    *)
      fail "Unsupported signature algorithm for acceptance: $signature_algorithm"
      ;;
  esac |
    openssl base64 -A |
    tr '+/' '-_' |
    tr -d '='
  rm -f "$payload"
}

activate() {
  local arg_signature
  arg_signature="$(sign_fields "$1" "$2" "$3" "$4" "$5" "$6" "$7")"
  adb shell content call \
    --uri "content://$authority" \
    --method activate \
    --arg "$1~$2~$artifact_kind~$3~$4~$5~$6~$7~$signature_key_id~$signature_algorithm~$arg_signature" > /dev/null
}

restart_app() {
  adb shell am force-stop "$package_name"
  adb shell am start -W -n "$component" > /dev/null
}

read_state() {
  adb shell content read --uri "content://$authority/state"
}

assert_state() {
  local expected="$1"
  local reason="${2:-}"
  local state
  state="$(read_state)"
  [[ "$state" == *"\"state\": \"$expected\""* ]] || {
    echo "$state" >&2
    fail "Expected state=$expected"
  }
  if [[ -n "$reason" && "$state" != *"$reason"* ]]; then
    echo "$state" >&2
    fail "Expected failure reason containing: $reason"
  fi
}

assert_ui() {
  local expected="$1"
  local xml
  adb shell uiautomator dump /sdcard/ota-acceptance-window.xml > /dev/null
  xml="$(adb shell cat /sdcard/ota-acceptance-window.xml)"
  [[ "$xml" == *"content-desc=\"$expected\""* ]] || fail "Expected UI text: $expected"
}

install_good_patch() {
  "$repo_dir/scripts/install_patch_artifact.sh" "$repo_dir/patch_artifacts/patched/libapp.so" \
    "$package_name" "$repo_dir/patch_artifacts/patched/patch_manifest.json" > /dev/null
  load_manifest "$repo_dir/patch_artifacts/patched/patch_manifest.json"
}

if ! $skip_build; then
  step "Build base, confirmed patch, and unconfirmed patch"
  "$repo_dir/scripts/build_base.sh"
  "$repo_dir/scripts/build_patched.sh"
  "$repo_dir/scripts/build_unconfirmed.sh"
fi

for required in \
  patch_artifacts/base/base.apk \
  patch_artifacts/patched/libapp.so \
  patch_artifacts/patched/patch_manifest.json \
  patch_artifacts/unconfirmed/libapp.so \
  patch_artifacts/unconfirmed/patch_manifest.json; do
  [[ -f "$repo_dir/$required" ]] || fail "Missing $required; run without --skip-build"
done

step "Install a clean base APK and verify Hello v1"
# Full uninstall+install (not `install -r`, which preserves app data), plus an explicit reset via
# the debug provider with verification that it actually took effect — belt and suspenders, now that
# the real contamination source above (network update-client reaching a live backend) is severed.
adb uninstall "$package_name" > /dev/null 2>&1 || true
adb install "$repo_dir/patch_artifacts/base/base.apk" > /dev/null
restart_app
adb shell content call --uri "content://$authority" --method reset > /dev/null
restart_app
state_after_reset="$(read_state 2>/dev/null || true)"
[[ "$state_after_reset" != *"\"patch_number\""* ]] || {
  echo "$state_after_reset" >&2
  fail "Expected no patch state after reset, but found leftover patch state (see above)"
}
assert_ui "Hello v1"

step "Install a compatible patch and verify Hello v2 / active"
install_good_patch
restart_app
assert_ui "Hello v2"
assert_state active

step "Reject an unsigned or tampered manifest before activation"
adb shell content call \
  --uri "content://$authority" \
  --method activate \
  --arg "$release~$patch_number~$artifact_kind~$expected_hash~$engine_revision~$dart_version~$abi~$build_mode~$signature_key_id~$signature_algorithm~invalid" > /dev/null 2>&1 || true
restart_app
assert_ui "Hello v2"
assert_state active
[[ "$(read_state)" != *"\"signature\": \"invalid\""* ]] || \
  fail "Tampered signature was written to patch state"

step "Reject a SHA-256 mismatch"
activate "$release" "$patch_number" \
  0000000000000000000000000000000000000000000000000000000000000000 \
  "$engine_revision" "$dart_version" "$abi" "$build_mode"
restart_app
assert_ui "Hello v1"
assert_state failed "SHA-256 mismatch"

step "Reject a Flutter engine mismatch"
install_good_patch
activate "$release" "$patch_number" "$expected_hash" \
  0000000000000000000000000000000000000000 "$dart_version" "$abi" "$build_mode"
restart_app
assert_ui "Hello v1"
assert_state failed "Flutter engine mismatch"

step "Reject a Dart SDK mismatch"
install_good_patch
activate "$release" "$patch_number" "$expected_hash" \
  "$engine_revision" 0.0.0 "$abi" "$build_mode"
restart_app
assert_ui "Hello v1"
assert_state failed "Dart version mismatch"

step "Reject a base release mismatch"
install_good_patch
activate 0.0.0+0 "$patch_number" "$expected_hash" \
  "$engine_revision" "$dart_version" "$abi" "$build_mode"
restart_app
assert_ui "Hello v1"
assert_state failed "Base release mismatch"

step "Reject an ABI mismatch"
install_good_patch
activate "$release" "$patch_number" "$expected_hash" \
  "$engine_revision" "$dart_version" x86_64 "$build_mode"
restart_app
assert_ui "Hello v1"
assert_state failed "ABI mismatch"

step "Reject a build-mode mismatch"
install_good_patch
activate "$release" "$patch_number" "$expected_hash" \
  "$engine_revision" "$dart_version" "$abi" debug
restart_app
assert_ui "Hello v1"
assert_state failed "Build mode mismatch"

step "Reject a missing artifact"
install_good_patch
adb shell content delete \
  --uri "content://$authority/patches/$patch_number/libapp.so" > /dev/null
restart_app
assert_ui "Hello v1"
assert_state failed "Artifact does not exist"

step "Rollback a patch that never reports boot success"
"$repo_dir/scripts/install_patch_artifact.sh" \
  "$repo_dir/patch_artifacts/unconfirmed/libapp.so" \
  "$package_name" "$repo_dir/patch_artifacts/unconfirmed/patch_manifest.json" > /dev/null
restart_app
assert_ui "Hello unconfirmed"
assert_state pending_boot
restart_app
assert_ui "Hello v1"
assert_state failed "Previous patched boot did not report success"

step "Reject a patch number that was marked bad"
"$repo_dir/scripts/install_patch_artifact.sh" \
  "$repo_dir/patch_artifacts/unconfirmed/libapp.so" \
  "$package_name" "$repo_dir/patch_artifacts/unconfirmed/patch_manifest.json" > /dev/null
restart_app
assert_ui "Hello v1"
assert_state failed "Patch number was marked bad"

step "Restore the compatible patch and leave the device on Hello v2 / active"
install_good_patch
restart_app
assert_ui "Hello v2"
assert_state active

lifecycle_status="$(adb shell content call \
  --uri "content://$authority" --method lifecycleStatus)"
[[ "$lifecycle_status" == *"last_known_good=true"* ]] || \
  fail "Expected last-known-good metadata after final activation"
[[ "$lifecycle_status" == *"quarantine_count=5"* ]] || \
  fail "Expected quarantine retention to be capped at five entries"

echo
echo "PASS: all Android OTA phase-1 acceptance scenarios succeeded"
