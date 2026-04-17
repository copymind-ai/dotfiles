#!/usr/bin/env bash
set -euo pipefail

# Show Supabase status.
# Usage: dev sb status

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

if supabase_is_running; then
  supabase status
else
  echo "Supabase is not running."
  echo "  To start: dev sb up"
fi
