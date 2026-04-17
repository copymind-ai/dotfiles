#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: discover_supabase_vars${RESET}\n"

eval "$(sed -n '/^discover_supabase_vars()/,/^}/p' "$SCRIPTS_DIR/dev-worktree-env.sh")"

header "discover_supabase_vars"
setup_tmpdir

WORKTREE="$TEST_TMPDIR/worktree"
mkdir -p "$WORKTREE/src/lib"
ENV="$WORKTREE/.env.local"

cat > "$WORKTREE/src/lib/config.ts" << 'TS'
const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const other = process.env.NODE_ENV;
TS
cat > "$ENV" << 'ENV'
NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
DATABASE_URL=postgresql://localhost/db
UNRELATED_VAR=foo
ENV

VARS="$(discover_supabase_vars "$WORKTREE" "$ENV")"
assert_contains "finds SUPABASE_URL" "NEXT_PUBLIC_SUPABASE_URL" "$VARS"
assert_contains "finds ANON_KEY" "NEXT_PUBLIC_SUPABASE_ANON_KEY" "$VARS"
assert_contains "finds DATABASE_URL" "DATABASE_URL" "$VARS"
assert_not_contains "excludes NODE_ENV" "NODE_ENV" "$VARS"
assert_not_contains "excludes UNRELATED_VAR" "UNRELATED_VAR" "$VARS"

print_results
