#!/usr/bin/env bash
# scripts/measure.sh — launcher only. The logic lives in scripts/lib/measure.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/measure.rb" "$@"
