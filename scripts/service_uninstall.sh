#!/usr/bin/env bash
# scripts/service_uninstall.sh — launcher only. The logic lives in scripts/lib/service_uninstall.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/service_uninstall.rb" "$@"
