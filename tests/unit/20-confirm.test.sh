#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: confirm${RESET}\n"

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/dev.helpers.sh"

# Run confirm with stdin piped from a string. Echo the resulting exit code.
# Wrapping in a function isolates `confirm`'s `read` and side-channels the
# exit code via stdout for assertion.
confirm_exit() {
  local input="$1" prompt="$2" default="${3:-n}"
  echo "$input" | (confirm "$prompt" "$default" >/dev/null 2>&1 && echo 0 || echo 1)
}

header "default n — accepts y/yes (case-insensitive)"
assert_eq "y → 0"   "0" "$(confirm_exit "y"   "Proceed?" n)"
assert_eq "Y → 0"   "0" "$(confirm_exit "Y"   "Proceed?" n)"
assert_eq "yes → 0" "0" "$(confirm_exit "yes" "Proceed?" n)"
assert_eq "YES → 0" "0" "$(confirm_exit "YES" "Proceed?" n)"

header "default n — rejects everything else"
assert_eq "n → 1"     "1" "$(confirm_exit "n"     "Proceed?" n)"
assert_eq "no → 1"    "1" "$(confirm_exit "no"    "Proceed?" n)"
assert_eq "empty → 1" "1" "$(confirm_exit ""      "Proceed?" n)"
assert_eq "garbage → 1" "1" "$(confirm_exit "asdf" "Proceed?" n)"

header "default y — empty input accepts"
assert_eq "empty + default y → 0" "0" "$(confirm_exit "" "Proceed?" y)"
assert_eq "n + default y → 1"     "1" "$(confirm_exit "n" "Proceed?" y)"
assert_eq "y + default y → 0"     "0" "$(confirm_exit "y" "Proceed?" y)"

header "default omitted falls back to n"
# When second arg is absent, default should be n
NO_DEFAULT_RESULT=$(echo "" | (confirm "Proceed?" >/dev/null 2>&1 && echo 0 || echo 1))
assert_eq "empty + no default → 1" "1" "$NO_DEFAULT_RESULT"

print_results
