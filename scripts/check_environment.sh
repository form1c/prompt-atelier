#!/usr/bin/env bash
# scripts/check_environment.sh — launcher only. The logic lives in scripts/lib/check_environment.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/check_environment.rb" "$@"
