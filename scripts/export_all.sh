#!/usr/bin/env bash
# scripts/export_all.sh — launcher only. The logic lives in scripts/lib/export_all.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/export_all.rb" "$@"
