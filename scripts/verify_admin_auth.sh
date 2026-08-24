#!/usr/bin/env bash
set -euo pipefail

# Exercises the per-operator admin auth model: the static ADMIN_API_KEY is the "root" bootstrap
# key (only usable to manage operators), every other admin action requires a per-operator key
# minted via that root key, and every admin request is recorded in admin_actions for audit.

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_host_port="${BACKEND_HOST_PORT:-8081}"
root_key="${ADMIN_API_KEY:-dev-admin-key}"
api="http://localhost:$backend_host_port"

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

step "Reset the backend to a known-empty state"
(cd "$repo_dir" && docker compose down -v) > /dev/null 2>&1 || true
(cd "$repo_dir" && ADMIN_API_KEY="$root_key" BACKEND_HOST_PORT="$backend_host_port" \
  docker compose up -d --build) > /dev/null
for i in $(seq 1 30); do
  curl -sf "$api/healthz" > /dev/null 2>&1 && break
  [[ "$i" -eq 30 ]] && fail "Backend did not become healthy at $api"
  sleep 1
done

step "A non-root key cannot create an operator"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$api/admin/operators" \
  -H "X-Api-Key: not-a-real-key" -H "Content-Type: application/json" -d '{"name":"alice"}')"
[[ "$status" == "401" ]] || fail "Expected 401 for an unknown key, got $status"

step "The root key creates an operator and receives a plaintext key exactly once"
create_response="$(curl -sf -X POST "$api/admin/operators" -H "X-Api-Key: $root_key" \
  -H "Content-Type: application/json" -d '{"name":"alice"}')"
echo "$create_response" | grep -q '"api_key"' || fail "Expected api_key in operator creation response"
alice_key="$(echo "$create_response" | sed -n 's/.*"api_key":"\([^"]*\)".*/\1/p')"
[[ -n "$alice_key" ]] || fail "Could not extract alice's api_key"

step "A freshly created operator with a non-root key cannot mint other operators"
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$api/admin/operators" \
  -H "X-Api-Key: $alice_key" -H "Content-Type: application/json" -d '{"name":"bob"}')"
[[ "$status" == "403" ]] || fail "Expected 403 for a non-root key creating an operator, got $status"

step "The operator's own key works for ordinary admin actions (registering an app)"
curl -sf -X POST "$api/admin/apps" -H "X-Api-Key: $alice_key" -H "Content-Type: application/json" \
  -d '{"slug":"auth-test-app","platform":"android","package_name":"com.example.auth_test"}' > /dev/null

step "Revoking the operator's key blocks further admin actions"
alice_id="$(echo "$create_response" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
curl -sf -X DELETE "$api/admin/operators/$alice_id" -H "X-Api-Key: $root_key" > /dev/null
status="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$api/admin/apps" -H "X-Api-Key: $alice_key" \
  -H "Content-Type: application/json" \
  -d '{"slug":"should-fail","platform":"android","package_name":"com.example.should_fail"}')"
[[ "$status" == "401" ]] || fail "Expected 401 for a revoked key, got $status"

step "Every admin request, including denied ones, was recorded in the audit log"
actions="$(curl -sf "$api/admin/actions?limit=50" -H "X-Api-Key: $root_key")"
echo "$actions" | grep -q '"operator_name":"alice"' || fail "Expected an audited action for operator alice"
echo "$actions" | grep -q '"operator_name":"unknown"' || fail "Expected an audited action for the rejected unknown key"
echo "$actions" | grep -q '"operator_name":"root"' || fail "Expected an audited action for the root key"

echo
echo "PASS: per-operator admin auth and audit logging work as expected"
