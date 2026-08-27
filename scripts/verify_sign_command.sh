#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

payload_for() {
  local output="$1"
  local key_id="$2"
  local algorithm="$3"
  "$repo_dir/scripts/write_manifest_payload.sh" "$output" 2 2 "1.0.0+1" 1 \
    full_aot_library 83675ed27633283e7fc296c8bca22e841224c096 3.12.2 \
    arm64-v8a release aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    46612b3568f1b3220765c4138063d6940fdb87bc5dd5197555bd3c188e0be766 \
    ec59d1df4b8a03d38eaf99f01a599eb7e2572f4c4f6f694a409e6da2304a9cb7 \
    "$key_id" "$algorithm"
}

# Fake KMS command boundary: OTA_SIGN_CMD reads the payload from stdin and prints a base64
# signature, matching what scripts/build_patch.sh expects. OTA_PUBLIC_KEY_CMD prints the
# base64url-encoded DER public key, matching what
# scripts/generate_compatibility_metadata.sh expects.
verify_kms_boundary() {
  local algorithm="$1"
  local private_key="$work_dir/${algorithm}_private.pem"
  local public_key_pem="$work_dir/${algorithm}_public.pem"
  local public_key_der="$work_dir/${algorithm}_public.der"
  local payload="$work_dir/${algorithm}_payload.txt"
  local sign_cmd="$work_dir/${algorithm}_sign.sh"
  local public_key_cmd="$work_dir/${algorithm}_public_key.sh"

  case "$algorithm" in
    ed25519)
      openssl genpkey -algorithm ED25519 -out "$private_key" >/dev/null 2>&1
      cat > "$sign_cmd" <<EOF
#!/usr/bin/env bash
set -euo pipefail
stdin_payload="\$(mktemp)"
trap 'rm -f "\$stdin_payload"' EXIT
cat > "\$stdin_payload"
openssl pkeyutl -sign -rawin -inkey "$private_key" -in "\$stdin_payload" | openssl base64 -A
EOF
      ;;
    rsa_pkcs1_sha256)
      openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$private_key" >/dev/null 2>&1
      cat > "$sign_cmd" <<EOF
#!/usr/bin/env bash
set -euo pipefail
openssl dgst -sha256 -sign "$private_key" -binary | openssl base64 -A
EOF
      ;;
    *)
      echo "Unsupported algorithm: $algorithm" >&2
      exit 2
      ;;
  esac
  chmod +x "$sign_cmd"

  openssl pkey -in "$private_key" -pubout -out "$public_key_pem"
  openssl pkey -pubin -in "$public_key_pem" -outform DER -out "$public_key_der"
  cat > "$public_key_cmd" <<EOF
#!/usr/bin/env bash
set -euo pipefail
openssl base64 -A -in "$public_key_der" | tr '+/' '-_' | tr -d '='
EOF
  chmod +x "$public_key_cmd"

  payload_for "$payload" "kms-$algorithm-v1" "$algorithm"

  # Sign the same way scripts/build_patch.sh does for OTA_SIGN_CMD.
  local signature
  signature="$(
    sh -c "$sign_cmd" < "$payload" | tr '+/' '-_' | tr -d '=\n'
  )"
  [[ "$signature" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "OTA_SIGN_CMD produced an invalid base64url signature for $algorithm" >&2
    exit 1
  }

  # Fetch the public key the same way scripts/generate_compatibility_metadata.sh will for
  # OTA_PUBLIC_KEY_CMD, then verify offline with openssl using standard base64 padding.
  local public_key_base64url
  public_key_base64url="$(sh -c "$public_key_cmd")"
  [[ "$public_key_base64url" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "OTA_PUBLIC_KEY_CMD produced invalid output for $algorithm" >&2
    exit 1
  }

  local fetched_public_der="$work_dir/${algorithm}_fetched_public.der"
  python3 -c '
import base64, sys
value = sys.argv[1]
value += "=" * (-len(value) % 4)
sys.stdout.buffer.write(base64.urlsafe_b64decode(value))
' "$public_key_base64url" > "$fetched_public_der"
  cmp -s "$public_key_der" "$fetched_public_der" || {
    echo "OTA_PUBLIC_KEY_CMD output did not round-trip to the original DER key for $algorithm" >&2
    exit 1
  }

  local signature_bin="$work_dir/${algorithm}_signature.bin"
  python3 -c '
import base64, sys
value = sys.argv[1]
value += "=" * (-len(value) % 4)
sys.stdout.buffer.write(base64.urlsafe_b64decode(value))
' "$signature" > "$signature_bin"

  case "$algorithm" in
    ed25519)
      openssl pkeyutl -verify -rawin -pubin -inkey "$public_key_pem" -in "$payload" \
        -sigfile "$signature_bin" >/dev/null
      ;;
    rsa_pkcs1_sha256)
      openssl dgst -sha256 -verify "$public_key_pem" -signature "$signature_bin" "$payload" >/dev/null
      ;;
  esac
}

verify_kms_boundary ed25519
verify_kms_boundary rsa_pkcs1_sha256

echo "OTA_SIGN_CMD/OTA_PUBLIC_KEY_CMD KMS-style boundary is valid for ed25519 and rsa_pkcs1_sha256"
