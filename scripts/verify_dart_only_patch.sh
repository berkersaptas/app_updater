#!/usr/bin/env bash
set -euo pipefail

# Keep this copy aligned with app_updater_cli/scripts/verify_dart_only_patch.sh. The CLI bundles its
# scripts so it stays self-contained when globally activated outside this repository.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/app_updater_cli/scripts/verify_dart_only_patch.sh" "$@"
