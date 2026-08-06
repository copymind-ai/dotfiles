#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: parked jobs${RESET}\n"

HOOK="$DOTFILES_DIR/claude/monitor-hook.sh"
STATUSLINE="$DOTFILES_DIR/claude/statusline.sh"
MONITOR="$DOTFILES_DIR/tmux/monitor.sh"

# A monitor directory and a session registry of their own, so nothing real is
# read or written.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/parked-jobs-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_MONITOR_DIR="$ROOT/monitor"
export CLAUDE_SESSION_DIR="$ROOT/sessions"
mkdir -p "$CLAUDE_MONITOR_DIR" "$CLAUDE_SESSION_DIR"

SID_PANE="aaaaaaaa-1111-2222-3333-444444444444"   # the session in the pane
SID_JOB="deadbeef-5555-6666-7777-888888888888"    # the one it parked its work on
JOB="deadbeef"

# Claude writes these as one line with no trailing newline, which is worth
# reproducing exactly: a reader that trusts read's exit status sees every one of
# them as unreadable.
session_file() { printf '%s' "$2" > "$CLAUDE_SESSION_DIR/$1.json"; }

session_file 111 "{\"pid\":111,\"sessionId\":\"$SID_PANE\",\"cwd\":\"/w\",\"kind\":\"interactive\",\"status\":\"idle\",\"parkedJobId\":\"$JOB\"}"
session_file 222 "{\"pid\":222,\"sessionId\":\"$SID_JOB\",\"cwd\":\"/w\",\"kind\":\"bg\",\"name\":\"Fix the thing\",\"jobId\":\"$JOB\",\"status\":\"busy\"}"
session_file 333 "{\"pid\":333,\"sessionId\":\"cccccccc-9999\",\"cwd\":\"/w\",\"kind\":\"interactive\",\"status\":\"idle\"}"
printf 'not json at all\n' > "$CLAUDE_SESSION_DIR/notes.txt"

# What the pane's own session left behind before it parked: real numbers once,
# frozen from the moment it handed the work over.
NOW="$(date +%s)"
mkdir -p "$CLAUDE_MONITOR_DIR"
printf 'state=idle\ndetail=\nevent=Stop\nsession=%s\nts=%s\n' "$SID_PANE" "$NOW" \
  > "$CLAUDE_MONITOR_DIR/7-3.state"
printf 'ctx=8\ncost=1.44\nover=0.00\nlim5=12\nlim7=34\nrst5=0\nrst7=0\nsub=1\nmodel=Opus\nsession=%s\nts=%s\n' \
  "$SID_PANE" "$NOW" > "$CLAUDE_MONITOR_DIR/7-3.meta"

# And what the session doing the work exports, keyed by its own id since the
# daemon left it without a pane.
printf 'state=busy\ndetail=Bash\nevent=PostToolUse\nsession=%s\nts=%s\n' "$SID_JOB" "$NOW" \
  > "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.state"
printf 'ctx=14\ncost=77.70\nover=0.00\nlim5=68\nlim7=41\nrst5=0\nrst7=0\nsub=1\nmodel=Opus\nsession=%s\nts=%s\n' \
  "$SID_JOB" "$NOW" > "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.meta"
mkdir -p "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.agents"
: > "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.agents/a1"
: > "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.agents/a2"
: > "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.agents/a3"

# A second pane, with nothing parked: it must keep reading its own export.
printf 'state=busy\ndetail=Edit\nevent=PreToolUse\nsession=cccccccc-9999\nts=%s\n' "$NOW" \
  > "$CLAUDE_MONITOR_DIR/7-4.state"
printf 'ctx=30\ncost=5.00\nover=0.00\nlim5=12\nlim7=34\nrst5=0\nrst7=0\nsub=1\nmodel=Opus\nsession=cccccccc-9999\nts=%s\n' \
  "$NOW" > "$CLAUDE_MONITOR_DIR/7-4.meta"

# Sourced for its functions; the dispatch at the bottom is guarded, so nothing
# runs and no terminal is needed.
# shellcheck disable=SC1090
source "$MONITOR"

# ── reading Claude's registry ────────────────────────────────────────

header "one field out of one line of JSON, without a fork"
LINE="$(cat "$CLAUDE_SESSION_DIR/222.json")"
monitor_json_str "$LINE" sessionId
assert_eq "a key in the middle" "$SID_JOB" "$JSTR"
monitor_json_str "$LINE" pid || true
assert_eq "a number is not a string" "" "$JSTR"
# The one that would quietly make a session the parked job of itself.
LINE="$(cat "$CLAUDE_SESSION_DIR/111.json")"
monitor_json_str "$LINE" jobId || true
assert_eq "jobId does not match parkedJobId" "" "$JSTR"
monitor_json_str "$LINE" parkedJobId
assert_eq "and parkedJobId still does" "$JOB" "$JSTR"

header "the registry indexes both directions"
monitor_read_sessions
monitor_index_get "$PARKED_BY_SID" "$SID_PANE"
assert_eq "the pane's session knows what it parked" "$JOB" "$LOOKUP"
monitor_index_get "$SID_BY_JOB" "$JOB"
assert_eq "and the job knows which session it is" "$SID_JOB" "$LOOKUP"
monitor_index_get "$PARKED_BY_SID" "cccccccc-9999"
assert_eq "a session that parked nothing is absent" "" "$LOOKUP"

