#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: find_new_migrations${RESET}\n"

_extract_fn() {
  awk "/^${1}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$SCRIPTS_DIR/dev-supabase-helpers.sh"
}
eval "$(_extract_fn find_new_migrations)"

header "detects new migration"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "CREATE TABLE a;" > "$WT/supabase/migrations/app/20260418000001_a.sql"
RESULT="$(find_new_migrations "$WT" "$SB")"
assert_contains "detects new migration" "20260418000001_a.sql" "$RESULT"

header "skips real file from origin"
echo "CREATE TABLE a;" > "$SB/supabase/migrations/app/20260418000001_a.sql"
RESULT="$(find_new_migrations "$WT" "$SB")"
assert_eq "skips real file from origin" "" "$RESULT"

header "skips correctly symlinked"
setup_tmpdir

WT="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT/supabase/migrations/app/20260418000002_b.sql"
ln -s "$WT/supabase/migrations/app/20260418000002_b.sql" "$SB/supabase/migrations/app/20260418000002_b.sql"
RESULT="$(find_new_migrations "$WT" "$SB")"
assert_eq "skips correctly symlinked" "" "$RESULT"

header "discovers arbitrarily-named subdir"
setup_tmpdir

WT="$TEST_TMPDIR/feat-c"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/analytics" "$SB/supabase/migrations"

echo "sql" > "$WT/supabase/migrations/analytics/20260424000000_c.sql"
RESULT="$(find_new_migrations "$WT" "$SB")"
assert_contains "finds file under custom subdir" "analytics/20260424000000_c.sql" "$RESULT"

print_results
