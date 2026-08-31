#!/usr/bin/env bash
# scripts/import_all.sh — launcher only. The logic lives in scripts/lib/import_all.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/import_all.rb" "$@"
