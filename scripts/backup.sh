#!/usr/bin/env bash
# scripts/backup.sh — launcher only. The logic lives in scripts/lib/backup.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/backup.rb" "$@"
