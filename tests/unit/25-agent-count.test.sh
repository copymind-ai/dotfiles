#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: subagent count${RESET}\n"

HOOK="$DOTFILES_DIR/claude/monitor-hook.sh"
MONITOR="$DOTFILES_DIR/tmux/monitor.sh"

# A monitor directory of its own, so a real ~/.claude/monitor is neither read nor
# written, and a tmux that does not exist -- the hook only ever reads $TMUX for
# the server pid it keys its files by.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-count-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_MONITOR_DIR="$ROOT"
export TMUX="/tmp/not-a-socket,4242,0"
export TMUX_PANE="%7"
AGENTS="$ROOT/4242-7.agents"

# One hook event, as Claude Code would send it.
hook() { printf '%s' "$1" | bash "$HOOK"; }

start() { hook "{\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"$1\",\"agent_type\":\"general-purpose\"}"; }
stop()  { hook "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"$1\",\"background_tasks\":[]}"; }

# The same, but carrying the registry: $1 is the agent that stopped, the rest are
# the ids still running.
stop_with() {
  local who=$1 ids="" id
  shift
  for id in "$@"; do
    ids="$ids,{\"id\":\"$id\",\"type\":\"subagent\",\"status\":\"running\"}"
  done
  hook "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"$who\",\"background_tasks\":[${ids#,}]}"
}

# Stop, carrying the background task registry: $@ are the ids still running.
turn_end() {
  local ids="" id
  for id in "$@"; do
    ids="$ids,{\"id\":\"$id\",\"type\":\"subagent\",\"status\":\"running\"}"
  done
  hook "{\"hook_event_name\":\"Stop\",\"background_tasks\":[${ids#,}]}"
}

marks() { # how many markers are on disk
  local f n=0
  for f in "$AGENTS"/*; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# ── what the hook records ────────────────────────────────────────────

header "an agent starting is counted and its stop takes it back off"
start a1
assert_eq "one agent" "1" "$(marks)"
start a2
start a3
assert_eq "three, one file each" "3" "$(marks)"
stop a2
assert_eq "the one that stopped is gone" "2" "$(marks)"
assert "and it is the right one" [ ! -e "$AGENTS/a2" ]
assert "the others are untouched" [ -e "$AGENTS/a1" ]

header "a stop for an agent that was never counted changes nothing"
stop never-started
assert_eq "still two" "2" "$(marks)"

header "an id that could be a path is refused"
start "../../escaped"
assert "nothing written outside the directory" [ ! -e "$ROOT/../escaped" ]
assert_eq "and nothing counted" "2" "$(marks)"

header "the state file is left alone by both"
# Only the count moves: what the session itself is doing is decided by the events
# that fire for the main loop, and a background agent starting is not one of them.
hook '{"hook_event_name":"UserPromptSubmit"}'
start a4
stop a4
assert_contains "still busy from the prompt" "state=busy" "$(cat "$ROOT/4242-7.state")"

header "an agent stopping picks up the ones the count never saw"
# A fleet that was already running when the exports started: only d1 was ever
# counted, and waiting for Stop would mean waiting out the whole turn.
start d1
stop_with d1 d1 d2 d3
assert_eq "d2 and d3 adopted, d1 struck off" "4" "$(marks)"
assert "the one that stopped is not resurrected" [ ! -e "$AGENTS/d1" ]
assert "and the others are counted" [ -e "$AGENTS/d2" ]
rm -f "$AGENTS/d2" "$AGENTS/d3"

header "the end of a turn reconciles against the registry"
# a1 and a3 are counted; the registry says a3 and a5. So a1 finished without its
# stop event ever arriving, and a5 was started before the hook was installed.
turn_end a3 a5
assert_eq "the registry decides" "2" "$(marks)"
assert "a marker with nothing behind it is dropped" [ ! -e "$AGENTS/a1" ]
assert "one the registry knows about is added" [ -e "$AGENTS/a5" ]
assert_contains "and the turn still reports idle" "state=idle" "$(cat "$ROOT/4242-7.state")"

header "a turn that ends with nothing running clears the count"
turn_end
assert_eq "empty" "0" "$(marks)"

header "a session ending in this pane takes the directory with it"
start a6
hook '{"hook_event_name":"SessionEnd","reason":"exit"}'
assert "no directory left" [ ! -d "$AGENTS" ]

header "and a session starting in it does not inherit the last one's agents"
start a7
hook '{"hook_event_name":"SessionStart","source":"startup"}'
assert_eq "starts from nothing" "0" "$(marks)"

# ── what the monitor makes of it ─────────────────────────────────────

# Sourced for its functions; the dispatch at the bottom is guarded, so nothing
# runs and no terminal is needed.
# shellcheck disable=SC1090
source "$MONITOR"

start b1; start b2; start b3
mkdir -p "$ROOT/4242-9.agents"; : > "$ROOT/4242-9.agents/c1"

header "the count is read per pane, and totalled for the header"
SERVER_PID=4242
SESSIONS=(alpha graspen-ci zulu)
P_PANE=(%1 %7 %9)
monitor_clock
monitor_read_exports
assert_eq "a session with no markers" "0" "${X_AGENTS[0]}"
assert_eq "the pane the agents are in" "3" "${X_AGENTS[1]}"
assert_eq "another pane, its own count" "1" "${X_AGENTS[2]}"

header "the row shows the count and the header the fleet's"
term_size() { printf '20 120'; }
ROW_STATE=(busy idle shell); ROW_DETAIL=("Cooking…" "Fix the CI failure" "")
X_CTX=(40 14 ""); X_COSTF=('$1.00' '$41.61' '')
N_CLAUDE=2; N_WORK=1; N_NEED=0
X_AGENTS[2]=0      # a shell, so its markers are a dead session's leftovers
X_AGENT_ALL=3
DRAWN="$(monitor_draw | tr -d '\r' | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g')"
assert_contains "the count sits by the state" 'idle  *3a  *14%' "$DRAWN"
assert_contains "the fleet total is in the header" '0 need you  3 agents' "$DRAWN"
assert_not_contains "a session with none says nothing" '0a' "$DRAWN"

header "the columns still line up under each other"
# The agent column is three wide whether or not it has anything in it, so ctx
# lands in the same place on every row. Nothing else here checks that, and a
# column out by one is invisible until you go looking for it.
# Counted in characters rather than bytes, since the cursor's own mark is
# multibyte and the row it is on would otherwise read as two columns further along.
CTX_COLS="$(printf '%s\n' "$DRAWN" |
              perl -CSD -ne 'print index($_, "%"), "\n" if /[0-9]%/' |
              sort -u | wc -l | tr -d ' ')"
assert_eq "the context figures share one column" "1" "$CTX_COLS"

print_results
