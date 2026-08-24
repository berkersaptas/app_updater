#!/usr/bin/env bash
set -euo pipefail

# Exercises the self-service developer web portal end to end: registration/login, self-service
# app creation with a server-generated signing key, per-app membership permissions (invite/remove,
# owner-only), and that the last owner of an app cannot be removed. Fully separate from the
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

step "Bob cannot view Alice's app before being invited"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" "$api/apps/$app_slug")"
[[ "$status" == "403" ]] || fail "Expected 403 before Bob is invited, got $status"

step "Alice invites Bob as a member"
curl -sf -b "$jar_a" -X POST "$api/apps/$app_slug/members" -d "email=bob-$unique@example.com&role=member" -o /dev/null

step "Bob can now view the app"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_b" "$api/apps/$app_slug")"
[[ "$status" == "200" ]] || fail "Expected 200 after Bob is invited, got $status"

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

step "The last remaining owner cannot be removed"
app_view="$(curl -sf -b "$jar_a" "$api/apps/$app_slug")"
alice_delete_path="$(echo "$app_view" | grep -oE "/apps/$app_slug/members/[a-f0-9-]+/delete" | tail -1)"
status="$(curl -s -o /dev/null -w '%{http_code}' -b "$jar_a" -X POST "$api$alice_delete_path")"
[[ "$status" == "400" ]] || fail "Expected 400 removing the last owner, got $status"

echo
echo "PASS: self-service portal registration, app creation, and per-app membership work as expected"
