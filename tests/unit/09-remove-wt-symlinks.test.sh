#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: remove_wt_symlinks${RESET}\n"

_extract_fn() {
  awk "/^${1}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$SCRIPTS_DIR/dev-supabase-helpers.sh"
}
eval "$(_extract_fn list_migration_dirs)"
eval "$(_extract_fn remove_wt_symlinks)"

header "removes only target worktree symlinks"
setup_tmpdir

WT_A="$TEST_TMPDIR/feat-a"
WT_B="$TEST_TMPDIR/feat-b"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT_A/supabase/migrations/app" "$WT_B/supabase/migrations/app" "$SB/supabase/migrations/app"

echo "sql" > "$WT_A/supabase/migrations/app/20260418000001_a.sql"
echo "sql" > "$WT_B/supabase/migrations/app/20260418000003_b.sql"
echo "sql" > "$SB/supabase/migrations/app/20260101000000_init.sql"
ln -s "$WT_A/supabase/migrations/app/20260418000001_a.sql" "$SB/supabase/migrations/app/20260418000001_a.sql"
ln -s "$WT_B/supabase/migrations/app/20260418000003_b.sql" "$SB/supabase/migrations/app/20260418000003_b.sql"

OUTPUT=$(remove_wt_symlinks "$WT_A" "$SB")
assert_contains "reports 1 removed" "Removed 1" "$OUTPUT"
assert_file_not_exists "a.sql removed" "$SB/supabase/migrations/app/20260418000001_a.sql"
assert_symlink "b.sql still intact" "$SB/supabase/migrations/app/20260418000003_b.sql"

print_results
