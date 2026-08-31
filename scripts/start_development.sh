#!/usr/bin/env bash
# scripts/start_development.sh — launcher only. The logic lives in scripts/lib/start_development.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/start_development.rb" "$@"
