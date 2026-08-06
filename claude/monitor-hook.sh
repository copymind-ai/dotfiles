#!/usr/bin/env bash
# One hook for every Claude Code event the tmux monitor cares about. Wired to all
# of them in settings.json and dispatched here on hook_event_name, so there is a
# single place to read rather than nine one-liners.
#
# Why hooks and not the status line: the status line payload has no "Claude is
# working" field, and the status line is not rendered at all while a permission
# dialog is up -- the two states the monitor exists to show. These events carry
# both, and they fire on the transition rather than on a timer.
#
# The sequence, measured on 2.1.223 for a turn that asks to write a file:
#
#   UserPromptSubmit -> PreToolUse(Write) -> Notification -> PostToolUse -> Stop
#
# Notification lags PreToolUse by about six seconds, and is dropped entirely when
# the prompt is answered inside that window -- so it never lands late for a
# dialog that has already gone. It is still the slower of the monitor's two ways
# of seeing a prompt, which is why the monitor keeps reading the screen too and
# takes whichever notices first.
#
# Every event runs this script, including PreToolUse before each tool call, so it
# stays at two forks: one jq, one mv.
set -uo pipefail

input=$(cat)

[ -n "${TMUX_PANE:-}" ] || exit 0
[ -n "${TMUX:-}" ] || exit 0

# Joined on a unit separator, not @tsv: tab is IFS whitespace, so the empty
# tool_name and message that most of these events carry would collapse and shift
# the timestamp into the wrong variable.
event='' tool='' message='' now=0
IFS=$'\037' read -r event tool message now < <(
  printf '%s' "$input" | jq -r '[
    (.hook_event_name // ""),
    (.tool_name // ""),
    (.message // ""),
    (now | floor)
  ] | map(tostring) | join("\u001f")' 2>/dev/null
) || true

[ -n "$event" ] || exit 0

IFS=, read -r _sock _spid _sid <<<"$TMUX"
dir=${CLAUDE_MONITOR_DIR:-$HOME/.claude/monitor}
key="${_spid:-0}-${TMUX_PANE#%}"
mkdir -p "$dir" 2>/dev/null || exit 0

state=''
detail=''
case $event in
  SessionStart)      state=idle ;;
  UserPromptSubmit)  state=busy ;;
  # The tool name is the best short answer to "working on what" that any of
  # these events carry, and it beats the title's summary for immediacy.
  PreToolUse)        state=busy; detail=$tool ;;
  PostToolUse)       state=busy; detail=$tool ;;
  PreCompact)        state=busy; detail=compacting ;;
  Stop)              state=idle ;;
  # Fires a few seconds after Stop with nothing new to say, so it is ignored
  # rather than allowed to overwrite a state that moved on in between.
  SubagentStop)      exit 0 ;;
  Notification)
    # Two different notifications arrive here. The permission one means the
    # session is blocked on you; the idle reminder only means nobody has typed
    # for a while, and treating that as a prompt would light up every settled
    # session on the monitor.
    case $message in
      *'waiting for your input'*|*'idle'*) state=idle ;;
      *) state=ask; detail=$message ;;
    esac
    ;;
  SessionEnd)
    rm -f "$dir/$key.state" "$dir/$key.meta" 2>/dev/null
    exit 0
    ;;
  *) exit 0 ;;
esac

# Newlines would split one record into several key=value lines and corrupt the
# read on the other side; a tool name or notification cannot legitimately hold
# one, so they are flattened rather than escaped.
detail=${detail//$'\n'/ }
detail=${detail//$'\r'/ }

tmp="$dir/.$key.state.$$"
if printf 'state=%s\ndetail=%s\nevent=%s\nts=%s\n' \
     "$state" "$detail" "$event" "$now" > "$tmp" 2>/dev/null
then
  mv -f "$tmp" "$dir/$key.state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
else
  rm -f "$tmp" 2>/dev/null
fi
exit 0
