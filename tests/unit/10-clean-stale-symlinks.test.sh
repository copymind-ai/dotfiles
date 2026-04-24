#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: clean_stale_symlinks${RESET}\n"

_extract_fn() {
  awk "/^${1}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$SCRIPTS_DIR/dev-supabase-helpers.sh"
}
eval "$(_extract_fn list_migration_dirs)"
eval "$(_extract_fn clean_stale_symlinks)"

header "removes broken symlinks"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT/supabase/migrations/app/20260418000001_exists.sql"
ln -s "$WT/supabase/migrations/app/20260418000001_exists.sql" "$SB/supabase/migrations/app/20260418000001_exists.sql"
ln -s "$WT/supabase/migrations/app/20260418000002_deleted.sql" "$SB/supabase/migrations/app/20260418000002_deleted.sql"

OUTPUT=$(clean_stale_symlinks "$WT" "$SB")
assert_contains "reports 1 stale removed" "Removed 1 stale" "$OUTPUT"
assert_symlink "valid symlink untouched" "$SB/supabase/migrations/app/20260418000001_exists.sql"
assert_file_not_exists "stale symlink removed" "$SB/supabase/migrations/app/20260418000002_deleted.sql"

print_results
