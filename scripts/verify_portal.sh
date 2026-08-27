#!/usr/bin/env bash
set -euo pipefail

# Exercises the self-service developer web portal end to end: registration/login, self-service
# app creation with a server-generated signing key, per-app membership permissions (invite/remove,
# owner-only), app-logo validation/access, and that the last owner of an app cannot be removed. Fully separate from the
# operator/API-key admin model (scripts/verify_admin_auth.sh) — this proves the two don't interfere.

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_host_port="${BACKEND_HOST_PORT:-8081}"
api="http://localhost:$backend_host_port"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

step "Reset the backend to a known-empty state"
(cd "$repo_dir" && docker compose down -v) > /dev/null 2>&1 || true
(cd "$repo_dir" && BACKEND_HOST_PORT="$backend_host_port" docker compose up -d --build) > /dev/null
for i in $(seq 1 30); do
  curl -sf "$api/healthz" > /dev/null 2>&1 && break
  [[ "$i" -eq 30 ]] && fail "Backend did not become healthy at $api"
  sleep 1
done

jar_a="$work_dir/cookies_a.txt"
jar_b="$work_dir/cookies_b.txt"
unique="$(date +%s)"

step "Register two developer accounts"
curl -sf -c "$jar_a" -X POST "$api/auth/register" -d "email=alice-$unique@example.com&password=password123" -o /dev/null
curl -sf -c "$jar_b" -X POST "$api/auth/register" -d "email=bob-$unique@example.com&password=password123" -o /dev/null

step "Alice self-service creates a managed-signing app"
app_slug="portal-verify-$unique"
create_response="$(curl -sf -b "$jar_a" -X POST "$api/apps" -d "slug=$app_slug&package_name=com.example.portal_verify")"
echo "$create_response" | grep -q "app_updater init --app-slug $app_slug" || fail "Expected the connected CLI command"
echo "$create_response" | grep -q "no API or private keys to copy" || fail "Expected managed-signing guidance"
if echo "$create_response" | grep -q "BEGIN PRIVATE KEY"; then
  fail "Managed app creation must not expose a private key"
fi

step "Alice uploads a valid logo and the portal serves its normalized variants"
logo="$work_dir/logo.png"
logo_base64='iVBORw0KGgoAAAANSUhEUgAAAIAAAACACAYAAADDPmHLAAAACXBIWXMAAAPoAAAD6AG1e1JrAAACf0lEQVR4nO2cwY3EQBACJzq+5B9Ax2GHARL1qP8JStyuPbPPug9uNoOX/gPgEAAJjgVAguNfABIcnwGQ4PgQiATHtwAkOL4GIsHxHAAJjgdBSHA8CUSC41EwEhzvApDgeBmEBMfbQCQ4XgcjwXEeAAmOAyFIcJwIQoLjSBgSHGcCkeA4FIoEx6lgJDiOhSPBcS8ACY6LIUhw3AxCguNqGBIcdwOR4LgcigTH7WAkOK6Hm+vp/D6AxyXgByKULwEBCoLwKCyA8iUgQEEQHoUFUL4EBCgIwqOwAMqXgAAFQXgUFkD5EhCgIAiPwgIoXwICFAThUVgA5UtAgIIgPAoLoHwJCFAQhEdhAZQvAQEKgvAoLIDyJSBAQRAehQVQvgQEKAjCo7AAypeAAAVBeBQWQPkSEKAgCI/CAihfAgIUBOFRWADlS0CAgiA8CgugfAkIUBCER2EBlC8BAQqC8CgsgPIlIEBBEB6FBVC+BAQoCMKjsADKl4AABUF4FBZA+RIQoCAIj8ICKF8CAhQE4VFYAOVLQICCIDwKC6B8CQhQEIRHYQGULwEBCoLwKCyA8iUgQEEQHoUFUL4EBCgIwqOwAMqXgAAFQXgUFkD5EhCgIAiPwgIoXwICFAThUVgA5UtAgIIgPAoLoHwJCFAQhEdhAZQvAQEKgvAoLIDyJSBAQRAehQVQvgQEKAjCo7AAypeAAAVBeBQWQPkSEKAgCI/CAihfAgIUBOFRWADlS0CAgiA8CgugfAkIUBCER2EBlC8BAQqC8CgsgPIlIEBBEB6FBVC+BAQoCMKjsADKl4AABUF4FBZA+RIQoCAIj8ICKF8CAhQE4VFYAOVLQICCIDzKD5KgSUPlDt7xAAAAAElFTkSuQmCC'
printf '%s' "$logo_base64" | openssl base64 -d -A -out "$logo"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_a" -X POST "$api/apps/$app_slug/logo" -F "logo=@$logo;type=image/png")"
[[ "$status" == "303" ]] || fail "Expected 303 for a valid owner logo upload, got $status"
app_view="$(curl -sf -b "$jar_a" "$api/apps/$app_slug")"
echo "$app_view" | grep -q "/apps/$app_slug/logo" || fail "Expected app page to render the uploaded logo"
content_type="$(curl -sf -b "$jar_a" -o "$work_dir/thumbnail.webp" -w '%{content_type}' "$api/apps/$app_slug/logo?size=thumbnail")"
[[ "$content_type" == "image/webp" ]] || fail "Expected normalized WebP logo, got $content_type"

