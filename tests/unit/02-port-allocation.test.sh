#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: port allocation${RESET}\n"

header "port allocation"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"

MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert_eq "next port after 13000" "13001" "$NEW_PORT"

printf "feat-a\t13001\t2026-01-02\n" >> "$REGISTRY"
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert_eq "next port after 13001" "13002" "$NEW_PORT"

BASE_PORT=13000
printf "feat-overflow\t13099\t2026-01-03\n" >> "$REGISTRY"
MAX_PORT=$(grep -v '^#' "$REGISTRY" | awk -F'\t' '{print $2}' | sort -n | tail -1)
NEW_PORT=$((MAX_PORT + 1))
assert "port overflow detected" test "$NEW_PORT" -ge $((BASE_PORT + 100))

header "port registry removal"
setup_tmpdir

REGISTRY="$TEST_TMPDIR/.worktree-ports"
printf "# worktree\tport\tcreated\n" > "$REGISTRY"
printf "main\t13000\t2026-01-01\n" >> "$REGISTRY"
printf "feat-a\t13001\t2026-01-02\n" >> "$REGISTRY"
printf "feat-b\t13002\t2026-01-03\n" >> "$REGISTRY"

SAFE_NAME="feat-a"
grep -v "^${SAFE_NAME}	" "$REGISTRY" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "$REGISTRY"

assert_not_contains "feat-a removed" "feat-a" "$(cat "$REGISTRY")"
assert_contains "main still present" "main" "$(cat "$REGISTRY")"
assert_contains "feat-b still present" "feat-b" "$(cat "$REGISTRY")"

print_results
