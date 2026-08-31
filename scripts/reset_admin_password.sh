#!/usr/bin/env bash
# scripts/reset_admin_password.sh — launcher only.
# The logic lives in scripts/lib/reset_admin_password.rb
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$DIR/lib/reset_admin_password.rb" "$@"
