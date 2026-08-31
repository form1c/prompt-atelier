#!/usr/bin/env bash
# scripts/migrate.sh — launcher only. The logic lives in scripts/lib/migrate.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/migrate.rb" "$@"
