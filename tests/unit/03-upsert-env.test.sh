#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: upsert_env${RESET}\n"

_source_fn() {
  eval "$(sed -n "/^${1}()/,/^}/p" "$SCRIPTS_DIR/dev-worktree-env.sh")"
}
_source_fn upsert_env

header "insert and update"
setup_tmpdir
ENV="$TEST_TMPDIR/.env.local"
echo "EXISTING_KEY=old_value" > "$ENV"

upsert_env "$ENV" "NEW_KEY" "new_value"
assert_contains "new key appended" "NEW_KEY=new_value" "$(cat "$ENV")"
assert_contains "existing key untouched" "EXISTING_KEY=old_value" "$(cat "$ENV")"

upsert_env "$ENV" "EXISTING_KEY" "updated_value"
assert_contains "key updated" "EXISTING_KEY=updated_value" "$(cat "$ENV")"
assert_not_contains "old value gone" "old_value" "$(cat "$ENV")"

header "empty file, no double newlines"
setup_tmpdir
ENV="$TEST_TMPDIR/.env.local"
touch "$ENV"
upsert_env "$ENV" "FIRST_KEY" "first_value"
assert_contains "key written to empty file" "FIRST_KEY=first_value" "$(cat "$ENV")"

printf "KEY1=val1" > "$ENV"  # no trailing newline
upsert_env "$ENV" "KEY2" "val2"
upsert_env "$ENV" "KEY3" "val3"
BLANK_LINES=$(grep -c '^$' "$ENV" || true)
assert_eq "no blank lines" "0" "$BLANK_LINES"

print_results
