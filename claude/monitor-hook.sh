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
#
# It also keeps the count of subagents a session has running, in a directory of
# empty marker files named by agent id, and what each one spent as it finishes --
# see the agents and subagent spend sections below.
set -uo pipefail

input=$(cat)

# Joined on a unit separator, not @tsv: tab is IFS whitespace, so the empty
# tool_name and message that most of these events carry would collapse and shift
# the timestamp into the wrong variable.
event='' tool='' message='' now=0 agent='' agent_live='' session='' apath=''
IFS=$'\037' read -r event tool message now agent agent_live session apath < <(
  printf '%s' "$input" | jq -r '[
    (.hook_event_name // ""),
    (.tool_name // ""),
    (.message // ""),
    (now | floor),
    # Which subagent the event is about, on SubagentStart and SubagentStop.
    (.agent_id // ""),
    # Every subagent the session still has in flight. Only Stop and SubagentStop
    # carry it, and it is the whole registry rather than a delta -- which is what
    # makes the reconcile below possible.
    ([.background_tasks[]? | select(.type == "subagent") | .id] | join(" ")),
    # Which session this is, for a run that has no pane to be keyed by.
    (.session_id // ""),
    # Where the finished subagent left its transcript, on SubagentStop -- the
    # only place its token usage can be read from. Last of the fields, because
    # it is the one that could hold a newline: read stops at one, and anything
    # after it in the record would be lost. Nothing is built from this but a
    # read, and a path that does not open simply skips the pricing below.
    (.agent_transcript_path // "")
  ] | map(tostring) | join("\u001f")' 2>/dev/null
) || true

[ -n "$event" ] || exit 0

dir=${CLAUDE_MONITOR_DIR:-$HOME/.claude/monitor}

# Everything is filed under a key, and which key says how the monitor will find
# it. A session with a pane is keyed by tmux server pid and pane id, which is
# what the monitor indexes by.
#
# A session without one is not lost, it is parked: `claude` hands long work to a
# background session under its daemon, and the daemon does not pass $TMUX_PANE on
# -- so the session doing the work, spending the money and running the agents has
# no pane to be keyed by, and until this it exported nothing at all. Keyed by its
# own session id instead, which the monitor reaches by following the pane's
# parkedJobId through Claude's own session registry. See tmux/monitor.sh.
#
# Anything that ends up in a filename is checked first: these values arrive as
# JSON and a path separator in one would write somewhere else entirely.
id_ok() {
  case ${1:-} in
    ''|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Checked whether or not it is the key, since it is also written into the state
# file, where a newline in it would split one record into two.
id_ok "$session" || session=""

if [ -n "${TMUX_PANE:-}" ] && [ -n "${TMUX:-}" ]; then
  IFS=, read -r _sock _spid _sid <<<"$TMUX"
  key="${_spid:-0}-${TMUX_PANE#%}"
else
  [ -n "$session" ] || exit 0
  key="sess-$session"
fi
mkdir -p "$dir" 2>/dev/null || exit 0

# --- subagents ----------------------------------------------------------------
#
# How many subagents a session has running is nowhere on its screen unless the
# fleet view happens to be open, and even there a finished agent keeps its row --
# so the monitor cannot count them by looking. These events can: SubagentStart
# and SubagentStop name the agent they are about, and Stop carries the whole
# background task registry.
#
# Kept as a directory of empty files named by agent id rather than as a number in
# a file, because several of these run at once -- five agents spawned in one turn
# is five concurrent SubagentStarts -- and a count would need a read, an add and a
# write between them. Creating and removing one file each cannot race, and the
# count is however many files are there, which the monitor gets from a glob.
adir="$dir/$key.agents"

# Adopts every agent the registry names and we have no marker for -- one that was
# already running when this pane's exports started, or whose SubagentStart never
# reached us. $1 is an id to leave out: the agent whose stop is being handled, which
# is still in a snapshot taken just before it went.
#
# Additive only, so it is safe on any event that carries the registry. A foreground
# subagent is never in there (the registry is of background tasks), and dropping
# markers here would take out every foreground agent running in parallel with the
# one that just stopped.
adopt_agents() {
  local id skip=${1:-}
  [ -n "$agent_live" ] || return 0
  mkdir -p "$adir" 2>/dev/null || return 0
  for id in $agent_live; do
    [ "$id" = "$skip" ] && continue
    id_ok "$id" || continue
    [ -e "$adir/$id" ] || : > "$adir/$id" 2>/dev/null
  done
  return 0
}

# Makes the marker directory say exactly what the registry says, dropping included.
# Only sound on Stop: that is the one moment the registry is the whole truth, since
# the main loop has finished and no foreground subagent can still be up -- so a
# marker with nothing behind it is a leftover from an agent that was killed, or
# from a stop event that never arrived, and can go.
#
# (An agent spawned by another agent is the one thing this can undercount, if the
# registry does not carry nested tasks: its marker goes here and the count runs
# short until that agent stops.)
reconcile_agents() {
  local f id live=" $agent_live "
  [ -n "$agent_live" ] || [ -d "$adir" ] || return 0
  for f in "$adir"/*; do
    [ -e "$f" ] || continue
    id=${f##*/}
    case $live in *" $id "*) ;; *) rm -f "$f" 2>/dev/null ;; esac
  done
  adopt_agents
}

# --- subagent spend -----------------------------------------------------------
#
# What a subagent cost is nowhere in the events, and nowhere in the status line
# either: the session's own total_cost_usd already has every agent folded into
# it, with nothing to pull the agent's share back out by. What SubagentStop does
# carry is the finished agent's transcript, and that holds a usage block per
# assistant message -- so the cost is recoverable here, once, at the moment the
# agent stops, and nowhere cheaper afterwards.
#
# Priced rather than kept in tokens, because tokens of different kinds are not
# comparable: a cache read is a tenth of a fresh input token and a cache write is
# more than one, so a token total would say almost nothing about the money.
#
# Appended, one line per agent, rather than added into a running total -- for the
# same reason the markers are files. Several agents stop at once, and a read, an
# add and a write between them would lose one. A short line opened for append
# lands whole; the monitor does the adding.
sfile="$dir/$key.aspend"

# Cents for the transcript at $1, on stdout. Two forks, on an event that fires
# once per agent rather than once per tool call.
#
# Deduplicated by message id: one assistant message with three content blocks is
# three lines in the transcript, each repeating that message's usage, and summing
# them as they come would charge it three times.
agent_cents() {
  jq -r '
    select(.type == "assistant") | .message // empty
    | select(.usage != null)
    | [ (.id // ""), (.model // ""),
        (.usage.input_tokens // 0),
        # The 5m/1h split only exists on newer transcripts; older ones have the
        # one flat figure, which was all 5m when it was written.
        (.usage.cache_creation.ephemeral_5m_input_tokens
           // .usage.cache_creation_input_tokens // 0),
        (.usage.cache_creation.ephemeral_1h_input_tokens // 0),
        (.usage.cache_read_input_tokens // 0),
        (.usage.output_tokens // 0) ]
    | @tsv' "$1" 2>/dev/null |
  awk -F'\t' '
    # Dollars per million tokens, by family rather than by exact id: the ids
    # carry suffixes that say nothing about the rate -- "[1m]", a vendor prefix,
    # a version tail -- and a model released next month is priced like its
    # siblings instead of being dropped. Sonnet is at its standard rate, so an
    # agent on it reads high until the introductory rate lapses on 2026-08-31.
    #
    # Server tool calls (web search) are not in here: they are billed per request
    # rather than per token, and the transcript counts them separately. A search-
    # heavy agent therefore reads a little low.
    BEGIN {
      IN["fable"]  = 10; OUT["fable"]  = 50
      IN["opus"]   = 5;  OUT["opus"]   = 25
      IN["sonnet"] = 3;  OUT["sonnet"] = 15
      IN["haiku"]  = 1;  OUT["haiku"]  = 5
    }
    function family(m) {
      if (m ~ /fable|mythos/) return "fable"
      if (m ~ /sonnet/)       return "sonnet"
      if (m ~ /haiku/)        return "haiku"
      # Opus by name, and anything unrecognized along with it: a model this does
      # not know is far likelier to be a new Opus than to be free.
      return "opus"
    }
    $1 != "" && seen[$1]++ { next }
    {
      f = family($2); i = IN[f] / 1000000; o = OUT[f] / 1000000
      # Each kind of token at its own multiple of the input rate, rather than all
      # of them at the input rate: that is the whole reason this is priced here.
      c += $3 * i + $4 * i * 1.25 + $5 * i * 2 + $6 * i * 0.1 + $7 * o
    }
    END { printf "%d\n", int(c * 100 + 0.5) }
  '
}

state=''
detail=''
case $event in
  # Whatever this pane counted belonged to the session that just ended in it.
  SessionStart)      state=idle; rm -rf "$adir" 2>/dev/null
                     rm -f "$sfile" 2>/dev/null ;;
  UserPromptSubmit)  state=busy ;;
  # The tool name is the best short answer to "working on what" that any of
  # these events carry, and it beats the title's summary for immediacy.
  PreToolUse)        state=busy; detail=$tool ;;
  PostToolUse)       state=busy; detail=$tool ;;
  PreCompact)        state=busy; detail=compacting ;;
  Stop)              state=idle; reconcile_agents ;;
  # One more agent. The state file is left alone: a background agent starting says
  # nothing about what the session itself is doing, and its own turn is already
  # reported by the tool events the agent runs through this same hook.
  SubagentStart)
    id_ok "$agent" || exit 0
    mkdir -p "$adir" 2>/dev/null && : > "$adir/$agent" 2>/dev/null
    exit 0
    ;;
  # One fewer -- and a chance to pick up any the count never saw, since this event
  # carries the registry as well. Waiting for Stop would be a long wait under a
  # session that stays busy for an hour, which is exactly what a fleet does.
  #
  # The state file is left where it is: this also fires a few seconds after Stop
  # with nothing new to say about the session, and would overwrite a state that
  # has since moved on.
  SubagentStop)
    id_ok "$agent" && rm -f "$adir/$agent" 2>/dev/null
    adopt_agents "$agent"
    # And what it spent, which is only readable now. A transcript that is missing
    # or unreadable, an older Claude that sends no path, a jq or awk that is not
    # here: the count still works, and the money is simply not counted.
    if [ -r "$apath" ]; then
      cents=$(agent_cents "$apath" 2>/dev/null) || cents=''
      case $cents in
        ''|0|*[!0-9]*) ;;
        *) printf '%s\n' "$cents" >> "$sfile" 2>/dev/null ;;
      esac
    fi
    exit 0
    ;;
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
    rm -f "$dir/$key.state" "$dir/$key.meta" "$sfile" 2>/dev/null
    rm -rf "$adir" 2>/dev/null
    exit 0
    ;;
  *) exit 0 ;;
esac

# Newlines would split one record into several key=value lines and corrupt the
# read on the other side; a tool name or notification cannot legitimately hold
# one, so they are flattened rather than escaped.
detail=${detail//$'\n'/ }
detail=${detail//$'\r'/ }

# The session id rides along so the monitor can follow a parked job from the very
# first event of a session, without waiting for the status line to render one.
tmp="$dir/.$key.state.$$"
if printf 'state=%s\ndetail=%s\nevent=%s\nsession=%s\nts=%s\n' \
     "$state" "$detail" "$event" "$session" "$now" > "$tmp" 2>/dev/null
then
  mv -f "$tmp" "$dir/$key.state" 2>/dev/null || rm -f "$tmp" 2>/dev/null
else
  rm -f "$tmp" 2>/dev/null
fi
exit 0
