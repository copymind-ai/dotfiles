#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../helpers.sh"

echo ""
printf "${BOLD}Unit: subagent spend${RESET}\n"

HOOK="$DOTFILES_DIR/claude/monitor-hook.sh"

# As in the count test: a monitor directory of its own, and a tmux that does not
# exist -- the hook reads $TMUX only for the server pid it keys its files by.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-spend-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export CLAUDE_MONITOR_DIR="$ROOT"
export TMUX="/tmp/not-a-socket,4242,0"
export TMUX_PANE="%7"
SPEND="$ROOT/4242-7.aspend"
TRANSCRIPT="$ROOT/agent.jsonl"

hook() { printf '%s' "$1" | bash "$HOOK"; }

# One assistant line of a subagent transcript. The usage block is the shape the
# real ones have; everything the pricing does not read is left out.
line() { # id model input cache5m cache1h cacheread output
  printf '{"type":"assistant","message":{"id":"%s","model":"%s","usage":{' "$1" "$2"
  printf '"input_tokens":%s,' "$3"
  printf '"cache_creation":{"ephemeral_5m_input_tokens":%s,"ephemeral_1h_input_tokens":%s},' "$4" "$5"
  printf '"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' "$6" "$7"
}

# Price one transcript and give back the cents the hook recorded for it. The file
# is cleared first, so each case reads its own figure rather than a running total.
price() {
  rm -f "$SPEND"
  hook "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"a1\",\"background_tasks\":[],\"agent_transcript_path\":\"$TRANSCRIPT\"}"
  [ -r "$SPEND" ] || { printf '0'; return; }
  tr -d '\n' < "$SPEND"
}

# ── what a transcript is worth ───────────────────────────────────────

header "each kind of token is charged at its own rate"
# A million of one kind at a time, on Opus at $5 in / $25 out, so every figure is
# a round number and a multiplier that has drifted shows up as a wrong one.
line m1 claude-opus-4-8 1000000 0 0 0 0 > "$TRANSCRIPT"
assert_eq "fresh input at the input rate" "500" "$(price)"
line m1 claude-opus-4-8 0 0 0 0 1000000 > "$TRANSCRIPT"
assert_eq "output at the output rate" "2500" "$(price)"
line m1 claude-opus-4-8 0 1000000 0 0 0 > "$TRANSCRIPT"
assert_eq "a five-minute cache write at 1.25x input" "625" "$(price)"
line m1 claude-opus-4-8 0 0 1000000 0 0 > "$TRANSCRIPT"
assert_eq "an hour cache write at 2x input" "1000" "$(price)"
line m1 claude-opus-4-8 0 0 0 1000000 0 > "$TRANSCRIPT"
assert_eq "a cache read at a tenth of input" "50" "$(price)"

header "one message split across content blocks is charged once"
# Three lines, one message id: the transcript repeats the whole usage block for
# each content block, and adding them as they come would treble the message.
{ line m1 claude-opus-4-8 0 0 0 0 1000000
  line m1 claude-opus-4-8 0 0 0 0 1000000
  line m1 claude-opus-4-8 0 0 0 0 1000000
  line m2 claude-haiku-4-5 0 0 0 0 1000000
} > "$TRANSCRIPT"
assert_eq "one opus message and one haiku" "3000" "$(price)"

header "the model is read by family, not by exact id"
line m1 'claude-opus-5[1m]' 0 0 0 0 1000000 > "$TRANSCRIPT"
assert_eq "a context suffix does not change the rate" "2500" "$(price)"
line m1 'us.anthropic.claude-sonnet-5-v1:0' 0 0 0 0 1000000 > "$TRANSCRIPT"
assert_eq "nor does a vendor prefix" "1500" "$(price)"
line m1 claude-fable-5 0 0 0 0 1000000 > "$TRANSCRIPT"
assert_eq "fable is its own tier" "5000" "$(price)"
line m1 claude-something-7 0 0 0 0 1000000 > "$TRANSCRIPT"
assert_eq "a model this does not know is priced as opus, not as free" "2500" "$(price)"

header "lines that are not a priced assistant message are skipped"
{ printf '{"type":"user","message":{"role":"user","content":"hello"}}\n'
  printf '{"type":"assistant","message":{"id":"m9","model":"claude-opus-4-8"}}\n'
  line m1 claude-opus-4-8 0 0 0 0 1000000
} > "$TRANSCRIPT"
assert_eq "only the one with usage counts" "2500" "$(price)"

header "a transcript that cannot be read costs nothing and breaks nothing"
rm -f "$SPEND"
hook '{"hook_event_name":"SubagentStop","agent_id":"a1","background_tasks":[],"agent_transcript_path":"/no/such/file.jsonl"}'
assert "nothing recorded" [ ! -e "$SPEND" ]
# An older Claude that sends no path at all: the count must still work.
hook '{"hook_event_name":"SubagentStop","agent_id":"a1","background_tasks":[]}'
assert "and no path at all is fine too" [ ! -e "$SPEND" ]

header "each agent appends its own line rather than rewriting a total"
# Several agents stop at once and only the append is safe between them, so what
# lands on disk has to be one line each and not a figure someone recomputed.
rm -f "$SPEND"
line m1 claude-opus-4-8 0 0 0 0 1000000 > "$TRANSCRIPT"
hook "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"a1\",\"background_tasks\":[],\"agent_transcript_path\":\"$TRANSCRIPT\"}"
hook "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"a2\",\"background_tasks\":[],\"agent_transcript_path\":\"$TRANSCRIPT\"}"
assert_eq "two agents, two lines" "2" "$(wc -l < "$SPEND" | tr -d ' ')"

header "a session boundary takes the spend with it"
hook '{"hook_event_name":"SessionEnd","reason":"exit"}'
assert "nothing left to inherit" [ ! -e "$SPEND" ]
hook "{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"a1\",\"background_tasks\":[],\"agent_transcript_path\":\"$TRANSCRIPT\"}"
hook '{"hook_event_name":"SessionStart","source":"startup"}'
assert "and a new session starts from nothing" [ ! -e "$SPEND" ]

# The monitor's half of this file went with the header figure it fed: nothing
# reads $key.aspend now. What is left is the hook's side, which still writes it.

print_results
