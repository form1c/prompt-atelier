#!/usr/bin/env bash
# scripts/seed_demo.sh — launcher only. The logic lives in scripts/lib/seed_demo.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/seed_demo.rb" "$@"
