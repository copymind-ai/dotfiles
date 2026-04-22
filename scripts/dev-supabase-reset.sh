#!/usr/bin/env bash
set -euo pipefail

# Full local database reset: wipe, re-migrate, seed users, seed data,
# and start edge functions in the background. Operates on the shared
# supabase worktree regardless of invoking cwd.
# Usage: dev sb reset

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/dev-supabase-helpers.sh"

require_bare_repo

if ! supabase_is_running; then
  echo "Error: Supabase is not running. Start it first: dev sb up" >&2
  exit 1
fi

supabase_wt="$(find_supabase_wt)"
db_port="$(get_db_port "$supabase_wt")"

echo "==> Resetting local database..."
supabase_db_reset_with_retry "$supabase_wt"

echo ""
echo "==> Applying migrations..."
do_migrate_up "$supabase_wt"

users_seed="$supabase_wt/supabase/seeds/users.sql"
if [ -f "$users_seed" ]; then
  echo ""
  echo "==> Seeding users..."
  psql "postgresql://postgres:postgres@127.0.0.1:${db_port}/postgres" -q -f "$users_seed"
fi

echo ""
echo "==> Seeding data..."
do_seed_up "$supabase_wt"

if [ "$(edge_runtime_enabled "$supabase_wt")" = "true" ]; then
  echo ""
  echo "==> Starting edge functions..."
  # Redirect the WHOLE subshell's fd 1/2 to /dev/null (not just the inner
  # command's) and redirect stdin from /dev/null. Otherwise the backgrounded
  # subshell keeps the parent's pipe (from command substitution) open, which
  # deadlocks any caller that does OUTPUT=$(dev sb reset).
  (cd "$supabase_wt" && supabase functions serve) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  sleep 5
else
  echo ""
  echo "==> Skipping functions serve (edge_runtime disabled)"
fi

echo ""
echo "==> Done!"
