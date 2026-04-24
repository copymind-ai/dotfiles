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

echo ""
echo "==> Starting edge functions..."
# `supabase db reset --local` restarts containers, so the edge runtime
# container is freshly recreated but `supabase functions serve` host
# process from the previous session is gone. Spawn a new one.
ensure_functions_serve "$supabase_wt"
sleep 5

echo ""
echo "==> Done!"
