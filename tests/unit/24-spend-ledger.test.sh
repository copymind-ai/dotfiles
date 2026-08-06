#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: spend ledger${RESET}\n"

STATUSLINE="$DOTFILES_DIR/claude/statusline.sh"
MONITOR="$DOTFILES_DIR/tmux/monitor.sh"

# A ledger of its own, so a real ~/.claude/monitor is neither read nor written.
LEDGER_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spend-ledger-test.XXXXXX")"
trap 'rm -rf "$LEDGER_ROOT"' EXIT
export CLAUDE_MONITOR_DIR="$LEDGER_ROOT"
SPEND="$LEDGER_ROOT/spend"

TODAY="$(date +%F)"

# One status line render for a session that has spent $1 in total so far. No
# rate_limits in the payload, which is how the status line tells an API-billed
# login from a subscription -- so these all land in the api column.
status_tick() {
  printf '{"context_window":{"used_percentage":10},"cost":{"total_cost_usd":%s},"model":{"display_name":"Test"},"session_id":"%s"}' \
    "$1" "$2" | bash "$STATUSLINE" >/dev/null
}

# The same, for a session Claude is sending rate limits to: a subscription.
status_tick_sub() {
  printf '{"context_window":{"used_percentage":10},"cost":{"total_cost_usd":%s},"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":9999999999},"seven_day":{"used_percentage":1,"resets_at":9999999999}},"model":{"display_name":"Test"},"session_id":"%s"}' \
    "$1" "$2" | bash "$STATUSLINE" >/dev/null
}

spent_of() { # cents recorded for a ledger file, or "none"
  [ -r "$1" ] || { echo none; return; }
  local k v
  while IFS='=' read -r k v; do
    [ "$k" = spent ] && { echo "$v"; return; }
  done < "$1"
  echo none
}

day_ago() { date -v-"$1"d '+%F' 2>/dev/null || date -d "$1 days ago" '+%F'; }

# ── what the status line writes ──────────────────────────────────────

header "a session accrues what it spends, into today's file"
status_tick 1.005 sess-a
status_tick 2.50 sess-a
assert_eq "cumulative cost in cents" "250" "$(spent_of "$SPEND/$TODAY.sess-a")"

header "sub-cent turns are not rounded away"
# Each turn on its own truncates to nothing; the differences telescope, so what
# lands is the truncation of the total rather than the sum of truncations.
status_tick 0.004 sess-tiny
status_tick 0.008 sess-tiny
status_tick 0.99 sess-tiny
assert_eq "three turns under a cent then one over" "99" "$(spent_of "$SPEND/$TODAY.sess-tiny")"

header "a cost that goes backwards rebases instead of accruing"
status_tick 0.75 sess-b
status_tick 0.10 sess-b     # resumed earlier, or the id was reused
assert_eq "no negative accrual" "75" "$(spent_of "$SPEND/$TODAY.sess-b")"
status_tick 0.30 sess-b     # and it measures from where it actually stood
assert_eq "accrues from the rebased figure" "95" "$(spent_of "$SPEND/$TODAY.sess-b")"

header "sessions are kept apart"
assert_eq "sess-a untouched by sess-b" "250" "$(spent_of "$SPEND/$TODAY.sess-a")"

header "a session running past midnight starts the new day at zero"
# Yesterday it reached $50; today it is at $51. Only the dollar belongs to today.
YESTERDAY="$(date -v-1d '+%F' 2>/dev/null || date -d yesterday '+%F')"
printf 'spent=5000\nlast=5000\nsub=1\nts=1\n' > "$SPEND/$YESTERDAY.sess-night"
status_tick 51.00 sess-night
assert_eq "only the new day's increment" "100" "$(spent_of "$SPEND/$TODAY.sess-night")"
assert_eq "yesterday left alone" "5000" "$(spent_of "$SPEND/$YESTERDAY.sess-night")"

header "a subscription session lands in the other column"
status_tick_sub 3.00 sess-plan
assert_eq "counted like any other" "300" "$(spent_of "$SPEND/$TODAY.sess-plan")"

# ── what the monitor totals ──────────────────────────────────────────

# Sourced for its functions; the dispatch at the bottom is guarded, so nothing
# runs and no terminal is needed.
# shellcheck disable=SC1090
source "$MONITOR"

seed() { printf 'spent=%s\nlast=%s\nsub=%s\nts=1\n' "$2" "$2" "${3:-1}" > "$SPEND/$1.seeded"; }

