#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: upsert_env_sorted${RESET}\n"

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/dev-helpers.sh"

header "alphabetical insertion into empty file"
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
upsert_env_sorted "$ENV" "BAR" "2"
upsert_env_sorted "$ENV" "FOO" "1"
upsert_env_sorted "$ENV" "BAZ" "3"
EXPECTED=$'BAR=2\nBAZ=3\nFOO=1'
assert_eq "three keys in alphabetical order" "$EXPECTED" "$(cat "$ENV")"

header "update existing key replaces value, no duplicate"
upsert_env_sorted "$ENV" "FOO" "1-updated"
assert_contains "new value present" "FOO=1-updated" "$(cat "$ENV")"
LINE_COUNT=$(grep -c "^FOO=" "$ENV")
assert_eq "no duplicate FOO line" "1" "$LINE_COUNT"

header "byte-order sort (LC_ALL=C): URL= before URL_PRIMARY="
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
# Insert in reverse alphabetical order, expect byte-order on disk.
# Without LC_ALL=C, macOS locale sort would reverse these.
upsert_env_sorted "$ENV" "URL_PRIMARY" "y"
upsert_env_sorted "$ENV" "URL" "x"
EXPECTED=$'URL=x\nURL_PRIMARY=y'
assert_eq "URL= sorts before URL_PRIMARY=" "$EXPECTED" "$(cat "$ENV")"

header "special chars in value preserved verbatim"
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
URL_VALUE="postgres://user:pass@host:5432/db?x=y#frag"
upsert_env_sorted "$ENV" "DATABASE_URL" "$URL_VALUE"
ACTUAL=$(grep "^DATABASE_URL=" "$ENV" | sed 's/^DATABASE_URL=//')
assert_eq "URL with =, /, :, ?, #, @ unmangled" "$URL_VALUE" "$ACTUAL"

header "creates file if missing"
setup_tmpdir
ENV="$TEST_TMPDIR/does-not-exist/.env"
mkdir -p "$(dirname "$ENV")"
assert_file_not_exists "no file before" "$ENV"
upsert_env_sorted "$ENV" "FIRST_KEY" "first_value"
assert_file_exists "file created" "$ENV"
assert_eq "single key written" "FIRST_KEY=first_value" "$(cat "$ENV")"

header "no blank lines after multiple inserts"
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
upsert_env_sorted "$ENV" "A" "1"
upsert_env_sorted "$ENV" "B" "2"
upsert_env_sorted "$ENV" "C" "3"
BLANKS=$(grep -c '^$' "$ENV" || true)
assert_eq "no blank lines" "0" "$BLANKS"

header "empty value writes KEY="
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
upsert_env_sorted "$ENV" "EMPTY_KEY" ""
assert_eq "empty value preserved" "EMPTY_KEY=" "$(cat "$ENV")"

print_results
