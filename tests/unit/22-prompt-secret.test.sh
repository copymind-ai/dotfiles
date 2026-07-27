#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: prompt_secret${RESET}\n"

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/dev.helpers.sh"

# prompt_secret masks input as `***… (N chars)`: stars capped at 20, the true
# length always shown in brackets. On a TTY it enables bracketed paste so a
# Cmd+V paste (wrapped by the terminal in ESC[200~ … ESC[201~) is captured as
# one atomic chunk — newlines included — instead of being torn apart or
# truncated at the first newline.
#
# The marker-parsing + masking logic is terminal-independent, so we drive it by
# feeding the same byte stream the terminal would produce, via a pipe. Process
# substitution (`< <(...)`) keeps prompt_secret in THIS shell so the captured
# value (set with `printf -v`) survives for assertions; a pipeline would run it
# in a subshell and lose it.

# Captured by the runners below.
PS_VALUE=""   # value prompt_secret stored
PS_MASK=""    # final rendered frame (text after the last carriage return)

# Feed CONTENT as a bracketed paste, then Enter (CR) to submit.
run_paste() {
  local content="$1" err raw
  err="$(mktemp)"
  prompt_secret PS_VALUE "Value: " 2>"$err" \
    < <(printf '\033[200~%s\033[201~\r' "$content")
  raw="$(cat "$err")"
  PS_MASK="${raw##*$'\r'}"
  rm -f "$err"
}

# Feed RAW bytes verbatim (interpreting \r \n \177 escapes), simulating typing.
run_typed() {
  local bytes="$1" err raw
  err="$(mktemp)"
  prompt_secret PS_VALUE "Value: " 2>"$err" < <(printf '%b' "$bytes")
  raw="$(cat "$err")"
  PS_MASK="${raw##*$'\r'}"
  rm -f "$err"
}

# Count the asterisks in a rendered frame.
stars_in() { printf '%s' "$1" | tr -cd '*' | wc -c | tr -d ' '; }

# ── Pasted values: masking + char count ─────────────────────────────

header "paste masks with stars + true count"
run_paste "hunter2"
assert_eq "value captured"      "hunter2"      "$PS_VALUE"
assert_eq "7 stars"             "7"            "$(stars_in "$PS_MASK")"
assert_contains "count shown"   "(7 chars)"    "$PS_MASK"
assert_not_contains "no plaintext leak" "hunter2" "$PS_MASK"

header "stars cap at 20, count stays true"
run_paste "01234567890123456789"        # exactly 20
assert_eq "20 chars → 20 stars" "20" "$(stars_in "$PS_MASK")"
assert_contains "(20 chars)" "(20 chars)" "$PS_MASK"

run_paste "0123456789012345678901234"   # 25
assert_eq "25 chars → still 20 stars" "20" "$(stars_in "$PS_MASK")"
assert_contains "(25 chars)" "(25 chars)" "$PS_MASK"

header "empty paste"
run_paste ""
assert_eq "value empty" "" "$PS_VALUE"
assert_eq "0 stars"     "0" "$(stars_in "$PS_MASK")"
assert_contains "(0 chars)" "(0 chars)" "$PS_MASK"

header "long single-line blob captured intact"
BLOB="ewogICJ0eXBlIjogInNlcnZpY2VfYWNjb3VudCIsCiAgInByaXZhdGVfa2V5IjogIi0t"
BLOB+="LS0tQkVHSU4gUFJJVkFURSBLRVktLS0tLSIKfQo="   # 108 chars, no newlines
run_paste "$BLOB"
assert_eq "blob captured byte-for-byte" "$BLOB" "$PS_VALUE"
assert_eq "blob length" "108" "${#PS_VALUE}"
assert_eq "capped at 20 stars" "20" "$(stars_in "$PS_MASK")"
assert_contains "(108 chars)" "(108 chars)" "$PS_MASK"

# ── Multi-line paste: newlines are content, not "submit" ────────────
# This is the regression guard for the original bug where a newline inside the
# value ended the read early (truncating to 112 chars) and spilled the rest
# into the next prompt.

header "multi-line paste keeps newlines (no truncation)"
run_paste "$(printf 'line1\nline2\nline3')"
assert_eq "value preserves newlines" "$(printf 'line1\nline2\nline3')" "$PS_VALUE"
assert_eq "full length (17)" "17" "${#PS_VALUE}"
assert_contains "(17 chars)" "(17 chars)" "$PS_MASK"

# ── Typed input (no paste markers) ──────────────────────────────────

header "typed input submits on Enter"
run_typed 'abc\r'
assert_eq "CR submits" "abc" "$PS_VALUE"
run_typed 'abc\n'
assert_eq "LF submits" "abc" "$PS_VALUE"

header "backspace deletes the previous char"
run_typed 'ab\177c\r'      # a b <DEL> c  → "ac"
assert_eq "backspace works" "ac" "$PS_VALUE"

header "non-paste escape sequences are ignored"
run_typed '\033[Cx\r'      # right-arrow (ESC[C) then 'x'
assert_eq "arrow consumed, only x kept" "x" "$PS_VALUE"

print_results
