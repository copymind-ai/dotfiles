#!/usr/bin/env bash
set -euo pipefail

# Symlink current worktree's new migrations into supabase worktree and apply to DB.
# Usage: dev sb link

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase.helpers.sh"

require_bare_repo

if ! supabase_is_running; then
  echo "Error: Supabase is not running. Start it first: dev sb up" >&2
  exit 1
fi

current_wt="$(git rev-parse --show-toplevel)"
supabase_wt="$(find_supabase_wt)"

# Update supabase worktree to latest origin/main
ensure_fetch_refspec
echo "Updating supabase worktree to origin/main..."
git fetch origin
(cd "$supabase_wt" && git checkout -f origin/main) 2>&1 | grep -v "^HEAD is now at" || true
apply_migrations "$supabase_wt"

# If we're in the supabase worktree itself, nothing to link
if [ "$current_wt" = "$supabase_wt" ]; then
  echo "Already in supabase worktree — nothing to link."
  exit 0
fi

wt_name="$(basename "$current_wt")"

# Clean stale symlinks from this worktree (deleted/renamed files)
clean_stale_symlinks "$current_wt" "$supabase_wt"

new_files="$(find_new_migrations "$current_wt" "$supabase_wt")"
if [ -z "$new_files" ]; then
  echo "No new migrations in $wt_name"
  exit 0
fi

echo "Found new migrations in $wt_name:"
echo "$new_files" | sed 's/^/  /'

latest_ts="$(get_latest_origin_timestamp "$supabase_wt")"
check_timestamps "$wt_name" "$new_files" "$latest_ts" "$supabase_wt"

symlink_migrations "$current_wt" "$new_files" "$supabase_wt"
apply_migrations "$supabase_wt"
