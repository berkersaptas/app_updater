#!/usr/bin/env bash
set -euo pipefail

# Exercises `artifact_kind=binary_diff` (Phase 2E) and the `app_updater` network
# update-client (Phase 2B/2C) end to end on a real device, against the real Dockerized backend.
# Complements scripts/run_device_acceptance.sh, which covers `full_aot_library` through the
# debug/test ContentProvider only. Until this session's real device runs, these two scenarios had
# only been verified manually; see docs/architecture_and_remaining_work.md's Phase 2E/2C sections.
#
# Signs with rsa_pkcs1_sha256, not ed25519: a real Android 10 (API 29) device could not verify
# ed25519 at all during manual testing (see docs/key_management.md) — RSA is the reliable choice
# for a scripted suite that has to work across devices.

trap 'status=$?; echo "FAIL: acceptance command at line $LINENO exited with $status" >&2' ERR

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_name="${PACKAGE_NAME:-com.berkersaptas.app_updater_sample}"
component="$package_name/.MainActivity"
authority="$package_name.ota-installer"
app_slug="${OTA_APP_SLUG:-sample-app-android}"
backend_host_port="${BACKEND_HOST_PORT:-8081}"
admin_api_key="${ADMIN_API_KEY:-dev-admin-key}"
api="http://localhost:$backend_host_port"
skip_build=false
[[ "${1:-}" == "--skip-build" ]] && skip_build=true
[[ $# -le 1 ]] || { echo "Usage: $0 [--skip-build]" >&2; exit 2; }

[[ "$(adb get-state 2>/dev/null || true)" == "device" ]] || {
  echo "FAIL: no authorized Android device is connected" >&2
  exit 1
}

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

logcat_capture_file="$(mktemp)"
sample_config_backup=""
ota_properties_backup=""
ota_properties_existed=false
cleanup() {
  local status=$?
  if [[ -n "$sample_config_backup" && -f "$sample_config_backup" ]]; then
    cp "$sample_config_backup" "$repo_dir/sample_app/app_updater.yaml"
  fi
  if [[ -n "$ota_properties_backup" && -f "$ota_properties_backup" ]]; then
    if $ota_properties_existed; then
      cp "$ota_properties_backup" "$repo_dir/sample_app/android/ota.properties"
    else
      rm -f "$repo_dir/sample_app/android/ota.properties"
    fi
  fi
  rm -f "$logcat_capture_file" "$sample_config_backup" "$ota_properties_backup"
  return "$status"
}
trap cleanup EXIT

# Streams logcat to a file for the duration of the restart instead of clearing the device's ring
# buffer and reading it back afterward with `adb logcat -d`: on a noisy device (lots of unrelated
# system-service spam) the buffer can wrap and lose our events before the post-hoc dump runs, which
# this session hit in practice (a genuine resumed download's log line was missed this way even
# though the resume itself worked correctly, confirmed by manual reproduction with live streaming).
restart_app() {
  adb logcat -c
  : > "$logcat_capture_file"
  adb logcat -v time -s flutter:V OtaPatchLoader:V OtaUpdateClient:V > "$logcat_capture_file" 2>&1 &
  local logcat_pid=$!
  adb shell am force-stop "$package_name"
  adb shell am start -W -n "$component" > /dev/null
  sleep 6
  kill "$logcat_pid" 2>/dev/null || true
  wait "$logcat_pid" 2>/dev/null || true
  # The killed process's redirected stdout can be block-buffered, dropping the last unflushed
  # chunk (this session hit it: a real "Patch disabled" line was emitted device-side but lost on
  # kill). The device's own log buffer is unaffected by killing our client-side reader, so a
  # supplemental -d dump backfills anything the live stream missed; duplicate lines are harmless
  # since callers only grep for a substring.
  adb logcat -d -s flutter:V OtaPatchLoader:V OtaUpdateClient:V >> "$logcat_capture_file" 2>&1 || true
}

assert_ui() {
  local expected="$1"
  local xml
  adb shell uiautomator dump /sdcard/ota-acceptance-window.xml > /dev/null
  xml="$(adb shell cat /sdcard/ota-acceptance-window.xml)"
  [[ "$xml" == *"content-desc=\"$expected\""* ]] || fail "Expected UI text: $expected"
}

logcat_since_restart() {
  cat "$logcat_capture_file"
}

step "Reset the backend to a known-empty state"
(cd "$repo_dir" && docker compose down -v) > /dev/null 2>&1 || true
(cd "$repo_dir" && ADMIN_API_KEY="$admin_api_key" BACKEND_HOST_PORT="$backend_host_port" \
  docker compose up -d --build) > /dev/null
for i in $(seq 1 30); do
  curl -sf "$api/healthz" > /dev/null 2>&1 && break
  [[ "$i" -eq 30 ]] && fail "Backend did not become healthy at $api"
  sleep 1
done

step "Forward the device's localhost:8080 to the backend"
adb reverse tcp:8080 "tcp:$backend_host_port" > /dev/null

step "Register the app and its dev signing keys on the backend"
curl -sf -X POST "$api/admin/apps" -H "X-Api-Key: $admin_api_key" -H "Content-Type: application/json" \
  -d "{\"slug\":\"$app_slug\",\"platform\":\"android\",\"package_name\":\"$package_name\"}" > /dev/null

register_key() {
  local key_id="$1" der="$2" algorithm="$3"
  local pub
  pub="$(openssl base64 -A -in "$der" | tr '+/' '-_' | tr -d '=')"
  curl -sf -X POST "$api/admin/apps/$app_slug/keys" -H "X-Api-Key: $admin_api_key" \
    -H "Content-Type: application/json" \
    -d "{\"key_id\":\"$key_id\",\"public_key_der_base64url\":\"$pub\",\"algorithm\":\"$algorithm\"}" > /dev/null
}

if ! $skip_build; then
  step "Generate dev signing keys (ed25519 + rsa) and build a fresh base APK"
  sample_config_backup="$(mktemp)"
  cp "$repo_dir/sample_app/app_updater.yaml" "$sample_config_backup"
  ota_properties_backup="$(mktemp)"
  if [[ -f "$repo_dir/sample_app/android/ota.properties" ]]; then
    ota_properties_existed=true
    cp "$repo_dir/sample_app/android/ota.properties" "$ota_properties_backup"
  fi
  OTA_SIGNATURE_ALGORITHM=ed25519 OTA_SIGNATURE_ACTIVE_KEY_ID=dev-ed25519-v1 \
    "$repo_dir/scripts/generate_dev_signing_key.sh"
  OTA_SIGNATURE_ALGORITHM=rsa_pkcs1_sha256 OTA_SIGNATURE_ACTIVE_KEY_ID=dev-rsa-v1 \
    "$repo_dir/scripts/generate_dev_signing_key.sh"
  node "$repo_dir/scripts/sync_sample_app_dev_keyring.mjs"
  "$repo_dir/scripts/build_base.sh"
  cp "$sample_config_backup" "$repo_dir/sample_app/app_updater.yaml"
  if $ota_properties_existed; then
    cp "$ota_properties_backup" "$repo_dir/sample_app/android/ota.properties"
  else
    rm -f "$repo_dir/sample_app/android/ota.properties"
  fi
  rm -f "$sample_config_backup" "$ota_properties_backup"
  sample_config_backup=""
  ota_properties_backup=""
fi
[[ -f "$repo_dir/patch_artifacts/base/base.apk" ]] || fail "Missing base.apk; run without --skip-build"
[[ -f "$repo_dir/patch_artifacts/base/libapp.so" ]] || fail "Missing base libapp.so; run without --skip-build"

register_key dev-ed25519-v1 "$repo_dir/keys/dev-ed25519-v1_public.der" ed25519
register_key dev-rsa-v1 "$repo_dir/keys/dev-rsa-v1_public.der" rsa_pkcs1_sha256

step "Install a clean base APK"
adb uninstall "$package_name" > /dev/null 2>&1 || true
adb install "$repo_dir/patch_artifacts/base/base.apk" > /dev/null

step "Build an RSA-signed binary_diff patch against this exact base and upload it"
patch_name="acceptance-$(date +%s)"
OTA_SIGNATURE_ALGORITHM=rsa_pkcs1_sha256 OTA_SIGNATURE_ACTIVE_KEY_ID=dev-rsa-v1 \
  OTA_ARTIFACT_KIND=binary_diff \
  "$repo_dir/scripts/build_patch.sh" lib/main_patched.dart "$patch_name" 1
curl -sf -X POST "$api/admin/apps/$app_slug/patches" -H "X-Api-Key: $admin_api_key" \
  -F "manifest=@$repo_dir/patch_artifacts/$patch_name/patch_manifest.json;type=application/json" \
  -F "artifact=@$repo_dir/patch_artifacts/$patch_name/libapp.so.diff;type=application/octet-stream" \
  > /dev/null

step "Reject a different exact build and safely decline a legacy OTA client"
manifest="$repo_dir/patch_artifacts/$patch_name/patch_manifest.json"
manifest_string() {
  sed -n "s/.*\"$1\": \"\([^\"]*\)\".*/\1/p" "$manifest" | head -1
}
release="$(manifest_string release)"
engine_revision="$(manifest_string engine_revision)"
dart_version="$(manifest_string dart_version)"
abi="$(manifest_string abi)"
build_mode="$(manifest_string build_mode)"
base_sha256="$(manifest_string base_sha256)"
different_base_sha256="0000000000000000000000000000000000000000000000000000000000000000"
different_fingerprint="$(
  "$repo_dir/scripts/compute_build_fingerprint.sh" 2 "$release" "$engine_revision" \
    "$dart_version" "$abi" "$build_mode" "$different_base_sha256"
)"
incompatible_response="$(curl -sf -X POST "$api/v1/apps/$app_slug/patch-check" \
  -H 'Content-Type: application/json' \
  -d "{\"channel\":\"stable\",\"release_version\":\"$release\",\"current_patch_number\":0,\"platform\":\"android\",\"arch\":\"$abi\",\"ota_protocol_version\":2,\"engine_revision\":\"$engine_revision\",\"dart_version\":\"$dart_version\",\"build_mode\":\"$build_mode\",\"base_sha256\":\"$different_base_sha256\",\"build_fingerprint\":\"$different_fingerprint\"}")"
[[ "$incompatible_response" == *'"patch_available":false'* ]] \
  || fail "A different exact build unexpectedly received the patch: $incompatible_response"
legacy_response="$(curl -sf -X POST "$api/v1/apps/$app_slug/patch-check" \
  -H 'Content-Type: application/json' \
  -d "{\"channel\":\"stable\",\"release_version\":\"$release\",\"current_patch_number\":0,\"platform\":\"android\",\"arch\":\"$abi\"}")"
[[ "$legacy_response" == *'"patch_available":false'* && "$legacy_response" == *'"client_upgrade_required":true'* ]] \
  || fail "Legacy client was not safely declined: $legacy_response"

step "Launch 1: app_updater finds, verifies, and stages the patch without activating it"
restart_app
assert_ui "Hello v1"
logcat_since_restart | grep -q "OtaUpdateInstalled(patchNumber: 1)" \
  || fail "Expected app_updater to report OtaUpdateInstalled(patchNumber: 1)"

step "Launch 2: the staged patch activates like any locally-installed patch"
restart_app
assert_ui "Hello v2"
logcat_since_restart | grep -q "Verified binary_diff patch 1; attempting patched boot" \
  || fail "Expected PatchLoader to verify and attempt the binary_diff patch"
logcat_since_restart | grep -q "Patch 1 is active" || fail "Expected patch 1 to become active"

step "Launch 3: steady state reports no update available"
restart_app
assert_ui "Hello v2"
logcat_since_restart | grep -q "OtaNoUpdateAvailable" \
  || fail "Expected steady-state no-update-available"

step "Build and upload a second patch, then plant a truncated .tmp to test download resume"
patch_name_2="$patch_name-2"
OTA_SIGNATURE_ALGORITHM=rsa_pkcs1_sha256 OTA_SIGNATURE_ACTIVE_KEY_ID=dev-rsa-v1 \
  OTA_ARTIFACT_KIND=binary_diff \
  "$repo_dir/scripts/build_patch.sh" lib/main_patched.dart "$patch_name_2" 2
curl -sf -X POST "$api/admin/apps/$app_slug/patches" -H "X-Api-Key: $admin_api_key" \
  -F "manifest=@$repo_dir/patch_artifacts/$patch_name_2/patch_manifest.json;type=application/json" \
  -F "artifact=@$repo_dir/patch_artifacts/$patch_name_2/libapp.so.diff;type=application/octet-stream" \
  > /dev/null
# Plant a truncated prefix of the real diff at the exact `.tmp` staging path OtaUpdateClient uses
# (via the debug provider's .tmp write support), simulating an interrupted prior download. If
# resume works, the client issues a Range request for the remaining bytes instead of restarting,
# and the patch still verifies correctly end to end (the resumed bytes are a real prefix of the
# real artifact, so the final SHA-256 check downstream is the true correctness signal here).
diff_artifact="$repo_dir/patch_artifacts/$patch_name_2/libapp.so.diff"
full_size="$(wc -c < "$diff_artifact" | tr -d ' ')"
truncated_size="$((full_size / 2))"
truncated="$(mktemp)"
head -c "$truncated_size" "$diff_artifact" > "$truncated"
adb shell content write --uri "content://$authority/patches/2/libapp.so.diff.tmp" < "$truncated"
rm -f "$truncated"

step "Launch 4: the resumed download completes via a Range request and the patch stages"
restart_app
assert_ui "Hello v2"
logcat_since_restart | grep -q "Resuming download of .* from byte $truncated_size" \
  || fail "Expected OtaUpdateClient to resume the planted .tmp from byte $truncated_size"
logcat_since_restart | grep -q "OtaUpdateInstalled(patchNumber: 2)" \
  || fail "Expected the resumed download to stage successfully"

step "Launch 5: the resumed patch activates correctly, confirming the resumed bytes are correct"
restart_app
assert_ui "Hello v2"
logcat_since_restart | grep -q "Patch 2 is active" \
  || fail "Expected the resumed patch 2 to become active"

step "Build and upload a third patch, then corrupt it in storage (simulating bit-rot/corruption)"
patch_name_3="$patch_name-3"
OTA_SIGNATURE_ALGORITHM=rsa_pkcs1_sha256 OTA_SIGNATURE_ACTIVE_KEY_ID=dev-rsa-v1 \
  OTA_ARTIFACT_KIND=binary_diff \
  "$repo_dir/scripts/build_patch.sh" lib/main_patched.dart "$patch_name_3" 3
curl -sf -X POST "$api/admin/apps/$app_slug/patches" -H "X-Api-Key: $admin_api_key" \
  -F "manifest=@$repo_dir/patch_artifacts/$patch_name_3/patch_manifest.json;type=application/json" \
  -F "artifact=@$repo_dir/patch_artifacts/$patch_name_3/libapp.so.diff;type=application/octet-stream" \
  > /dev/null
# Flip 8 bytes inside the stored artifact directly, bypassing the API — this is deliberately a
# storage-corruption scenario, not a re-upload (patch_number is part of the signed payload, so a
# tampered re-upload would just fail signature verification, testing something else already
# covered by scripts/run_device_acceptance.sh).
docker compose -f "$repo_dir/docker-compose.yml" exec -T backend \
  sh -c "printf '\xff\xff\xff\xff\xff\xff\xff\xff' | dd of=/data/artifacts/$app_slug/3/libapp.so.diff bs=1 seek=20 conv=notrunc" \
  > /dev/null 2>&1

step "Launch 6: the corrupted patch downloads and stages fine (bad bytes aren't detected until reconstruction)"
restart_app
assert_ui "Hello v2"
logcat_since_restart | grep -q "OtaUpdateInstalled(patchNumber: 3)" \
  || fail "Expected the corrupted patch to stage successfully (corruption isn't caught until resolve)"

step "Launch 7: reconstruction fails, the corrupted patch is rejected, and the app falls back to base"
restart_app
assert_ui "Hello v1"
logcat_since_restart | grep -q "OtaPatchLoader: Patch 3 disabled" \
  || fail "Expected the corrupted patch to be rejected on resolve, not silently accepted"

step "Verify events reached the backend"
events="$(docker compose -f "$repo_dir/docker-compose.yml" exec -T postgres \
  psql -U ota -d ota -t -c "select count(*) from patch_events where event_type = 'PatchInstallSuccess';")"
[[ "${events// /}" -ge 1 ]] || fail "Expected at least one PatchInstallSuccess event in Postgres"

step "Disable the corrupted patch and restore the good one, leaving the device on Hello v2 / active"
curl -sf -X PATCH "$api/admin/apps/$app_slug/patches/3" -H "X-Api-Key: $admin_api_key" \
  -H "Content-Type: application/json" -d '{"enabled":false}' > /dev/null
restart_app
restart_app
assert_ui "Hello v2"

echo
echo "PASS: binary_diff + network update-client acceptance scenarios succeeded"
