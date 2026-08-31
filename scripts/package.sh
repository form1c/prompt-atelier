#!/usr/bin/env bash
# scripts/package.sh — launcher only. The logic lives in scripts/lib/package.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/package.rb" "$@"
