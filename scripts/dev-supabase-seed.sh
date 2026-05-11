#!/usr/bin/env bash
set -euo pipefail

# Apply pending seeds in the shared supabase worktree.
# Usage: dev sb seed

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase.helpers.sh"

require_bare_repo

if ! supabase_is_running; then
  echo "Error: Supabase is not running. Start it first: dev sb up" >&2
  exit 1
fi

supabase_wt="$(find_supabase_wt)"
do_seed_up "$supabase_wt"
