#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: get_latest_origin_timestamp${RESET}\n"

_extract_fn() {
  awk "/^${1}\\(\\)/{found=1} found{print} found && /^\\}/{exit}" "$SCRIPTS_DIR/dev-supabase-helpers.sh"
}
eval "$(_extract_fn get_latest_origin_timestamp)"

header "returns latest real timestamp"
setup_tmpdir

SB="$TEST_TMPDIR/supabase"
mkdir -p "$SB/supabase/migrations/app"
echo "sql" > "$SB/supabase/migrations/app/20260101000000_init.sql"
echo "sql" > "$SB/supabase/migrations/app/20260418000001_feature.sql"
ln -s "/fake/path.sql" "$SB/supabase/migrations/app/20260501000000_symlink.sql"

RESULT="$(get_latest_origin_timestamp "$SB")"
assert_eq "returns latest real timestamp" "20260418000001" "$RESULT"

print_results
