#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 7 ]] || {
  echo "Usage: $0 <protocol> <release> <engine> <dart> <abi> <build-mode> <base-sha256>" >&2
  exit 2
}

protocol="$1"
release="$2"
engine_revision="$3"
dart_version="$4"
abi="$5"
build_mode="$6"
base_sha256="$7"

[[ "$protocol" =~ ^[0-9]+$ ]] || { echo "Invalid OTA protocol version" >&2; exit 2; }
[[ -n "$release" && -n "$dart_version" && -n "$abi" ]] || { echo "Blank fingerprint field" >&2; exit 2; }
[[ "$engine_revision" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid engine revision" >&2; exit 2; }
[[ "$build_mode" == release ]] || { echo "Invalid build mode" >&2; exit 2; }
[[ "$base_sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid base SHA-256" >&2; exit 2; }

printf 'ota_protocol_version=%s\nrelease=%s\nengine_revision=%s\ndart_version=%s\nabi=%s\nbuild_mode=%s\nbase_sha256=%s\n' \
  "$protocol" "$release" "$engine_revision" "$dart_version" "$abi" "$build_mode" \
  "$base_sha256" | shasum -a 256 | awk '{print $1}'
