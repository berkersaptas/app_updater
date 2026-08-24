#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: $0 <apk>" >&2; exit 2; }
unzip -Z1 "$1" | grep -E '^lib/(arm64-v8a|armeabi-v7a|x86_64)/(libapp|libflutter)\.so$' | sort
