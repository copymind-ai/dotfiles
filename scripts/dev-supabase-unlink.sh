#!/usr/bin/env bash
set -euo pipefail

# Remove current worktree's migration symlinks, apply its local rollback
# scripts (supabase/rollbacks/ — reverts the DDL, not just the history),
# and repair DB history.
# Usage: dev sb unlink [--reset]
#   --reset  After unlinking, run a full DB reset (dev sb reset) — escape
#            hatch for when rollback scripts were missing or failed and
#            phantom schema remains.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase.helpers.sh"

require_bare_repo

RESET_AFTER=false
if [ "${1:-}" = "--reset" ]; then
  RESET_AFTER=true
fi

current_wt="$(git rev-parse --show-toplevel)"
unlink_worktree_migrations "$current_wt"

if [ "$RESET_AFTER" = true ]; then
  exec "$SCRIPT_DIR/dev-supabase-reset.sh"
fi
