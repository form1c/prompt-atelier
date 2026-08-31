#!/usr/bin/env bash
# scripts/run_tests.sh — launcher only. The logic lives in scripts/lib/run_tests.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/run_tests.rb" "$@"
