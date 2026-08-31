#!/usr/bin/env bash
# scripts/build.sh — launcher only. The logic lives in scripts/lib/build.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/build.rb" "$@"
