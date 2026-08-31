#!/usr/bin/env bash
# scripts/install.sh — launcher only. The logic lives in scripts/lib/install.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/install.rb" "$@"
