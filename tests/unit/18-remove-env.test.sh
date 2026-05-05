#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: remove_env${RESET}\n"

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/dev-helpers.sh"

header "removes existing line, keeps others"
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
cat > "$ENV" <<'EOF'
ALPHA=1
BETA=2
GAMMA=3
EOF
remove_env "$ENV" "BETA"
EXPECTED=$'ALPHA=1\nGAMMA=3'
assert_eq "BETA removed, others intact" "$EXPECTED" "$(cat "$ENV")"

header "no-op on missing key"
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
cat > "$ENV" <<'EOF'
ALPHA=1
BETA=2
EOF
ORIGINAL="$(cat "$ENV")"
remove_env "$ENV" "DELTA"
assert_eq "file unchanged when key absent" "$ORIGINAL" "$(cat "$ENV")"

header "no-op on missing file (no error)"
setup_tmpdir
ENV="$TEST_TMPDIR/does-not-exist.env"
EXIT_CODE=0
remove_env "$ENV" "ANY" || EXIT_CODE=$?
assert_exit_code "exits 0 when file missing" "0" "$EXIT_CODE"
assert_file_not_exists "file not created" "$ENV"

header "removes only exact key match (prefix safe)"
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
cat > "$ENV" <<'EOF'
URL=short
URL_PRIMARY=long
EOF
remove_env "$ENV" "URL"
assert_eq "URL_PRIMARY untouched when removing URL" "URL_PRIMARY=long" "$(cat "$ENV")"

header "removes all duplicate occurrences if present"
setup_tmpdir
ENV="$TEST_TMPDIR/.env"
cat > "$ENV" <<'EOF'
ALPHA=1
DUP=first
BETA=2
DUP=second
EOF
remove_env "$ENV" "DUP"
ACTUAL="$(cat "$ENV")"
assert_not_contains "no DUP= remains" "DUP=" "$ACTUAL"
assert_contains "ALPHA preserved" "ALPHA=1" "$ACTUAL"
assert_contains "BETA preserved" "BETA=2" "$ACTUAL"

print_results