header "the chain resolves to the parked session's files"
monitor_parked_base "$SID_PANE"
assert_eq "pane -> parkedJobId -> jobId -> export" \
  "$CLAUDE_MONITOR_DIR/sess-$SID_JOB" "$PARKED_BASE"
monitor_parked_base "cccccccc-9999"
assert_eq "nothing parked, nothing followed" "" "$PARKED_BASE"
monitor_parked_base ""
assert_eq "and a pane whose session is unknown is left alone" "" "$PARKED_BASE"

header "a job that has exported nothing is not followed"
# It has finished, or the exporters are not installed where it runs. The pane's
# own numbers are old, but they are the only ones there are.
mv "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.state" "$ROOT/held.state"
mv "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.meta" "$ROOT/held.meta"
monitor_parked_base "$SID_PANE"
assert_eq "no files, no follow" "" "$PARKED_BASE"
mv "$ROOT/held.state" "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.state"
mv "$ROOT/held.meta" "$CLAUDE_MONITOR_DIR/sess-$SID_JOB.meta"

# ── what the row ends up showing ─────────────────────────────────────

header "the parked session's numbers are the ones on the row"
SERVER_PID=7
SESSIONS=(parked plain)
P_PANE=(%3 %4)
monitor_clock
monitor_read_exports
assert_eq "state comes from the session doing the work" "busy" "${X_STATE[0]}"
assert_eq "so does its detail" "Bash" "${X_DETAIL[0]}"
assert_eq "context, not the frozen 8%" "14" "${X_CTX[0]}"
assert_eq "cost, not the frozen \$1.44" '$77.70' "${X_COSTF[0]}"
assert_eq "and the agents it is running" "3" "${X_AGENTS[0]}"

header "a pane with nothing parked is untouched"
assert_eq "its own state" "busy" "${X_STATE[1]}"
assert_eq "its own context" "30" "${X_CTX[1]}"
assert_eq "its own cost" '$5.00' "${X_COSTF[1]}"
assert_eq "and no agents" "0" "${X_AGENTS[1]}"

header "the active total adds up what is really being spent"
# 77.70 for the parked session plus 5.00 for the plain one. The pane session's
# own 1.44 is not in it: one row, one session, and the row followed the job.
assert_eq "the parked figure, not the pane's" "82.70" "$X_COST_ALL"

header "a registry that is not there leaves every pane unparked"
(
  export CLAUDE_SESSION_DIR="$ROOT/nowhere"
  # shellcheck disable=SC1090
  source "$MONITOR"
  SERVER_PID=7; SESSIONS=(parked); P_PANE=(%3)
  monitor_clock
  monitor_read_exports
  printf '%s|%s\n' "${X_CTX[0]}" "${X_COSTF[0]}"
) > "$ROOT/out-noreg"
assert_eq "back to the pane's own export" '8|$1.44' "$(cat "$ROOT/out-noreg")"

# ── what the exporters write with no pane ────────────────────────────

header "with no pane, both exporters key by session id"
BG="$ROOT/bg"
mkdir -p "$BG"
(
  unset TMUX TMUX_PANE
  export CLAUDE_MONITOR_DIR="$BG"
  printf '{"hook_event_name":"SubagentStart","agent_id":"z1","session_id":"%s"}' "$SID_JOB" |
    bash "$HOOK"
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s"}' "$SID_JOB" | bash "$HOOK"
  printf '{"context_window":{"used_percentage":14},"cost":{"total_cost_usd":77.70},"model":{"display_name":"Opus"},"session_id":"%s"}' \
    "$SID_JOB" | bash "$STATUSLINE" >/dev/null
)
assert "the hook wrote a state file under the session id" [ -r "$BG/sess-$SID_JOB.state" ]
assert "the status line wrote the metadata beside it" [ -r "$BG/sess-$SID_JOB.meta" ]
assert "and the agent was counted" [ -e "$BG/sess-$SID_JOB.agents/z1" ]
assert "nothing was keyed by a pane" [ ! -e "$BG/0-.state" ]
assert_contains "the state file names its session" "session=$SID_JOB" \
  "$(cat "$BG/sess-$SID_JOB.state")"

header "a session id that is not one is not turned into a path"
(
  unset TMUX TMUX_PANE
  export CLAUDE_MONITOR_DIR="$BG"
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"../escaped"}' | bash "$HOOK"
  printf '{"cost":{"total_cost_usd":1},"session_id":"../escaped"}' | bash "$STATUSLINE" >/dev/null
)
assert "the hook wrote nothing outside" [ ! -e "$ROOT/escaped.state" ]
assert "nor did the status line" [ ! -e "$ROOT/escaped.meta" ]
# The ledger builds a filename out of the id as well, and is skipped for the same
# reason -- it used to attempt the write and fail on it.
assert_eq "and the ledger did not try either" "0" \
  "$(find "$ROOT" -name '*escaped*' 2>/dev/null | wc -l | tr -d ' ')"

print_results
