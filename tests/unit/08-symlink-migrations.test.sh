#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: symlink_migrations${RESET}\n"

_extract_fn() {
  awk "/^${1}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$SCRIPTS_DIR/dev-supabase-helpers.sh"
}
eval "$(_extract_fn symlink_migrations)"

header "creates symlinks"
setup_tmpdir

WT="$TEST_TMPDIR/feat-a"
SB="$TEST_TMPDIR/supabase"
mkdir -p "$WT/supabase/migrations/app" "$SB/supabase/migrations/app"
echo "sql" > "$WT/supabase/migrations/app/20260418000001_x.sql"

OUTPUT=$(symlink_migrations "$WT" "supabase/migrations/app/20260418000001_x.sql" "$SB")
assert_symlink "symlink created" "$SB/supabase/migrations/app/20260418000001_x.sql"
assert_contains "reports count" "Symlinked 1" "$OUTPUT"

print_results
