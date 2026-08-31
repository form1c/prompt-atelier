#!/usr/bin/env bash
# scripts/restore.sh — launcher only. The logic lives in scripts/lib/restore.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/restore.rb" "$@"