D3="$(day_ago 3)"; D10="$(day_ago 10)"; D100="$(day_ago 100)"
seed "$D3" 1000      # $10, inside every window but today
seed "$D10" 2000     # $20, inside 30d and all
seed "$D100" 50000   # $500, all-time only
printf 'junk\n' > "$SPEND/not-a-ledger-file"

# today: api 2.50 + 0.99 + 0.95 + 1.00 = 5.44, sub 3.00, so 8.44 in total. The
# days behind it are all subscription: yesterday 50.00, then 10.00, 20.00, 500.00
monitor_clock
monitor_read_ledger

header "the windows total the days they cover"
assert_eq "today" "8.44" "${SPEND_ALL[0]}"
assert_eq "7d includes today and yesterday" "68.44" "${SPEND_ALL[1]}"
assert_eq "30d includes 7d" "88.44" "${SPEND_ALL[2]}"
assert_eq "all includes everything" "588.44" "${SPEND_ALL[3]}"

header "each window is split the way its sessions were paying"
assert_eq "today sub" "3.00" "${SPEND_SUB[0]}"
assert_eq "today api" "5.44" "${SPEND_API[0]}"
assert_eq "7d sub picks up the earlier days" "63.00" "${SPEND_SUB[1]}"
assert_eq "7d api is still only today's" "5.44" "${SPEND_API[1]}"
assert_eq "all sub" "583.00" "${SPEND_SUB[3]}"
assert_eq "all api" "5.44" "${SPEND_API[3]}"

header "the day rolls over without recounting"
MON_DAY="$(date -v+1d '+%F' 2>/dev/null || date -d 'tomorrow' '+%F')"
monitor_read_ledger
assert_eq "today starts over" "0.00" "${SPEND_ALL[0]}"
assert_eq "and has no split to show" "" "${SPEND_SUB[0]}"
assert_eq "the day just ended is still inside 7d" "68.44" "${SPEND_ALL[1]}"
assert_eq "its split too" "5.44" "${SPEND_API[1]}"
assert_eq "all-time unchanged" "588.44" "${SPEND_ALL[3]}"

header "an empty ledger reads as unknown, not as zero"
EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/spend-ledger-empty.XXXXXX")"
mkdir -p "$EMPTY/spend"
(
  export CLAUDE_MONITOR_DIR="$EMPTY"
  # shellcheck disable=SC1090
  source "$MONITOR"
  monitor_clock
  monitor_read_ledger
  printf '%s|%s\n' "${SPEND_ALL[0]}" "${SPEND_ALL[3]}"
) > "$EMPTY/out"
assert_eq "no files, no figures" "|" "$(cat "$EMPTY/out")"
rm -rf "$EMPTY"

header "a missing ledger directory is not an error"
(
  export CLAUDE_MONITOR_DIR="$LEDGER_ROOT/nowhere"
  # shellcheck disable=SC1090
  source "$MONITOR"
  monitor_clock
  monitor_read_ledger
  printf 'rc=%s|%s\n' "$?" "${SPEND_ALL[3]}"
) > "$LEDGER_ROOT/out-missing"
assert_eq "returns clean and says nothing" "rc=0|" "$(cat "$LEDGER_ROOT/out-missing")"

header "the rows are drawn as a table under the sessions"
term_size() { printf '50 120'; }
SESSIONS=(alpha); ROW_STATE=(idle); ROW_DETAIL=(""); X_CTX=(10); X_COSTF=('$1.00')
X_COST_ALL=1.00; X_COST_SUB=""; X_COST_API=1.00; X_COST_OVER=""
MON_DAY="$TODAY"
monitor_read_ledger
DRAWN="$(monitor_draw | tr -d '\r' | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g')"
assert_contains "an active row for the live sessions" 'total active *\$1.00' "$DRAWN"
assert_contains "today with its split" ' today *\$8.44 *sub ~\$3.00 *api \$5.44' "$DRAWN"
assert_contains "and the rest of the windows" ' all *\$588.44' "$DRAWN"
assert_not_contains "the word only opens the block" "total today" "$DRAWN"

header "with no live cost the block opens on the first row there is"
X_COST_ALL=""; X_COST_SUB=""; X_COST_API=""; X_COSTF=("")
DRAWN="$(monitor_draw | tr -d '\r' | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g')"
assert_contains "today carries it instead" 'total today *\$8.44' "$DRAWN"
assert_not_contains "and no active row is drawn" "total active" "$DRAWN"

print_results
