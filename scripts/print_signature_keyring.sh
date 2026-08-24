#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <active-key-id> [revoked-key-id[,revoked-key-id...]]" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
active_key_id="$1"
revoked_key_ids="${2:-}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_dir="$repo_dir/keys"

[[ "$active_key_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid active key id" >&2
  exit 2
}
if [[ -n "$revoked_key_ids" && ! "$revoked_key_ids" =~ ^[A-Za-z0-9._,-]+$ ]]; then
  echo "Invalid revoked key id list" >&2
  exit 2
fi

trusted_keys=()
while IFS= read -r -d '' public_key; do
  key_id="$(basename "$public_key" _public.der)"
  [[ "$key_id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
  public_key_base64url="$(openssl base64 -A -in "$public_key" | tr '+/' '-_' | tr -d '=')"
  trusted_keys+=("$key_id:$public_key_base64url")
done < <(find "$key_dir" -maxdepth 1 -name '*_public.der' -print0 | sort -z)

[[ ${#trusted_keys[@]} -gt 0 ]] || {
  echo "No OTA public keys found in $key_dir" >&2
  exit 1
}

trusted_keyring="$(IFS=,; echo "${trusted_keys[*]}")"
[[ ",$trusted_keyring," == *",$active_key_id:"* ]] || {
  echo "Active key is not present in trusted keyring: $active_key_id" >&2
  exit 1
}

printf 'export OTA_SIGNATURE_ACTIVE_KEY_ID=%q\n' "$active_key_id"
printf 'export OTA_SIGNATURE_TRUSTED_KEYS=%q\n' "$trusted_keyring"
printf 'export OTA_SIGNATURE_REVOKED_KEY_IDS=%q\n' "$revoked_key_ids"
