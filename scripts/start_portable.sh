#!/usr/bin/env bash
# scripts/start_portable.sh — launcher only. The logic lives in scripts/lib/start_portable.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/start_portable.rb" "$@"
