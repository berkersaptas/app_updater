#!/usr/bin/env bash
set -euo pipefail

# One-command onboarding for a new Flutter app: registers the app on the backend, generates a
# fresh signing key pair, registers the public key, and writes app_updater.yaml into the
# target Flutter project. This is the "basic developer level" setup path — no manual base64
# encoding, no hand-written trusted_keys entries.
#
# Usage:
#   scripts/app_updater_init.sh \
#     --app-slug muhasebe-app-android \
#     --package-name com.sirket.muhasebe \
#     --backend-url https://ota.sirket.com \
#     --api-key <operator-or-root-api-key> \
#     --project-dir /path/to/flutter/project \
#     [--key-dir /path/to/store/the/private/key] \
#     [--platform android]

usage() {
  cat >&2 <<'EOF'
Usage: scripts/app_updater_init.sh --app-slug <slug> --package-name <pkg> --backend-url <url> \
  --api-key <key> --project-dir <path> [--key-dir <path>] [--platform android]
EOF
  exit 2
}

app_slug=""
package_name=""
backend_url=""
api_key=""
project_dir=""
key_dir=""
platform="android"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-slug) app_slug="$2"; shift 2 ;;
    --package-name) package_name="$2"; shift 2 ;;
    --backend-url) backend_url="$2"; shift 2 ;;
    --api-key) api_key="$2"; shift 2 ;;
    --project-dir) project_dir="$2"; shift 2 ;;
    --key-dir) key_dir="$2"; shift 2 ;;
    --platform) platform="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$app_slug" && -n "$package_name" && -n "$backend_url" && -n "$api_key" && -n "$project_dir" ]] || usage
[[ "$app_slug" =~ ^[a-z0-9-]+$ ]] || { echo "app-slug must be lowercase alphanumeric/hyphens" >&2; exit 2; }
[[ "$platform" == "android" ]] || { echo "Only --platform android is supported (iOS is out of scope; see docs/ios_runtime_decision.md)" >&2; exit 2; }
[[ -d "$project_dir" ]] || { echo "Project directory does not exist: $project_dir" >&2; exit 1; }

key_dir="${key_dir:-$HOME/.app_updater/keys/$app_slug}"
key_id="prod-rsa-$(date +%Y%m%d)"
private_key="$key_dir/${key_id}_private.pem"
public_key_der="$key_dir/${key_id}_public.der"

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

step "Register the app on the backend (skipped if it already exists)"
register_status="$(curl -s -o /tmp/app_updater_init_register.json -w '%{http_code}' \
  -X POST "$backend_url/admin/apps" -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
  -d "{\"slug\":\"$app_slug\",\"platform\":\"$platform\",\"package_name\":\"$package_name\"}")"
case "$register_status" in
  201) echo "Registered $app_slug" ;;
  409) echo "$app_slug already exists on the backend, continuing" ;;
  401|403) fail "Backend rejected the API key (HTTP $register_status) — check --api-key" ;;
  *) fail "Unexpected response registering the app (HTTP $register_status): $(cat /tmp/app_updater_init_register.json)" ;;
esac

step "Generate a fresh RSA signing key pair (kept outside the Flutter project)"
mkdir -p "$key_dir"
if [[ -f "$private_key" ]]; then
  fail "A key already exists at $private_key — remove it first if you really want to regenerate (this would orphan any patches already signed with it)"
fi
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key" 2>/dev/null
chmod 600 "$private_key"
openssl pkey -in "$private_key" -pubout -outform DER -out "$public_key_der"

step "Register the public key with the backend"
public_key_base64url="$(openssl base64 -A -in "$public_key_der" | tr '+/' '-_' | tr -d '=')"
key_status="$(curl -s -o /tmp/app_updater_init_key.json -w '%{http_code}' \
  -X POST "$backend_url/admin/apps/$app_slug/keys" -H "X-Api-Key: $api_key" -H "Content-Type: application/json" \
  -d "{\"key_id\":\"$key_id\",\"public_key_der_base64url\":\"$public_key_base64url\",\"algorithm\":\"rsa_pkcs1_sha256\"}")"
[[ "$key_status" == "201" ]] || fail "Unexpected response registering the key (HTTP $key_status): $(cat /tmp/app_updater_init_key.json)"

step "Write app_updater.yaml into the project"
config_file="$project_dir/app_updater.yaml"
cat > "$config_file" <<EOF
app_slug: $app_slug
backend_url: $backend_url
trusted_keys:
  - key_id: $key_id
    algorithm: rsa_pkcs1_sha256
    public_key: $public_key_base64url
revoked_key_ids: []
EOF

echo
echo "Done. Next steps:"
echo "  1. Add 'app_updater' as a pubspec.yaml dependency in $project_dir"
echo "  2. Make MainActivity extend FlutterOtaActivity (Kotlin, one line)"
echo "  3. Call AppUpdater.instance.autoUpdate() in main()"
echo "  4. Keep the private signing key SECRET, it is not in the Flutter project:"
echo "       $private_key"
echo "     You need it (via OTA_SIGNING_KEY_PATH or OTA_SIGN_CMD) whenever you build a patch."
echo "  See app_updater/README.md for the full integration guide."