step "Logo upload rejects malformed files"
printf '%s' 'not-an-image' > "$work_dir/broken.png"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_a" -X POST "$api/apps/$app_slug/logo" -F "logo=@$work_dir/broken.png;type=image/png")"
[[ "$status" == "400" ]] || fail "Expected 400 for a malformed image, got $status"
dd if=/dev/zero of="$work_dir/too-large.png" bs=1048576 count=3 2>/dev/null
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_a" -X POST "$api/apps/$app_slug/logo" -F "logo=@$work_dir/too-large.png;type=image/png")"
[[ "$status" == "413" ]] || fail "Expected 413 for a logo over 2 MB, got $status"

step "The authenticated CLI endpoint can explicitly replace the owner app logo"
alice_login="$(curl -sf -X POST "$api/v1/cli/login" -H 'Content-Type: application/json' -d "{\"email\":\"alice-$unique@example.com\",\"password\":\"password123\"}")"
alice_cli_token="$(printf '%s' "$alice_login" | sed -E 's/.*"token":"([^"]+)".*/\1/')"
[[ -n "$alice_cli_token" && "$alice_cli_token" != "$alice_login" ]] || fail "Could not read Alice's CLI token"
status="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$api/v1/cli/apps/$app_slug/logo" -H "Authorization: Bearer $alice_cli_token" -F "logo=@$logo;type=image/png")"
[[ "$status" == "200" ]] || fail "Expected 200 from owner CLI logo replacement, got $status"

step "Bob cannot view Alice's app before being invited"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" "$api/apps/$app_slug")"
[[ "$status" == "403" ]] || fail "Expected 403 before Bob is invited, got $status"

step "Alice invites Bob as a member"
curl -sf -b "$jar_a" -X POST "$api/apps/$app_slug/members" -d "email=bob-$unique@example.com&role=member" -o /dev/null

step "Bob can now view the app"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" "$api/apps/$app_slug")"
[[ "$status" == "200" ]] || fail "Expected 200 after Bob is invited, got $status"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" "$api/apps/$app_slug/logo")"
[[ "$status" == "200" ]] || fail "Expected an app member to view the logo, got $status"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" -X POST "$api/apps/$app_slug/logo" -F "logo=@$logo;type=image/png")"
[[ "$status" == "403" ]] || fail "Expected 403 for a non-owner replacing the logo, got $status"
bob_login="$(curl -sf -X POST "$api/v1/cli/login" -H 'Content-Type: application/json' -d "{\"email\":\"bob-$unique@example.com\",\"password\":\"password123\"}")"
bob_cli_token="$(printf '%s' "$bob_login" | sed -E 's/.*"token":"([^"]+)".*/\1/')"
status="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$api/v1/cli/apps/$app_slug/logo" -H "Authorization: Bearer $bob_cli_token" -F "logo=@$logo;type=image/png")"
[[ "$status" == "403" ]] || fail "Expected 403 for a non-owner CLI logo replacement, got $status"

step "Bob (a non-owner member) cannot invite a third user"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" -X POST "$api/apps/$app_slug/members" -d "email=carol-$unique@example.com&role=member")"
[[ "$status" == "403" ]] || fail "Expected 403 for a non-owner inviting, got $status"

step "Alice removes Bob, who then loses access again"
app_view="$(curl -sf -b "$jar_a" "$api/apps/$app_slug")"
bob_delete_path="$(echo "$app_view" | grep -oE "/apps/$app_slug/members/[a-f0-9-]+/delete" | tail -1)"
[[ -n "$bob_delete_path" ]] || fail "Could not find Bob's remove-member form action"
curl -sf -b "$jar_a" -X POST "$api$bob_delete_path" -o /dev/null
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" "$api/apps/$app_slug")"
[[ "$status" == "403" ]] || fail "Expected 403 after Bob was removed, got $status"

step "Alice removes the logo and the portal returns to its fallback mark"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_a" -X POST "$api/apps/$app_slug/logo/delete")"
[[ "$status" == "303" ]] || fail "Expected 303 deleting the logo, got $status"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_a" "$api/apps/$app_slug/logo")"
[[ "$status" == "404" ]] || fail "Expected 404 after deleting the logo, got $status"
curl -sf -b "$jar_a" "$api/apps/$app_slug" | grep -q 'app-logo-fallback' || fail "Expected fallback mark after logo deletion"

step "The last remaining owner cannot be removed"
app_view="$(curl -sf -b "$jar_a" "$api/apps/$app_slug")"
alice_delete_path="$(echo "$app_view" | grep -oE "/apps/$app_slug/members/[a-f0-9-]+/delete" | tail -1)"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_a" -X POST "$api$alice_delete_path")"
[[ "$status" == "400" ]] || fail "Expected 400 removing the last owner, got $status"

echo
echo "PASS: portal registration, app logos, and per-app membership work as expected"
