#!/usr/bin/env bash
# scripts/service_install.sh — launcher only. The logic lives in scripts/lib/service_install.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/service_install.rb" "$@"
